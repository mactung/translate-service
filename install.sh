#!/bin/sh
#
# Native install of translate-service (FastAPI + ctranslate2 + NLLB-200-distilled-600M)
# on Ubuntu 24+. Assumes the repo is cloned at /root/apps/translate-service.
#
# Usage (on the server, as root):
#   cd /root/apps/translate-service
#   ./install.sh                       # first run: venv, pip, download+convert model, register systemd, start
#   ./install.sh --reinstall-deps      # force pip reinstall
#   ./install.sh --reconvert-model     # force model re-download + re-convert
#
# Idempotent — re-running upgrades python deps and reloads the service.

set -eu

REPO_DIR="/root/apps/translate-service"
VENV_DIR="$REPO_DIR/venv"
MODEL_DIR="$REPO_DIR/models/opus-mt-en-vi-ct2"
OLD_MODEL_DIRS="$REPO_DIR/models/nllb-200-distilled-600M-ct2"
SERVICE_NAME="translate-service"
SERVICE_SRC="$REPO_DIR/systemd/${SERVICE_NAME}.service"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"
OLD_SERVICE_NAME="libretranslate"  # cleanup from the previous deploy

REINSTALL_DEPS=0
RECONVERT=0
for arg in "$@"; do
  case "$arg" in
    --reinstall-deps)  REINSTALL_DEPS=1 ;;
    --reconvert-model) RECONVERT=1 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
cd "$REPO_DIR"

echo "[1/6] stop & remove any prior libretranslate service + old NLLB model dir"
if systemctl list-unit-files | grep -q "^${OLD_SERVICE_NAME}\.service"; then
  systemctl stop "$OLD_SERVICE_NAME" || true
  systemctl disable "$OLD_SERVICE_NAME" || true
  rm -f "/etc/systemd/system/${OLD_SERVICE_NAME}.service"
  systemctl daemon-reload
fi
for old in $OLD_MODEL_DIRS; do
  if [ -d "$old" ]; then
    echo "    removing old model: $old"
    rm -rf "$old"
  fi
done

echo "[2/6] apt deps (skipped if already present)"
need_apt=""
for pkg in python3 python3-venv python3-pip build-essential curl; do
  dpkg -s "$pkg" >/dev/null 2>&1 || need_apt="$need_apt $pkg"
done
if [ -n "$need_apt" ]; then
  apt-get update -qq
  apt-get install -y -qq $need_apt
else
  echo "    all apt deps already installed"
fi

if [ ! -d "$VENV_DIR" ]; then
  echo "[3/6] creating venv"
  python3 -m venv "$VENV_DIR"
else
  echo "[3/6] venv already exists"
fi

echo "[4/6] pip install requirements"
"$VENV_DIR/bin/pip" install --upgrade pip wheel >/dev/null
if [ "$REINSTALL_DEPS" -eq 1 ]; then
  "$VENV_DIR/bin/pip" install --upgrade --force-reinstall -r requirements.txt
else
  "$VENV_DIR/bin/pip" install --upgrade -r requirements.txt
fi

echo "[5/6] download + convert OPUS-MT en→vi model (one-time, ~300 MB download)"
if [ "$RECONVERT" -eq 1 ]; then
  "$VENV_DIR/bin/python" scripts/download_model.py --force
else
  "$VENV_DIR/bin/python" scripts/download_model.py
fi

echo "[6/6] installing + starting systemd unit"
cp "$SERVICE_SRC" "$SERVICE_DST"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"

echo "Waiting for /health to respond"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:5050/health >/dev/null 2>&1; then
    echo "    service is up"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "    service didn't respond in 5 min — check: journalctl -u $SERVICE_NAME -n 100" >&2
    exit 1
  fi
  sleep 5
done

echo "Done. Smoke test:"
curl -sS -X POST http://127.0.0.1:5050/translate \
  -H 'Content-Type: application/json' \
  -d '{"q":"hello","source":"en","target":"vi","format":"text"}'
echo
