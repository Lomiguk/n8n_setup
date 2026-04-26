#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
ENV_FILE="${ENV_FILE:-.env}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-300}"
HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-5}"

info() {
  printf '[INFO] %s\n' "$1"
}

fail() {
  printf '[ERROR] %s\n' "$1" >&2
  exit 1
}

if [ ! -f "$ENV_FILE" ]; then
  fail "Missing $ENV_FILE. Copy .env.example to .env and fill in secure values first."
fi

read_env_value() {
  local key="$1"
  local line

  line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%$'\r'}"
  line="${line%\"}"
  line="${line#\"}"
  line="${line%\'}"
  line="${line#\'}"
  printf '%s' "$line"
}

TRAEFIK_PUBLIC_NETWORK="$(read_env_value TRAEFIK_PUBLIC_NETWORK)"
APP_INTERNAL_NETWORK="$(read_env_value APP_INTERNAL_NETWORK)"
DOMAIN_N8N="$(read_env_value DOMAIN_N8N)"

: "${TRAEFIK_PUBLIC_NETWORK:?TRAEFIK_PUBLIC_NETWORK is required in .env}"
: "${APP_INTERNAL_NETWORK:?APP_INTERNAL_NETWORK is required in .env}"
: "${DOMAIN_N8N:?DOMAIN_N8N is required in .env}"

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not in PATH."
fi

if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose v2 is required. Install the docker compose plugin."
fi

create_network_if_missing() {
  local network_name="$1"

  if docker network inspect "$network_name" >/dev/null 2>&1; then
    info "Docker network '$network_name' already exists."
    return
  fi

  info "Creating Docker network '$network_name'."
  docker network create "$network_name" >/dev/null
}

create_network_if_missing "$TRAEFIK_PUBLIC_NETWORK"
create_network_if_missing "$APP_INTERNAL_NETWORK"

mkdir -p backups

info "Starting reverse proxy first so ACME and routing are ready."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d traefik

info "Starting database, MinIO, Dozzle, and n8n."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d postgres minio dozzle n8n backup

health_url="https://${DOMAIN_N8N}/healthz"
deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))

info "Polling n8n health endpoint: $health_url"
while [ "$SECONDS" -lt "$deadline" ]; do
  status_code="$(curl -k -s -o /dev/null -w '%{http_code}' "$health_url" || true)"

  case "$status_code" in
    200|302|401)
      info "n8n is reachable with HTTP status $status_code."
      info "Deployment completed successfully."
      exit 0
      ;;
    *)
      printf '[WAIT] n8n returned HTTP status %s. Retrying in %ss...\n' "$status_code" "$HEALTH_INTERVAL_SECONDS"
      sleep "$HEALTH_INTERVAL_SECONDS"
      ;;
  esac
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
fail "Timed out after ${HEALTH_TIMEOUT_SECONDS}s waiting for n8n at $health_url."
