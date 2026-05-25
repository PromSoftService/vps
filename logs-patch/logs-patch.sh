#!/usr/bin/env bash
set -euo pipefail

echo "=== check docker-compose.yml ==="
if [ ! -f docker-compose.yml ]; then
  echo "ERROR: run this from toolkit root with docker-compose.yml"
  exit 1
fi

echo "=== remove broken override if exists ==="
rm -f docker-compose.override.yml

echo "=== detect services from base docker-compose.yml only ==="
SERVICES="$(docker compose -f docker-compose.yml config --services)"

if [ -z "$SERVICES" ]; then
  echo "ERROR: no services found in docker-compose.yml"
  exit 1
fi

echo "$SERVICES"

echo "=== write docker-compose.override.yml with docker log rotation ==="
TMP_FILE=".docker-compose.override.yml.tmp"

{
  echo "services:"
  for svc in $SERVICES; do
    cat <<EOF
  $svc:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
  done
} > "$TMP_FILE"

echo "=== validate generated override ==="
docker compose -f docker-compose.yml -f "$TMP_FILE" config >/dev/null

mv "$TMP_FILE" docker-compose.override.yml

echo "=== truncate current container logs for this compose project ==="
IDS="$(docker compose -f docker-compose.yml -f docker-compose.override.yml ps -aq || true)"

if [ -n "$IDS" ]; then
  for cid in $IDS; do
    log_path="$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null || true)"
    if [ -n "$log_path" ] && [ -f "$log_path" ]; then
      echo "truncate: $cid -> $log_path"
      sudo truncate -s 0 "$log_path"
    fi
  done
else
  echo "no existing containers for this compose project"
fi

echo "=== recreate containers so logging limits apply ==="
docker compose up -d --force-recreate

echo "=== status ==="
docker compose ps

echo "=== applied docker log config ==="
IDS="$(docker compose ps -q || true)"
if [ -n "$IDS" ]; then
  docker inspect $IDS --format '{{.Name}} {{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}}'
else
  echo "no running containers"
fi

echo "=== done ==="
