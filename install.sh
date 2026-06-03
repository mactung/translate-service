#!/bin/sh
#
# Native install of LibreTranslate (no Docker) on Ubuntu 24+.
# Assumes the repo is cloned at /root/apps/translate-service.
#
# Usage (on the server, as root):
#   cd /root/apps/translate-service
#   ./install.sh                 # first run: create venv, install, register systemd, start
#   ./install.sh --reinstall     # force reinstall the python package
#
# Idempotent — re-running upgrades the package and reloads the service.

set -eu

REPO_DIR="/root/apps/translate-service"
VENV_DIR="$REPO_DIR/venv"
SERVICE_NAME="libretranslate"
SERVICE_SRC="$REPO_DIR/systemd/libretranslate.service"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"

REINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --reinstall) REINSTALL=1 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
cd "$REPO_DIR"

echo "[1/6] apt deps"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip build-essential libicu-dev pkg-config curl

if [ ! -d "$VENV_DIR" ]; then
  echo "[2/6] creating venv"
  python3 -m venv "$VENV_DIR"
else
  echo "[2/6] venv already exists"
fi

echo "[3/6] pip install libretranslate"
"$VENV_DIR/bin/pip" install --upgrade pip wheel >/dev/null
if [ "$REINSTALL" -eq 1 ]; then
  "$VENV_DIR/bin/pip" install --upgrade --force-reinstall libretranslate
else
  "$VENV_DIR/bin/pip" install --upgrade libretranslate
fi

echo "[4/6] installing systemd unit"
cp "$SERVICE_SRC" "$SERVICE_DST"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null

echo "[5/6] starting service (first start downloads Argos en→vi model, ~2 min)"
systemctl restart "$SERVICE_NAME"

echo "[6/6] waiting for /languages to respond"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:5050/languages >/dev/null 2>&1; then
    echo "    LibreTranslate is up"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "    Service didn't respond in 5 min — check: journalctl -u $SERVICE_NAME -n 100" >&2
    exit 1
  fi
  sleep 5
done

echo "Done. Smoke test:"
curl -sS -X POST http://127.0.0.1:5050/translate \
  -H 'Content-Type: application/json' \
  -d '{"q":"hello","source":"en","target":"vi","format":"text"}'
echo
