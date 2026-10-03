#!/usr/bin/env bash

# Vizion Installer

API_URL="http://78.154.103.21:10532"
REPO_ZIP="https://github.com/ElXora/VizionScript/raw/refs/heads/main/main.zip"
PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"

C='\033[1;36m'
G='\033[1;32m'
R='\033[1;31m'
Y='\033[1;33m'
N='\033[0m'

clear

echo -e "${C}"
echo ' __     __   _     _             '
echo ' \ \   / /__| |__ (_) ___  _ __  '
echo '  \ \ / / _ \ |_ \| |/ _ \|  _ \ '
echo '   \ V /  __/ | | | | (_) | | | |'
echo '    \_/ \___|_| |_|_|\___/|_| |_|'
echo -e "${N}"
echo -e "${C}Vizion Installer${N}"
echo

# --------------------------------------------------
# REQUIREMENTS
# --------------------------------------------------

for c in curl unzip; do
    command -v "$c" >/dev/null 2>&1 || {
        echo -e "${R}$c is required. Install it first.${N}"
        exit 1
    }
done

# --------------------------------------------------
# INPUT
# --------------------------------------------------

read -rp "Email used for your license: " EMAIL
read -rp "License key: " KEY

EMAIL=$(echo "$EMAIL" | tr -d '\r' | xargs)
KEY=$(echo "$KEY" | tr -d '\r' | xargs)

echo
echo "1) Non-Blueprint"
echo "2) Blueprint"
read -rp "Select type: " T

if [ "$T" = "2" ]; then
    TYPE="blueprint"
else
    TYPE="non-blueprint"
fi

echo
echo "1) 2.0.8"
echo "2) 2.1.0"
read -rp "Select version: " V

if [ "$V" = "1" ]; then
    VER="2.0.8"
else
    VER="2.1.0"
fi

# --------------------------------------------------
# LICENSE
# --------------------------------------------------

IP=$(curl -4 -s --max-time 5 https://api.ipify.org)

BODY=$(printf \
'{"email":"%s","key":"%s","ip":"%s","requestedType":"%s","requestedVersion":"%s"}' \
"$EMAIL" "$KEY" "$IP" "$TYPE" "$VER")

echo -ne "\nVerifying license..."

RESP=$(curl -s --max-time 20 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d "$BODY" \
    "$API_URL/api/verify")

if [ -z "$RESP" ]; then
    echo -e "\n${R}✖ Could not reach the license server. Try again later.${N}"
    exit 1
fi

if ! echo "$RESP" | grep -q '"success":true'; then
    MSG=$(echo "$RESP" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
    echo -e "\n${R}✖ ${MSG:-Invalid license}${N}"
    exit 1
fi

echo -e " ${G}verified ✔${N}\n"

# --------------------------------------------------
# DOWNLOAD
# --------------------------------------------------

echo "Downloading Vizion ($TYPE $VER)..."

TMP=$(mktemp -d)

curl -fsSL -L "$REPO_ZIP" \
    -o "$TMP/v.zip" || {
        echo -e "${R}Download failed${N}"
        rm -rf "$TMP"
        exit 1
    }

unzip -q "$TMP/v.zip" \
    -d "$TMP/src" || {
        echo -e "${R}Unzip failed${N}"
        rm -rf "$TMP"
        exit 1
    }

RESOURCE_DIR=$(find "$TMP/src" -type d -path '*/resources/scripts' | head -1)

if [ -n "$RESOURCE_DIR" ]; then
    SRC=$(dirname "$(dirname "$RESOURCE_DIR")")
else
    SRC=$(find "$TMP/src" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        | head -1)

    SRC=${SRC:-$TMP/src}
fi

# --------------------------------------------------
# PANEL CHECK
# --------------------------------------------------

read -rp "Install into $PANEL_DIR ? [y/N]: " OK

if [[ ! "$OK" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    rm -rf "$TMP"
    exit 0
fi

if [ ! -f "$PANEL_DIR/artisan" ]; then
    echo -e "${R}No Pterodactyl panel found in $PANEL_DIR${N}"
    echo "Set PANEL_DIR=/your/path if needed."
    rm -rf "$TMP"
    exit 1
fi

# --------------------------------------------------
# INSTALL FILES
# --------------------------------------------------

echo -e "\n${C}Installing Vizion files...${N}"

cp -a "$SRC"/. "$PANEL_DIR"/

rm -rf "$TMP"

cd "$PANEL_DIR" || exit 1

# Initial ownership
chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || \
chown -R nginx:nginx "$PANEL_DIR" 2>/dev/null || true

# --------------------------------------------------
# NON-BLUEPRINT BUILD
# --------------------------------------------------

if [ "$TYPE" = "non-blueprint" ]; then

    echo -e "\n${C}Preparing panel dependencies...${N}"

    command -v node >/dev/null 2>&1 || {
        echo -e "${R}Node.js is required to build Vizion.${N}"
        exit 1
    }

    command -v yarn >/dev/null 2>&1 || {
        echo "Yarn not found. Installing..."
        npm install -g yarn
    }

    NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')

    if [ "${NODE_MAJOR:-0}" -ge 17 ]; then
        export NODE_OPTIONS=--openssl-legacy-provider
    fi

    echo -e "${C}Installing dependencies...${N}"

    yarn install || {
        echo -e "${R}yarn install failed${N}"
        exit 1
    }

    # --------------------------------------------------
    # FIX 1: Webpack Assets Manifest
    # --------------------------------------------------

    echo -e "${C}Fixing webpack-assets-manifest...${N}"

    yarn add -D webpack-assets-manifest@5.0.0 || {
        echo -e "${R}Failed installing webpack-assets-manifest${N}"
        exit 1
    }

    # --------------------------------------------------
    # FIX 2: Terser Webpack Plugin
    # --------------------------------------------------

    echo -e "${C}Fixing terser-webpack-plugin...${N}"

    yarn remove terser-webpack-plugin >/dev/null 2>&1 || true

    yarn add -D terser-webpack-plugin@4.2.3 || {
        echo -e "${R}Failed installing terser-webpack-plugin${N}"
        exit 1
    }

    # --------------------------------------------------
    # FIX 3: Webpack 5 path polyfill
    # --------------------------------------------------

    echo -e "${C}Adding path-browserify...${N}"

    yarn add path-browserify || {
        echo -e "${R}Failed installing path-browserify${N}"
        exit 1
    }

    # Add webpack fallback automatically
    python3 - <<'PY'
from pathlib import Path

p = Path("webpack.config.js")

if p.exists():
    s = p.read_text()

    if "path-browserify" not in s:
        marker = "resolve: {"

        if marker in s:
            s = s.replace(
                marker,
                marker + '\n        fallback: { path: require.resolve("path-browserify") },',
                1
            )
            p.write_text(s)
            print("Added path-browserify webpack fallback.")
        else:
            print("WARNING: Could not find resolve: {} in webpack.config.js")
    else:
        print("path-browserify fallback already exists.")
else:
    print("WARNING: webpack.config.js not found.")
PY

    # --------------------------------------------------
    # EXISTING DEPENDENCIES
    # --------------------------------------------------

    [ -x node_modules/.bin/cross-env ] || yarn add cross-env

    [ -d node_modules/webpack-bundle-analyzer ] || \
        yarn add -D webpack-bundle-analyzer

    # --------------------------------------------------
    # CLEAN WEBPACK CACHE
    # --------------------------------------------------

    echo -e "${C}Cleaning webpack cache...${N}"

    rm -rf node_modules/.cache

    # --------------------------------------------------
    # BUILD
    # --------------------------------------------------

    echo -e "\n${C}Building panel (this can take a few minutes)...${N}"

    yarn build:production || {
        echo -e "${R}"
        echo "Build failed."
        echo "Fix the error above and run:"
        echo "yarn build:production"
        echo -e "${N}"
        exit 1
    }

else

    echo -e "\n${C}Blueprint selected.${N}"
    echo "Rebuild with your Blueprint command after installation."
    echo "Example:"
    echo "blueprint -rerun-install"

fi

# --------------------------------------------------
# LARAVEL CACHE / PERMISSIONS FIX
# --------------------------------------------------

echo -e "\n${C}Fixing Laravel permissions...${N}"

mkdir -p storage/framework/cache/data
mkdir -p storage/framework/sessions
mkdir -p storage/framework/views
mkdir -p storage/logs
mkdir -p bootstrap/cache

chown -R www-data:www-data \
    storage \
    bootstrap/cache \
    public/assets \
    2>/dev/null || true

chmod -R ug+rwX \
    storage \
    bootstrap/cache \
    2>/dev/null || true

find storage bootstrap/cache \
    -type d \
    -exec chmod 775 {} \; \
    2>/dev/null || true

find storage bootstrap/cache \
    -type f \
    -exec chmod 664 {} \; \
    2>/dev/null || true

# --------------------------------------------------
# CLEAR OLD CACHE
# --------------------------------------------------

echo -e "${C}Clearing Laravel caches...${N}"

php artisan view:clear
php artisan config:clear
php artisan route:clear
php artisan cache:clear
php artisan optimize:clear

# --------------------------------------------------
# CLEAR OLD COMPILED VIEWS / CACHE DATA
# --------------------------------------------------

rm -rf storage/framework/cache/data/*
rm -rf storage/framework/views/*

# Recreate directories after cleanup
mkdir -p storage/framework/cache/data
mkdir -p storage/framework/views

chown -R www-data:www-data \
    storage \
    bootstrap/cache \
    2>/dev/null || true

chmod -R ug+rwX \
    storage \
    bootstrap/cache \
    2>/dev/null || true

# --------------------------------------------------
# FINAL LARAVEL OPTIMIZE
# --------------------------------------------------

echo -e "${C}Optimizing Laravel...${N}"

php artisan optimize

# --------------------------------------------------
# FINAL OWNERSHIP
# --------------------------------------------------

chown -R www-data:www-data \
    "$PANEL_DIR" \
    2>/dev/null || \
chown -R nginx:nginx \
    "$PANEL_DIR" \
    2>/dev/null || true

# --------------------------------------------------
# PHP-FPM RESTART
# --------------------------------------------------

echo -e "${C}Restarting PHP-FPM...${N}"

systemctl restart php8.3-fpm 2>/dev/null || \
systemctl restart php8.2-fpm 2>/dev/null || \
systemctl restart php8.1-fpm 2>/dev/null || true

# --------------------------------------------------
# VERIFY BUNDLE
# --------------------------------------------------

echo
echo -e "${C}Checking generated assets...${N}"

BUNDLE=$(find "$PANEL_DIR/public/assets" \
    -maxdepth 1 \
    -type f \
    -name 'bundle.*.js' \
    | head -1)

if [ -n "$BUNDLE" ]; then
    echo -e "${G}✔ Bundle found:${N} $(basename "$BUNDLE")"
else
    echo -e "${Y}⚠ No bundle.*.js found in public/assets${N}"
fi

# --------------------------------------------------
# WRITE TEST
# --------------------------------------------------

if sudo -u www-data test -w "$PANEL_DIR/storage/framework/cache/data" 2>/dev/null; then
    echo -e "${G}✔ www-data can write to Laravel cache${N}"
else
    echo -e "${Y}⚠ www-data write test failed${N}"
fi

# --------------------------------------------------
# DONE
# --------------------------------------------------

echo
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "${G}✔ Vizion installed successfully!${N}"
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo
echo "Panel: $PANEL_DIR"
echo "Type:  $TYPE"
echo "Version: $VER"
echo
echo "Hard-refresh your browser:"
echo "Ctrl + Shift + R"
echo cd /var/www/pterodactyl && yarn build:production && php artisan view:clear && php artisan optimize:clear && chown -R www-data:www-data public/assets storage bootstrap/cache && systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || true
