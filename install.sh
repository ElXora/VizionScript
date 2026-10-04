#!/usr/bin/env bash
# Vizion installer
API_URL="http://78.154.103.21:10532"
REPO_ZIP="https://github.com/ElXora/VizionScript/raw/refs/heads/main/main.zip"
PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
BP_URL="${REPO_ZIP%main.zip}fix.zip"   # fix.zip (Blueprint theme) sits next to main.zip in your repo

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

IP=$(curl -s --max-time 5 https://api.ipify.org)
BODY=$(printf '{"email":"%s","key":"%s","ip":"%s"}' "$EMAIL" "$KEY" "$IP")

echo -ne "\nVerifying license..."
RESP=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d "$BODY" "$API_URL/api/verify")
if [ -z "$RESP" ]; then echo -e "\n${R}✖ Could not reach the license server. Try again later.${N}"; exit 1; fi
if ! echo "$RESP" | grep -q '"success":true'; then
  MSG=$(echo "$RESP" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
  echo -e "\n${R}✖ ${MSG:-Invalid license}${N}"; exit 1
fi
echo -e " ${G}verified ✔${N}\n"

# Only what the license allows can be installed
LT=$(echo "$RESP" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
LV=$(echo "$RESP" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
if [ "$LT" = "blueprint" ] || [ "$LT" = "non-blueprint" ]; then
  TYPE="$LT"; echo -e "License type: ${G}$TYPE${N}"
else
  echo -e "1) Non-Blueprint\n2) Blueprint"; read -rp "Select type: " T
  [ "$T" = "2" ] && TYPE="blueprint" || TYPE="non-blueprint"
fi
if [ "$LV" = "2.0.8" ] || [ "$LV" = "2.1.0" ]; then
  VER="$LV"; echo -e "License version: ${G}$VER${N}"
else
  echo -e "\n1) 2.0.8\n2) 2.1.0"; read -rp "Select version: " V
  [ "$V" = "1" ] && VER="2.0.8" || VER="2.1.0"
fi

ZIP_URL="$REPO_ZIP"; [ "$TYPE" = "blueprint" ] && ZIP_URL="$BP_URL"

echo -e "\nDownloading Vizion ($TYPE $VER)..."
TMP=$(mktemp -d)
curl -fsSL -L "$ZIP_URL" -o "$TMP/v.zip" || { echo -e "${R}Download failed${N}"; exit 1; }
unzip -q "$TMP/v.zip" -d "$TMP/src" || { echo -e "${R}Unzip failed${N}"; exit 1; }
# NOTE: was "R=" which overwrote the red color variable -> renamed to RS
RS=$(find "$TMP/src" -type d -path '*/resources/scripts' | head -1)
if [ -n "$RS" ]; then SRC=$(dirname "$(dirname "$RS")"); else SRC=$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -1); SRC=${SRC:-$TMP/src}; fi

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

if [ "$TYPE" = "non-blueprint" ] || [ "$TYPE" = "blueprint" ]; then
  echo -e "\n${C}Building panel (this takes a few minutes)...${N}"
  command -v node >/dev/null || { echo -e "${R}Node.js is required to build. Install Node 18+ and run the commands below manually.${N}"; }
  command -v yarn >/dev/null || npm i -g yarn
  NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
  [ "${NODE_MAJOR:-0}" -ge 17 ] && export NODE_OPTIONS=--openssl-legacy-provider
  yarn install || { echo -e "${R}yarn install failed${N}"; exit 1; }
  [ -x node_modules/.bin/cross-env ] || yarn add cross-env
  [ -d node_modules/webpack-bundle-analyzer ] || yarn add -D webpack-bundle-analyzer

  # Fix: "[webpack-cli] TypeError: AssetsManifestPlugin is not a constructor"
  # webpack-assets-manifest v6+ switched to a named export; the panel config expects v5.
  AM_MAJOR=$(node -p "require('./node_modules/webpack-assets-manifest/package.json').version.split('.')[0]" 2>/dev/null)
  if [ "${AM_MAJOR:-0}" -ge 6 ]; then
    echo -e "${C}Pinning webpack-assets-manifest to 5.1.0...${N}"
    yarn add -D webpack-assets-manifest@5.1.0 --exact || { echo -e "${R}Could not pin webpack-assets-manifest${N}"; exit 1; }
  fi
  # Make the config tolerate either export style
  sed -i -E "s#^(const|let|var) +(\{ *)?([A-Za-z_]+)( *\})? *= *require\((['\"])webpack-assets-manifest\5\)(\.[A-Za-z]+)?;#\1 \3 = (m => m.WebpackAssetsManifest || m.default || m)(require(\5webpack-assets-manifest\5));#" webpack.config.js
  # Write the manifest as manifest.json (what the panel reads)
  sed -i "s/new AssetsManifestPlugin({ writeToDisk: true,/new AssetsManifestPlugin({ output: 'manifest.json', writeToDisk: true,/" webpack.config.js

  # Webpack compatibility fixes (installed webpack version decides which apply)
  WP_MAJOR=$(node -p "require('./node_modules/webpack/package.json').version.split('.')[0]" 2>/dev/null)
  TP_MAJOR=$(node -p "require('./node_modules/terser-webpack-plugin/package.json').version.split('.')[0]" 2>/dev/null)
  if [ "${WP_MAJOR:-5}" -ge 5 ]; then
    # Webpack 5: terser plugin must be v5+, its old `cache` option is gone
    if [ "${TP_MAJOR:-0}" -lt 5 ]; then
      echo -e "${C}Installing terser-webpack-plugin v5...${N}"
      yarn add -D terser-webpack-plugin@^5 || { echo -e "${R}Could not install terser-webpack-plugin${N}"; exit 1; }
    fi
    sed -i -E '/^\s*cache:\s*(true|false),?\s*$/d' webpack.config.js
    # Remove the old `cache` option inside TerserPlugin(...)
    sed -i -E '/TerserPlugin\(/,/\}\)/ s/\bcache:[[:space:]]*[a-zA-Z]+[[:space:]]*,?//' webpack.config.js
    # Webpack 5: no automatic Node polyfills -> "Can't resolve 'path'"
    [ -d node_modules/path-browserify ] || yarn add -D path-browserify || { echo -e "${R}Could not install path-browserify${N}"; exit 1; }
    grep -q "path-browserify" webpack.config.js || sed -i -E "0,/^(\s*)resolve:\s*\{/s//&\n\1    fallback: { path: require.resolve('path-browserify') },/" webpack.config.js
  elif [ "${TP_MAJOR:-0}" -ge 5 ]; then
    # Webpack 4: needs terser-webpack-plugin v4
    echo -e "${C}Pinning terser-webpack-plugin to 4.2.3...${N}"
    yarn add -D terser-webpack-plugin@4.2.3 --exact || { echo -e "${R}Could not pin terser-webpack-plugin${N}"; exit 1; }
  fi

  if [ "$TYPE" = "blueprint" ]; then
    echo -e "${C}Installing Blueprint theme packages...${N}"
    for P in "framer-motion@^6.3.10" "@preact/signals-react@^1.2.1" "react-chartjs-2@^4.2.0" "chart.js@^3.8.0" "boring-avatars@^1.7.0" "use-fit-text@^2.4.0" "deepmerge-ts@^4.2.1" "qrcode.react@^1.0.1" "xterm-addon-unicode11@^0.6.0"; do
      [ -d "node_modules/${P%@^*}" ] || yarn add "$P" || { echo -e "${R}Could not install $P${N}"; exit 1; }
    done
  fi

  yarn build:production || { echo -e "${R}Build failed - theme not active. Fix the error above and run: yarn build:production${N}"; exit 1; }
  # Make sure the panel finds its manifest
  [ -f public/assets/assets-manifest.json ] && cp public/assets/assets-manifest.json public/assets/manifest.json
fi

# Clear Laravel caches/views to prevent stale frontend references / white screen
php artisan view:clear
php artisan config:clear
php artisan route:clear
php artisan cache:clear

# Rebuild Laravel cache and restore runtime permissions to prevent 500 errors
php artisan optimize:clear
php artisan optimize
php artisan queue:restart
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || chown -R nginx:nginx storage bootstrap/cache 2>/dev/null
find "$PANEL_DIR" -path "$PANEL_DIR/node_modules" -prune -o -type d -exec chmod 755 {} \; 2>/dev/null
find "$PANEL_DIR" -path "$PANEL_DIR/node_modules" -prune -o -type f -exec chmod 644 {} \; 2>/dev/null
chmod -R 775 storage/* bootstrap/cache/
chown -R www-data:www-data "$PANEL_DIR"/* 2>/dev/null || chown -R nginx:nginx "$PANEL_DIR"/* 2>/dev/null
echo -e "\n${G}✔ Vizion installed. Hard-refresh your browser (Ctrl+Shift+R).${N}"
