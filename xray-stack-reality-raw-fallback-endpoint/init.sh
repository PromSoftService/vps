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

mkdir -p nginx/conf.d xray site generated

required_vars=(
  DOMAIN
  XRAY_PORT
  XRAY_UUID
  XRAY_LOGLEVEL
  XRAY_FLOW
  REALITY_TARGET
  REALITY_SERVER_NAMES
  REALITY_FINGERPRINT
  REALITY_SPIDERX
  NGINX_FALLBACK_PORT
  NGINX_SERVER_NAME
  XRAY_IMAGE
  NGINX_IMAGE
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: required variable '$var_name' is empty"
    exit 1
  fi
done

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
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

json_quote() {
  local value="$1"
  python3 - <<'PY' "$value"
import json
import sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
}

server_names_to_json() {
  python3 - "$1" <<'PY'
import json, sys
raw = sys.argv[1]
items = [part.strip() for part in raw.split(',') if part.strip()]
if not items:
    raise SystemExit("REALITY_SERVER_NAMES is empty after parsing")
print(', '.join(json.dumps(x) for x in items))
PY
}

run_docker_capture() {
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  printf '%s' "$output"
  return "$status"
}

ensure_reality_private_key() {
  local current="${REALITY_PRIVATE_KEY:-}"
  if [[ -n "$current" && "$current" != "AUTO" ]]; then
    printf '%s' "$current"
    return 0
  fi

  echo "Generating REALITY x25519 key pair via Xray image..." >&2

  local out
  if ! out="$(run_docker_capture docker run --rm "$XRAY_IMAGE" x25519)"; then
    printf '%s\n' "$out" > generated/x25519.txt
    echo "ERROR: docker failed while generating REALITY key pair" >&2
    echo "----- generated/x25519.txt -----" >&2
    cat generated/x25519.txt >&2 || true
    echo "--------------------------------" >&2
    exit 1
  fi

  printf '%s\n' "$out" > generated/x25519.txt

  local private_key
  private_key="$(
    printf '%s\n' "$out" | sed -nE '
      s/^[[:space:]]*Private key:[[:space:]]*(.+)[[:space:]]*$/\1/p
      s/^[[:space:]]*PrivateKey:[[:space:]]*(.+)[[:space:]]*$/\1/p
    ' | head -n1
  )"

  if [[ -z "$private_key" ]]; then
    echo "ERROR: failed to parse REALITY private key from x25519 output" >&2
    echo "----- generated/x25519.txt -----" >&2
    cat generated/x25519.txt >&2 || true
    echo "--------------------------------" >&2
    exit 1
  fi

  printf '%s' "$private_key"
}

derive_public_key() {
  local private_key="$1"
  local out

  if ! out="$(run_docker_capture docker run --rm "$XRAY_IMAGE" x25519 -i "$private_key")"; then
    printf '%s\n' "$out" > generated/x25519-public.txt
    echo "ERROR: docker failed while deriving REALITY public key" >&2
    echo "----- generated/x25519-public.txt -----" >&2
    cat generated/x25519-public.txt >&2 || true
    echo "---------------------------------------" >&2
    exit 1
  fi

  printf '%s\n' "$out" > generated/x25519-public.txt

  local public_key
  public_key="$(
    printf '%s\n' "$out" | sed -nE '
      s/^[[:space:]]*Public key:[[:space:]]*(.+)[[:space:]]*$/\1/p
      s/^[[:space:]]*PublicKey:[[:space:]]*(.+)[[:space:]]*$/\1/p
      s/^[[:space:]]*Password:[[:space:]]*(.+)[[:space:]]*$/\1/p
      s/^[[:space:]]*Password[[:space:]]+\(PublicKey\):[[:space:]]*(.+)[[:space:]]*$/\1/p
    ' | head -n1
  )"

  if [[ -z "$public_key" ]]; then
    echo "ERROR: failed to derive REALITY public key from private key" >&2
    echo "----- generated/x25519-public.txt -----" >&2
    cat generated/x25519-public.txt >&2 || true
    echo "---------------------------------------" >&2
    exit 1
  fi

  printf '%s' "$public_key"
}

ensure_short_id() {
  local current="${REALITY_SHORT_ID:-}"
  if [[ -n "$current" && "$current" != "AUTO" ]]; then
    printf '%s' "$current"
    return 0
  fi
  openssl rand -hex 8
}

validate_yes_no() {
  local value="$1"
  local name="$2"

  case "$value" in
    yes|no)
      ;;
    *)
      echo "ERROR: $name must be 'yes' or 'no'"
      exit 1
      ;;
  esac
}

validate_bool_string() {
  local value="$1"
  local name="$2"

  case "$value" in
    true|false)
      ;;
    *)
      echo "ERROR: $name must be 'true' or 'false'"
      exit 1
      ;;
  esac
}

validate_int_string() {
  local value="$1"
  local name="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $name must be an integer"
    exit 1
  fi
}

validate_runtime_options() {
  validate_yes_no "${SERVER_SOCKOPT_ENABLED:-no}" "SERVER_SOCKOPT_ENABLED"
  validate_yes_no "${REALITY_MUX_ENABLED:-no}" "REALITY_MUX_ENABLED"
  validate_yes_no "${CLIENT_SOCKOPT_ENABLED:-no}" "CLIENT_SOCKOPT_ENABLED"

  if [[ "${SERVER_SOCKOPT_ENABLED:-no}" == "yes" ]]; then
    validate_bool_string "${SERVER_SOCKOPT_TCP_FAST_OPEN:-false}" "SERVER_SOCKOPT_TCP_FAST_OPEN"
    validate_int_string "${SERVER_SOCKOPT_TCP_KEEP_ALIVE_IDLE:-300}" "SERVER_SOCKOPT_TCP_KEEP_ALIVE_IDLE"
    validate_int_string "${SERVER_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL:-0}" "SERVER_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL"
  fi

  if [[ "${REALITY_MUX_ENABLED:-no}" == "yes" ]]; then
    validate_int_string "${REALITY_MUX_CONCURRENCY:-8}" "REALITY_MUX_CONCURRENCY"
    validate_int_string "${REALITY_MUX_XUDP_CONCURRENCY:-16}" "REALITY_MUX_XUDP_CONCURRENCY"
  fi

  if [[ "${CLIENT_SOCKOPT_ENABLED:-no}" == "yes" ]]; then
    validate_bool_string "${CLIENT_SOCKOPT_TCP_FAST_OPEN:-false}" "CLIENT_SOCKOPT_TCP_FAST_OPEN"
    validate_int_string "${CLIENT_SOCKOPT_TCP_KEEP_ALIVE_IDLE:-300}" "CLIENT_SOCKOPT_TCP_KEEP_ALIVE_IDLE"
    validate_int_string "${CLIENT_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL:-0}" "CLIENT_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL"
  fi
}

build_server_sockopt_fragment() {
  if [[ "${SERVER_SOCKOPT_ENABLED:-no}" != "yes" ]]; then
    echo ""
    return
  fi

  python3 - <<'PY'
import json
import os

sockopt = {
    "tcpFastOpen": os.environ.get("SERVER_SOCKOPT_TCP_FAST_OPEN", "false") == "true",
    "tcpKeepAliveIdle": int(os.environ.get("SERVER_SOCKOPT_TCP_KEEP_ALIVE_IDLE", "300")),
    "tcpKeepAliveInterval": int(os.environ.get("SERVER_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL", "0")),
}

print(', "sockopt": ' + json.dumps(sockopt, ensure_ascii=False, separators=(",", ":")))
PY
}

REALITY_PRIVATE_KEY_EFFECTIVE="$(ensure_reality_private_key)"
REALITY_PUBLIC_KEY_EFFECTIVE="$(derive_public_key "$REALITY_PRIVATE_KEY_EFFECTIVE")"
REALITY_SHORT_ID_EFFECTIVE="$(ensure_short_id)"
REALITY_SERVER_NAMES_JSON="$(server_names_to_json "$REALITY_SERVER_NAMES")"
REALITY_SERVER_NAME_PRIMARY="$(trim "${REALITY_SERVER_NAMES%%,*}")"

validate_runtime_options

SERVER_SOCKOPT_FRAGMENT="$(build_server_sockopt_fragment)"

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

if [[ ! -f xray/config.json.template ]]; then
  echo "ERROR: xray/config.json.template not found"
  exit 1
fi

if [[ ! -f nginx/conf.d/default.conf.template ]]; then
  echo "ERROR: nginx/conf.d/default.conf.template not found"
  exit 1
fi

cp xray/config.json.template xray/config.json
cp nginx/conf.d/default.conf.template nginx/conf.d/default.conf

replace_token xray/config.json "__XRAY_LOGLEVEL__" "$XRAY_LOGLEVEL"
replace_token xray/config.json "__XRAY_PORT__" "$XRAY_PORT"
replace_token xray/config.json "__XRAY_UUID__" "$XRAY_UUID"
replace_token xray/config.json "__XRAY_FLOW__" "$XRAY_FLOW"
replace_token xray/config.json "__NGINX_FALLBACK_PORT__" "$NGINX_FALLBACK_PORT"
replace_token xray/config.json "__REALITY_TARGET__" "$REALITY_TARGET"
replace_token xray/config.json "__REALITY_PRIVATE_KEY__" "$REALITY_PRIVATE_KEY_EFFECTIVE"
replace_token xray/config.json "__REALITY_SHORT_ID__" "$REALITY_SHORT_ID_EFFECTIVE"
replace_token xray/config.json "__REALITY_SERVER_NAMES_JSON__" "$REALITY_SERVER_NAMES_JSON"
replace_token xray/config.json "__SERVER_SOCKOPT_FRAGMENT__" "$SERVER_SOCKOPT_FRAGMENT"

replace_token nginx/conf.d/default.conf "__NGINX_FALLBACK_PORT__" "$NGINX_FALLBACK_PORT"
replace_token nginx/conf.d/default.conf "__NGINX_SERVER_NAME__" "$NGINX_SERVER_NAME"

chmod +x check-reality.sh generate_client_config.py || true

cat > generated/client.env <<EOF2
DOMAIN=${DOMAIN}
XRAY_UUID=${XRAY_UUID}
REALITY_SERVER_NAME=${REALITY_SERVER_NAME_PRIMARY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY_EFFECTIVE}
REALITY_SHORT_ID=${REALITY_SHORT_ID_EFFECTIVE}
REALITY_FINGERPRINT=${REALITY_FINGERPRINT}
REALITY_SPIDERX=${REALITY_SPIDERX}
REALITY_MUX_ENABLED=${REALITY_MUX_ENABLED:-no}
REALITY_MUX_CONCURRENCY=${REALITY_MUX_CONCURRENCY:-8}
REALITY_MUX_XUDP_CONCURRENCY=${REALITY_MUX_XUDP_CONCURRENCY:-16}
REALITY_MUX_XUDP_PROXY_UDP_443=${REALITY_MUX_XUDP_PROXY_UDP_443:-reject}
CLIENT_SOCKOPT_ENABLED=${CLIENT_SOCKOPT_ENABLED:-no}
CLIENT_SOCKOPT_TCP_FAST_OPEN=${CLIENT_SOCKOPT_TCP_FAST_OPEN:-false}
CLIENT_SOCKOPT_TCP_KEEP_ALIVE_IDLE=${CLIENT_SOCKOPT_TCP_KEEP_ALIVE_IDLE:-300}
CLIENT_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL=${CLIENT_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL:-0}
EOF2

client_args=(
  "$DOMAIN"
  "$XRAY_UUID"
  "$REALITY_SERVER_NAME_PRIMARY"
  "$REALITY_PUBLIC_KEY_EFFECTIVE"
  "$REALITY_SHORT_ID_EFFECTIVE"
  --fingerprint "$REALITY_FINGERPRINT"
  --spiderx "$REALITY_SPIDERX"
  --remark "$DOMAIN reality raw"
  -o generated/client-config.json
)

if [[ "${REALITY_MUX_ENABLED:-no}" == "yes" ]]; then
  client_args+=(
    --mux-enabled
    --mux-concurrency "${REALITY_MUX_CONCURRENCY:-8}"
    --mux-xudp-concurrency "${REALITY_MUX_XUDP_CONCURRENCY:-16}"
    --mux-xudp-proxy-udp-443 "${REALITY_MUX_XUDP_PROXY_UDP_443:-reject}"
  )
fi

if [[ "${CLIENT_SOCKOPT_ENABLED:-no}" == "yes" ]]; then
  client_args+=(
    --client-sockopt-enabled
    --client-sockopt-tcp-fast-open "${CLIENT_SOCKOPT_TCP_FAST_OPEN:-false}"
    --client-sockopt-tcp-keep-alive-idle "${CLIENT_SOCKOPT_TCP_KEEP_ALIVE_IDLE:-300}"
    --client-sockopt-tcp-keep-alive-interval "${CLIENT_SOCKOPT_TCP_KEEP_ALIVE_INTERVAL:-0}"
  )
fi

python3 generate_client_config.py "${client_args[@]}"

echo "Testing Xray config syntax..."
docker run --rm --network host -v "$ROOT_DIR/xray:/usr/local/etc/xray:ro" "$XRAY_IMAGE" run -test -config /usr/local/etc/xray/config.json

echo "Recreating services..."
docker compose up -d --force-recreate xray nginx

echo
echo "===== xray/config.json ====="
sed -n '1,260p' xray/config.json

echo
echo "===== nginx/conf.d/default.conf ====="
sed -n '1,200p' nginx/conf.d/default.conf

echo
echo "===== generated/client.env ====="
cat generated/client.env

echo
echo "===== generated/client-config.json ====="
sed -n '1,260p' generated/client-config.json