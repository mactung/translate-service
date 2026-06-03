#!/bin/sh
#
# Install nginx config for translate-service on the Ubuntu server.
# HTTP-only — no TLS, no certbot. Idempotent.
#
# Pre-reqs:
#   - LibreTranslate already running on 127.0.0.1:5050 (./deploy.sh)
#   - Port 80 open in the firewall
#   - DNS points the desired hostname(s) to this server

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITE_NAME="translate-service"
CONF_SRC="$SCRIPT_DIR/translate.shadowingenglish.com.conf"
CONF_DST="/etc/nginx/sites-available/${SITE_NAME}"
LINK_DST="/etc/nginx/sites-enabled/${SITE_NAME}"

[ -f "$CONF_SRC" ] || { echo "Missing $CONF_SRC" >&2; exit 1; }

if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx"
  sudo apt-get update
  sudo apt-get install -y nginx
fi

echo "Copying site config to $CONF_DST"
sudo cp "$CONF_SRC" "$CONF_DST"

if [ ! -L "$LINK_DST" ]; then
  echo "Enabling site"
  sudo ln -s "$CONF_DST" "$LINK_DST"
fi

echo "Testing nginx config"
sudo nginx -t

echo "Reloading nginx"
sudo systemctl reload nginx

echo "Done. Verify:"
echo "  curl -sS http://translate.shadowingenglish.com/languages | head -c 200"
