#!/usr/bin/env bash
# Vizion installer
API_URL="http://78.154.103.21:10532"   # <- your bot address (Wispbyte IP or domain + port)
REPO_ZIP="https://github.com/ElXora/VizionScript/raw/refs/heads/main/main.zip"   # <- your main.zip on GitHub
PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"

C='\033[1;36m'; G='\033[1;32m'; R='\033[1;31m'; N='\033[0m'
clear; echo -e "${C}
 __     ___ _____ ___ ___  _  _
 \\ \\   / /_ _|__  / |_ _|/ _ \\| \\| |
  \\ \\ / / | |  / /   | || (_) | .\` |
   \\ V / |___|/___| |___|\\___/|_|\\_|
${N}        Vizion Installer\n"

for c in curl unzip; do command -v $c >/dev/null || { echo -e "${R}$c is required (apt install -y $c)${N}"; exit 1; }; done

read -rp "Email used for your license: " EMAIL
read -rp "License key: " KEY
EMAIL=$(echo "$EMAIL" | tr -d '\r' | xargs); KEY=$(echo "$KEY" | tr -d '\r' | xargs)
echo -e "\n1) Non-Blueprint\n2) Blueprint"; read -rp "Select type: " T
[ "$T" = "2" ] && TYPE="blueprint" || TYPE="non-blueprint"
echo -e "\n1) 2.0.8\n2) 2.1.0"; read -rp "Select version: " V
[ "$V" = "1" ] && VER="2.0.8" || VER="2.1.0"

IP=$(curl -s --max-time 5 https://api.ipify.org)
BODY=$(printf '{"email":"%s","key":"%s","ip":"%s","requestedType":"%s","requestedVersion":"%s"}' "$EMAIL" "$KEY" "$IP" "$TYPE" "$VER")

echo -ne "\nVerifying license..."
RESP=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d "$BODY" "$API_URL/api/verify")
if [ -z "$RESP" ]; then echo -e "\n${R}✖ Could not reach the license server. Try again later.${N}"; exit 1; fi
if ! echo "$RESP" | grep -q '"success":true'; then
  MSG=$(echo "$RESP" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
  echo -e "\n${R}✖ ${MSG:-Invalid license}${N}"; exit 1
fi
echo -e " ${G}verified ✔${N}\n"

echo "Downloading Vizion ($TYPE $VER)..."
TMP=$(mktemp -d)
curl -fsSL -L "$REPO_ZIP" -o "$TMP/v.zip" || { echo -e "${R}Download failed${N}"; exit 1; }
unzip -q "$TMP/v.zip" -d "$TMP/src" || { echo -e "${R}Unzip failed${N}"; exit 1; }
R=$(find "$TMP/src" -type d -path '*/resources/scripts' | head -1)
if [ -n "$R" ]; then SRC=$(dirname "$(dirname "$R")"); else SRC=$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -1); SRC=${SRC:-$TMP/src}; fi

read -rp "Install into $PANEL_DIR ? [y/N]: " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; rm -rf "$TMP"; exit 0; }
[ -f "$PANEL_DIR/artisan" ] || { echo -e "${R}No Pterodactyl panel found in $PANEL_DIR (set PANEL_DIR=/your/path)${N}"; exit 1; }
cp -a "$SRC"/. "$PANEL_DIR"/
rm -rf "$TMP"
cd "$PANEL_DIR" || exit 1
chown -R www-data:www-data "$PANEL_DIR"/* 2>/dev/null || chown -R nginx:nginx "$PANEL_DIR"/* 2>/dev/null

# Fix Laravel runtime permissions / stale cache that can cause 500 errors
mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views bootstrap/cache
rm -rf storage/framework/cache/data/* storage/framework/views/*
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || chown -R nginx:nginx storage bootstrap/cache 2>/dev/null
chmod -R ug+rwX storage bootstrap/cache

if [ "$TYPE" = "non-blueprint" ]; then
  echo -e "\n${C}Building panel (this takes a few minutes)...${N}"
  command -v node >/dev/null || { echo -e "${R}Node.js is required to build. Install Node 18+ and run the commands below manually.${N}"; }
  command -v yarn >/dev/null || npm i -g yarn
  NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
  [ "${NODE_MAJOR:-0}" -ge 17 ] && export NODE_OPTIONS=--openssl-legacy-provider
  yarn install || { echo -e "${R}yarn install failed${N}"; exit 1; }
  [ -x node_modules/.bin/cross-env ] || yarn add cross-env
  [ -d node_modules/webpack-bundle-analyzer ] || yarn add -D webpack-bundle-analyzer
  yarn build:production || { echo -e "${R}Build failed - theme not active. Fix the error above and run: yarn build:production${N}"; exit 1; }
else
  echo -e "\n${C}Blueprint: rebuild with your Blueprint command (e.g. blueprint -rerun-install) after this.${N}"
fi

# Clear Laravel caches/views to prevent stale frontend references / white screen
php artisan view:clear
php artisan config:clear
php artisan route:clear
php artisan cache:clear

# Rebuild Laravel cache and restore runtime permissions to prevent 500 errors
php artisan optimize
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || chown -R nginx:nginx storage bootstrap/cache 2>/dev/null
chmod -R ug+rwX storage bootstrap/cache
chown -R www-data:www-data "$PANEL_DIR"/* 2>/dev/null || chown -R nginx:nginx "$PANEL_DIR"/* 2>/dev/null
echo -e "\n${G}✔ Vizion installed. Hard-refresh your browser (Ctrl+Shift+R).${N}"
