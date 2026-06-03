#!/bin/sh
#
# Deploy translate-service (LibreTranslate) on the Contabo Ubuntu server.
#
# Usage:
#   ./deploy.sh              # pull latest image, restart container, healthcheck
#   ./deploy.sh --no-pull    # skip image pull (use whatever is cached locally)
#   ./deploy.sh --no-health  # skip post-start healthcheck
#
# Assumes Docker + Compose v2 plugin are installed.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SKIP_PULL=0
SKIP_HEALTH=0
for arg in "$@"; do
  case "$arg" in
    --no-pull)   SKIP_PULL=1 ;;
    --no-health) SKIP_HEALTH=1 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

ts()   { date +'%H:%M:%S'; }
log()  { echo "[$(ts)] $*"; }
fail() { echo "[$(ts)] x $*" >&2; exit 1; }

[ -f docker-compose.yml ] || fail "docker-compose.yml missing"
command -v docker >/dev/null 2>&1 || fail "docker not installed"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin missing"

if [ "$SKIP_PULL" -eq 0 ]; then
  log "Pulling latest libretranslate image"
  docker compose pull
fi

log "Starting / updating container"
docker compose up -d --remove-orphans

if [ "$SKIP_HEALTH" -eq 0 ]; then
  log "Waiting for healthcheck (first start downloads models, may take 2-3 min)"
  for i in $(seq 1 60); do
    status=$(docker inspect --format='{{.State.Health.Status}}' translate-service 2>/dev/null || echo "starting")
    if [ "$status" = "healthy" ]; then
      log "Healthy after ${i} checks"
      exit 0
    fi
    sleep 5
  done
  fail "Container did not become healthy in 5 min — check 'docker logs translate-service'"
fi

log "Done"
