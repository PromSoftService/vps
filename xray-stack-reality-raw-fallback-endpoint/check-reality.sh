#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f ".env" ]]; then
  echo "ERROR: .env not found"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "== 1. recreate services =="
docker compose down || true
docker compose up -d --force-recreate

echo
echo "== 2. docker compose ps =="
docker compose ps || true

echo
echo "== 3. xray config syntax =="
docker run --rm \
  --network host \
  -v "$ROOT_DIR/xray:/usr/local/etc/xray:ro" \
  "$XRAY_IMAGE" \
  run -test -config /usr/local/etc/xray/config.json || true

echo
echo "== 4. xray logs =="
docker compose logs --tail=100 xray || true

echo
echo "== 5. nginx logs =="
docker compose logs --tail=100 nginx || true

echo
echo "== 6. rendered xray config =="
sed -n '1,260p' xray/config.json || true

echo
echo "== 7. rendered nginx config =="
sed -n '1,220p' nginx/conf.d/default.conf || true

echo
echo "== 8. generated client env =="
sed -n '1,120p' generated/client.env || true

echo
echo "== 9. generated client config =="
sed -n '1,260p' generated/client-config.json || true

echo
echo "== 10. follow logs (Ctrl+C to stop) =="
docker compose logs -f nginx xray