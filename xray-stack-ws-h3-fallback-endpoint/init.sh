#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f ".env" ]]; then
  echo "ERROR: .env not found. Create it from .env.example first."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "Checking sudo access..."
sudo -v

mkdir -p nginx/conf.d xray site certbot/www certbot/conf generated

required_vars=(
  DOMAIN
  EMAIL
  XRAY_UUID
  XRAY_PATH
  XRAY_PORT
  XRAY_LOGLEVEL
  DOH_URL
  CLIENT_SOCKS_UDP
  CLIENT_SNIFF_QUIC
  CLIENT_ALPN
  CLIENT_MUX_ENABLED
  CLIENT_MUX_CONCURRENCY
  CLIENT_MUX_XUDP_CONCURRENCY
  NGINX_HTTP2
  NGINX_HTTP3
  NGINX_HTTP3_STRICT
  NGINX_ALTSVC_MAX_AGE
  NGINX_HSTS_MAX_AGE
  NGINX_PROXY_READ_TIMEOUT
  NGINX_PROXY_SEND_TIMEOUT
  XRAY_IMAGE
  NGINX_IMAGE
  CERTBOT_IMAGE
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: required variable '$var_name' is empty"
    exit 1
  fi
done

log() {
  echo
  echo "== $* =="
}

normalize_ws_path() {
  local value="$1"

  if [[ -z "$value" ]]; then
    echo "/ws"
    return
  fi

  if [[ "$value" != /* ]]; then
    value="/$value"
  fi

  if [[ "$value" != "/" && "$value" == */ ]]; then
    value="${value%/}"
  fi

  echo "$value"
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

replace_token() {
  local file="$1"
  local token="$2"
  local value="$3"
  sed -i "s/${token}/$(escape_sed "$value")/g" "$file"
}

bool_to_python() {
  case "${1,,}" in
    true|yes|on|1) echo "true" ;;
    false|no|off|0) echo "false" ;;
    *)
      echo "ERROR: invalid boolean value '$1'" >&2
      exit 1
      ;;
  esac
}

validate_settings() {
  case "${NGINX_HTTP2}" in
    on|off) ;;
    *) echo "ERROR: NGINX_HTTP2 must be on/off"; exit 1 ;;
  esac

  case "${NGINX_HTTP3}" in
    on|off) ;;
    *) echo "ERROR: NGINX_HTTP3 must be on/off"; exit 1 ;;
  esac

  case "${NGINX_HTTP3_STRICT}" in
    yes|no) ;;
    *) echo "ERROR: NGINX_HTTP3_STRICT must be yes/no"; exit 1 ;;
  esac

  bool_to_python "$CLIENT_SOCKS_UDP" >/dev/null
  bool_to_python "$CLIENT_SNIFF_QUIC" >/dev/null
  bool_to_python "$CLIENT_MUX_ENABLED" >/dev/null
}

check_required_files() {
  local required_files=(
    "xray/config.json.template"
    "nginx/conf.d/default.conf.template"
    "nginx/conf.d/bootstrap.conf.template"
    "generate_client_config.py"
    "docker-compose.yml"
    "renew.sh"
  )

  for f in "${required_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: required file '$f' not found"
      exit 1
    fi
  done
}

ensure_default_site() {
  if [[ ! -f site/index.html ]]; then
    cat > site/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OK</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
</head>
<body>
OK
</body>
</html>
HTML
  fi
}

EFFECTIVE_NGINX_HTTP3="${NGINX_HTTP3}"

verify_nginx_http3_image() {
  EFFECTIVE_NGINX_HTTP3="${NGINX_HTTP3}"

  if [[ "${NGINX_HTTP3}" != "on" ]]; then
    return
  fi

  if [[ "${VERIFY_HTTP3_IMAGE:-yes}" != "yes" ]]; then
    return
  fi

  log "Checking nginx image for --with-http_v3_module"
  if docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 | grep -q -- '--with-http_v3_module'; then
    return
  fi

  if [[ "${NGINX_HTTP3_STRICT}" == "yes" ]]; then
    echo "ERROR: NGINX_HTTP3=on, but nginx image does not include --with-http_v3_module"
    echo "Set NGINX_HTTP3=off, set NGINX_HTTP3_STRICT=no, or use an HTTP/3-capable nginx image."
    exit 1
  fi

  echo "WARNING: nginx image does not include --with-http_v3_module; disabling HTTP/3 for this run."
  EFFECTIVE_NGINX_HTTP3="off"
}

prepare_cert_permissions() {
  local live_dir="certbot/conf/live/${DOMAIN}"
  local archive_dir="certbot/conf/archive/${DOMAIN}"

  sudo chmod 755 certbot/conf || true
  sudo chmod 755 certbot/conf/live || true
  sudo chmod 755 certbot/conf/archive || true

  if [[ -d "$live_dir" ]]; then
    sudo chmod 755 "$live_dir" || true
  fi

  if [[ -d "$archive_dir" ]]; then
    sudo chmod 755 "$archive_dir" || true
    sudo find "$archive_dir" -type f -name '*.pem' -exec chmod 644 {} \; || true
  fi
}

generate_xray_config() {
  XRAY_PATH_NORMALIZED="$(normalize_ws_path "$XRAY_PATH")"
  XRAY_FINGERPRINT_VALUE="${XRAY_FINGERPRINT:-chrome}"

  cp xray/config.json.template xray/config.json

  replace_token xray/config.json "__XRAY_LOGLEVEL__" "$XRAY_LOGLEVEL"
  replace_token xray/config.json "__DOH_URL__" "$DOH_URL"
  replace_token xray/config.json "__XRAY_PORT__" "$XRAY_PORT"
  replace_token xray/config.json "__XRAY_UUID__" "$XRAY_UUID"
  replace_token xray/config.json "__XRAY_PATH__" "$XRAY_PATH_NORMALIZED"

  cat > generated/client.env <<EOF2
DOMAIN=${DOMAIN}
XRAY_UUID=${XRAY_UUID}
XRAY_PATH=${XRAY_PATH_NORMALIZED}
DOH_URL=${DOH_URL}
XRAY_FINGERPRINT=${XRAY_FINGERPRINT_VALUE}
CLIENT_SOCKS_UDP=${CLIENT_SOCKS_UDP}
CLIENT_SNIFF_QUIC=${CLIENT_SNIFF_QUIC}
CLIENT_ALPN=${CLIENT_ALPN}
CLIENT_MUX_ENABLED=${CLIENT_MUX_ENABLED}
CLIENT_MUX_CONCURRENCY=${CLIENT_MUX_CONCURRENCY}
CLIENT_MUX_XUDP_CONCURRENCY=${CLIENT_MUX_XUDP_CONCURRENCY}
CLIENT_MUX_XUDP_PROXY_UDP_443=${CLIENT_MUX_XUDP_PROXY_UDP_443:-}
EOF2

  chmod +x generate_client_config.py || true

  python3 generate_client_config.py \
    "$DOMAIN" \
    "$XRAY_UUID" \
    "$XRAY_PATH_NORMALIZED" \
    --doh "$DOH_URL" \
    --remark "$DOMAIN ws tls fallback" \
    --fingerprint "$XRAY_FINGERPRINT_VALUE" \
    --socks-udp "$CLIENT_SOCKS_UDP" \
    --sniff-quic "$CLIENT_SNIFF_QUIC" \
    --alpn "$CLIENT_ALPN" \
    --mux-enabled "$CLIENT_MUX_ENABLED" \
    --mux-concurrency "$CLIENT_MUX_CONCURRENCY" \
    --mux-xudp-concurrency "$CLIENT_MUX_XUDP_CONCURRENCY" \
    --mux-xudp-proxy-udp-443 "${CLIENT_MUX_XUDP_PROXY_UDP_443:-}" \
    -o generated/client-config.json
}

render_bootstrap_nginx() {
  cp nginx/conf.d/bootstrap.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"
}

render_tls_nginx() {
  prepare_cert_permissions

  local h3_listen_fragment=""
  local h3_http3_fragment=""
  local h3_headers_fragment=""

  if [[ "${EFFECTIVE_NGINX_HTTP3}" == "on" ]]; then
    h3_listen_fragment="    listen 443 quic reuseport;"
    h3_http3_fragment="    http3 on;"
    h3_headers_fragment="    add_header Alt-Svc 'h3=\":443\"; ma=__NGINX_ALTSVC_MAX_AGE__' always;
    add_header QUIC-Status \$http3 always;"
  fi

  cp nginx/conf.d/default.conf.template nginx/conf.d/default.conf
  replace_token nginx/conf.d/default.conf "__DOMAIN__" "$DOMAIN"
  replace_token nginx/conf.d/default.conf "__XRAY_PATH__" "$XRAY_PATH_NORMALIZED"
  replace_token nginx/conf.d/default.conf "__XRAY_PORT__" "$XRAY_PORT"
  replace_token nginx/conf.d/default.conf "__NGINX_HTTP2__" "$NGINX_HTTP2"
  replace_token nginx/conf.d/default.conf "__NGINX_H3_LISTEN_FRAGMENT__" "$h3_listen_fragment"
  replace_token nginx/conf.d/default.conf "__NGINX_HTTP3_FRAGMENT__" "$h3_http3_fragment"
  replace_token nginx/conf.d/default.conf "__NGINX_H3_HEADERS_FRAGMENT__" "$h3_headers_fragment"
  replace_token nginx/conf.d/default.conf "__NGINX_ALTSVC_MAX_AGE__" "$NGINX_ALTSVC_MAX_AGE"
  replace_token nginx/conf.d/default.conf "__NGINX_HSTS_MAX_AGE__" "$NGINX_HSTS_MAX_AGE"
  replace_token nginx/conf.d/default.conf "__NGINX_PROXY_READ_TIMEOUT__" "$NGINX_PROXY_READ_TIMEOUT"
  replace_token nginx/conf.d/default.conf "__NGINX_PROXY_SEND_TIMEOUT__" "$NGINX_PROXY_SEND_TIMEOUT"
}

cert_present() {
  [[ -f "certbot/conf/live/${DOMAIN}/fullchain.pem" && -f "certbot/conf/live/${DOMAIN}/privkey.pem" ]]
}

print_generated_files() {
  echo
  echo "===== xray/config.json ====="
  sed -n '1,260p' xray/config.json || true

  echo
  echo "===== nginx/conf.d/default.conf ====="
  sed -n '1,260p' nginx/conf.d/default.conf || true

  echo
  echo "===== generated/client.env ====="
  sed -n '1,160p' generated/client.env || true

  echo
  echo "===== generated/client-config.json ====="
  sed -n '1,360p' generated/client-config.json || true
}

start_bootstrap_nginx_for_acme() {
  log "Starting bootstrap nginx for ACME"
  docker compose up -d --force-recreate nginx
  sleep 2

  echo
  echo "Bootstrap nginx started. If certificate issuance fails, check:"
  echo "  - DOMAIN points to this VPS"
  echo "  - TCP/80 is open"
  echo "  - nothing else occupies port 80"
}

main() {
  log "Checking prerequisites"
  validate_settings
  check_required_files
  verify_nginx_http3_image
  ensure_default_site

  log "Stopping previous containers with the same names"
  docker compose down --remove-orphans 2>/dev/null || true
  docker rm -f nginx certbot xray 2>/dev/null || true

  log "Generating xray config and client artifacts"
  generate_xray_config

  if cert_present; then
    log "Certificate found. Rendering TLS nginx config"
    render_tls_nginx

    log "Starting full stack"
    docker compose up -d --force-recreate

    print_generated_files

    echo
    echo "Done."
    echo "Certificate already exists."
    if [[ "${EFFECTIVE_NGINX_HTTP3}" == "on" ]]; then
      echo "Services started in HTTPS + optional HTTP/3 fallback site + VLESS WS mode."
    else
      echo "Services started in HTTPS + VLESS WS mode. HTTP/3 is disabled."
    fi
    echo "Run ./check-stack.sh for diagnostics."
    exit 0
  fi

  log "Certificate not found. Rendering bootstrap HTTP-only nginx config"
  render_bootstrap_nginx

  log "Starting bootstrap mode"
  start_bootstrap_nginx_for_acme

  log "Issuing certificate via ./renew.sh"
  chmod +x renew.sh || true
  ./renew.sh issue

  if ! cert_present; then
    echo "ERROR: certificate still not found after ./renew.sh issue"
    exit 1
  fi

  log "Certificate issued. Rendering final TLS nginx config"
  render_tls_nginx

  log "Starting full stack in final mode"
  docker compose up -d --force-recreate

  print_generated_files

  echo
  echo "Done."
  echo "Certificate issued and full stack started."
  echo "Run ./check-stack.sh for diagnostics."
}

main "$@"
