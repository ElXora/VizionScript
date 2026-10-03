#!/bin/bash

set -e

# ============================================================
# Vizion Pterodactyl Theme Installer
# ============================================================

PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
THEME_URL="https://github.com/ElXora/VizionScript/raw/refs/heads/main/main.zip"
LICENSE_SERVER="http://78.154.103.21:10532"
SITE_URL="https://test.aldow.cyou"

VERSION="2.1.0"

C='\033[0;36m'
G='\033[0;32m'
R='\033[0;31m'
Y='\033[1;33m'
N='\033[0m'

echo ""
echo -e "${C}==============================================${N}"
echo -e "${C}        VIZION THEME INSTALLER${N}"
echo -e "${C}==============================================${N}"
echo ""

# ============================================================
# ROOT CHECK
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${R}Please run this installer as root.${N}"
    exit 1
fi

# ============================================================
# REQUIREMENTS
# ============================================================

echo -e "${C}Checking required packages...${N}"

apt-get update -y

apt-get install -y \
    curl \
    unzip \
    python3 \
    sudo

# ============================================================
# PANEL CHECK
# ============================================================

if [ ! -d "$PANEL_DIR" ]; then
    echo -e "${R}Pterodactyl panel directory not found:${N}"
    echo "$PANEL_DIR"
    exit 1
fi

cd "$PANEL_DIR"

echo -e "${G}Panel found: $PANEL_DIR${N}"

# ============================================================
# LICENSE
# ============================================================

echo ""
echo -e "${C}Enter your Vizion license key:${N}"
read -r LICENSE_KEY

if [ -z "$LICENSE_KEY" ]; then
    echo -e "${R}License key cannot be empty.${N}"
    exit 1
fi

echo ""
echo -e "${C}Verifying license...${N}"

LICENSE_RESPONSE="$(curl -fsS \
    --max-time 15 \
    --get \
    --data-urlencode "license=$LICENSE_KEY" \
    --data-urlencode "domain=$SITE_URL" \
    --data-urlencode "version=$VERSION" \
    "$LICENSE_SERVER/verify" 2>/dev/null || true)"

if [ -z "$LICENSE_RESPONSE" ]; then
    echo -e "${R}Could not contact license server.${N}"
    exit 1
fi

echo "License response:"
echo "$LICENSE_RESPONSE"
echo ""

if ! echo "$LICENSE_RESPONSE" | grep -qiE '"valid"[[:space:]]*:[[:space:]]*true|valid.*true|success.*true|status.*valid|licensed.*true'; then
    echo -e "${R}License verification failed.${N}"
    exit 1
fi

echo -e "${G}License verified successfully.${N}"

# ============================================================
# THEME TYPE
# ============================================================

echo ""
echo -e "${C}Select theme type:${N}"
echo "1) Non-Blueprint"
echo "2) Blueprint"

read -r -p "Enter choice [1-2]: " THEME_CHOICE

case "$THEME_CHOICE" in
    1)
        THEME_TYPE="non-blueprint"
        ;;
    2)
        THEME_TYPE="blueprint"
        ;;
    *)
        echo -e "${R}Invalid choice.${N}"
        exit 1
        ;;
esac

echo -e "${G}Selected: $THEME_TYPE${N}"

# ============================================================
# VERSION
# ============================================================

echo ""
echo -e "${C}Select Vizion version:${N}"
echo "1) 2.0.8"
echo "2) 2.1.0"

read -r -p "Enter choice [1-2]: " VERSION_CHOICE

case "$VERSION_CHOICE" in
    1)
        VERSION="2.0.8"
        ;;
    2)
        VERSION="2.1.0"
        ;;
    *)
        echo -e "${R}Invalid choice.${N}"
        exit 1
        ;;
esac

echo -e "${G}Selected version: $VERSION${N}"

# ============================================================
# TEMP DIRECTORY
# ============================================================

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

ZIP_FILE="$TMP_DIR/vizion.zip"
EXTRACT_DIR="$TMP_DIR/vizion"

mkdir -p "$EXTRACT_DIR"

# ============================================================
# DOWNLOAD
# ============================================================

echo ""
echo -e "${C}Downloading Vizion theme...${N}"

curl -fL \
    --retry 5 \
    --connect-timeout 15 \
    --max-time 1800 \
    -o "$ZIP_FILE" \
    "$THEME_URL"

if [ ! -s "$ZIP_FILE" ]; then
    echo -e "${R}Theme download failed.${N}"
    exit 1
fi

echo -e "${G}Theme downloaded.${N}"

# ============================================================
# EXTRACT
# ============================================================

echo -e "${C}Extracting theme...${N}"

unzip -q -o "$ZIP_FILE" -d "$EXTRACT_DIR"

# Find the actual extracted directory/files.
SOURCE_DIR="$EXTRACT_DIR"

if [ "$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]; then
    POSSIBLE_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

    if [ -d "$POSSIBLE_DIR" ]; then
        SOURCE_DIR="$POSSIBLE_DIR"
    fi
fi

echo -e "${G}Theme extracted.${N}"

# ============================================================
# BACKUP
# ============================================================

BACKUP_DIR="/root/vizion-backup-$(date +%Y%m%d-%H%M%S)"

echo ""
echo -e "${C}Creating backup...${N}"

mkdir -p "$BACKUP_DIR"

for ITEM in \
    app \
    bootstrap \
    config \
    database \
    public \
    resources \
    routes \
    storage \
    webpack.config.js \
    package.json \
    yarn.lock
do
    if [ -e "$PANEL_DIR/$ITEM" ]; then
        cp -a "$PANEL_DIR/$ITEM" "$BACKUP_DIR/" 2>/dev/null || true
    fi
done

echo -e "${G}Backup created: $BACKUP_DIR${N}"

# ============================================================
# COPY THEME
# ============================================================

echo ""
echo -e "${C}Installing Vizion files...${N}"

cp -a "$SOURCE_DIR"/. "$PANEL_DIR"/

cd "$PANEL_DIR"

echo -e "${G}Theme files copied.${N}"

# ============================================================
# NON-BLUEPRINT BUILD
# ============================================================

if [ "$THEME_TYPE" = "non-blueprint" ]; then

    echo ""
    echo -e "${C}==============================================${N}"
    echo -e "${C}        BUILDING NON-BLUEPRINT THEME${N}"
    echo -e "${C}==============================================${N}"
    echo ""

    # --------------------------------------------------------
    # NODE CHECK
    # --------------------------------------------------------

    if ! command -v node >/dev/null 2>&1; then
        echo -e "${R}Node.js is not installed.${N}"
        exit 1
    fi

    if ! command -v yarn >/dev/null 2>&1; then
        echo -e "${R}Yarn is not installed.${N}"
        exit 1
    fi

    echo -e "${C}Node version:${N}"
    node -v

    echo -e "${C}Yarn version:${N}"
    yarn -v

    # --------------------------------------------------------
    # OPENSSL FIX FOR NEW NODE
    # --------------------------------------------------------

    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"

    if [ "$NODE_MAJOR" -ge 17 ]; then
        export NODE_OPTIONS="--openssl-legacy-provider"
        echo -e "${Y}Using NODE_OPTIONS=--openssl-legacy-provider${N}"
    fi

    # --------------------------------------------------------
    # YARN INSTALL
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Installing dependencies...${N}"

    yarn install --network-timeout 600000 || {
        echo -e "${R}yarn install failed.${N}"
        exit 1
    }

    # --------------------------------------------------------
    # WEBPACK ASSETS MANIFEST
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Installing webpack-assets-manifest...${N}"

    yarn add -D webpack-assets-manifest@5.0.0 || {
        echo -e "${R}Failed to install webpack-assets-manifest.${N}"
        exit 1
    }

    # --------------------------------------------------------
    # TERSER FIX
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Fixing terser-webpack-plugin compatibility...${N}"

    yarn remove terser-webpack-plugin || true

    yarn add -D terser-webpack-plugin@4.2.3 || {
        echo -e "${R}Failed to install terser-webpack-plugin.${N}"
        exit 1
    }

    # --------------------------------------------------------
    # PATH BROWSERIFY
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Installing path-browserify...${N}"

    yarn add path-browserify || {
        echo -e "${R}Failed to install path-browserify.${N}"
        exit 1
    }

    # --------------------------------------------------------
    # WEBPACK PATH FALLBACK
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Adding webpack path fallback...${N}"

    python3 <<'PY'
from pathlib import Path
import re

file = Path("webpack.config.js")

if not file.exists():
    print("webpack.config.js not found, skipping fallback patch.")
    raise SystemExit(0)

text = file.read_text()

if "path-browserify" in text:
    print("path-browserify fallback already exists.")
    raise SystemExit(0)

# If resolve already exists, add fallback inside it.
resolve_match = re.search(
    r'(?m)^(\s*)resolve\s*:\s*\{',
    text
)

if resolve_match:
    indent = resolve_match.group(1) + "    "

    insert = (
        f'{indent}fallback: {{\n'
        f'{indent}    path: require.resolve("path-browserify"),\n'
        f'{indent}}},\n'
    )

    pos = resolve_match.end()
    text = text[:pos] + "\n" + insert + text[pos:]

else:
    # Insert a resolve section before module/config if possible.
    insert = '''
    resolve: {
        fallback: {
            path: require.resolve("path-browserify"),
        },
    },
'''

    module_match = re.search(r'(?m)^(\s*)module\s*:\s*\{', text)

    if module_match:
        pos = module_match.start()
        text = text[:pos] + insert + "\n" + text[pos:]
    else:
        # Fallback: append before EOF.
        text += "\n" + insert + "\n"

file.write_text(text)

print("webpack path fallback added.")
PY

    # --------------------------------------------------------
    # CROSS ENV
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Checking cross-env...${N}"

    if ! yarn list --pattern "^cross-env$" 2>/dev/null | grep -q "cross-env"; then
        yarn add -D cross-env || {
            echo -e "${R}Failed to install cross-env.${N}"
            exit 1
        }
    fi

    # --------------------------------------------------------
    # WEBPACK BUNDLE ANALYZER
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Checking webpack-bundle-analyzer...${N}"

    if ! yarn list --pattern "webpack-bundle-analyzer" 2>/dev/null | grep -q "webpack-bundle-analyzer"; then
        yarn add -D webpack-bundle-analyzer || {
            echo -e "${R}Failed to install webpack-bundle-analyzer.${N}"
            exit 1
        }
    fi

    # --------------------------------------------------------
    # ICON POSITION FIX
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Checking DialogIcon IconPosition export...${N}"

    python3 <<'PY'
from pathlib import Path

file = Path("resources/scripts/components/elements/dialog/DialogIcon.tsx")

if not file.exists():
    print("DialogIcon.tsx not found, skipping IconPosition patch.")
    raise SystemExit(0)

text = file.read_text()

if "IconPosition" in text and "export enum IconPosition" in text:
    print("IconPosition export already exists.")
    raise SystemExit(0)

if "IconPosition" not in text:
    print("IconPosition is not referenced in DialogIcon.tsx, skipping.")
    raise SystemExit(0)

enum_code = '''
export enum IconPosition {
    LEFT = "left",
    RIGHT = "right",
}

'''

text = enum_code + text

file.write_text(text)

print("IconPosition export added.")
PY

    # --------------------------------------------------------
    # XTERM UNICODE SUPPORT
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Installing xterm-addon-unicode11...${N}"

    yarn add xterm-addon-unicode11 || {
        echo -e "${R}Failed to install xterm-addon-unicode11.${N}"
        exit 1
    }

    # --------------------------------------------------------
    # CLEAN NODE CACHE
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Cleaning frontend build cache...${N}"

    rm -rf node_modules/.cache

    # --------------------------------------------------------
    # EXTRA YARN BUILD
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Running yarn build...${N}"

    yarn build || {
        echo -e "${R}yarn build failed.${N}"
        exit 1
    }

    # --------------------------------------------------------
    # PRODUCTION BUILD
    # --------------------------------------------------------

    echo ""
    echo -e "${C}Running yarn build:production...${N}"

    yarn build:production || {
        echo -e "${R}Production frontend build failed.${N}"
        exit 1
    }

    echo ""
    echo -e "${G}Frontend build completed successfully.${N}"

fi

# ============================================================
# LARAVEL RUNTIME DIRECTORIES
# ============================================================

echo ""
echo -e "${C}Preparing Laravel runtime directories...${N}"

cd "$PANEL_DIR"

mkdir -p \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

# ============================================================
# REMOVE OLD COMPILED VIEWS/CACHE DATA
# ============================================================

echo -e "${C}Removing stale Laravel compiled files...${N}"

find storage/framework/views -type f -delete 2>/dev/null || true
find storage/framework/cache/data -type f -delete 2>/dev/null || true

# ============================================================
# PERMISSIONS
# ============================================================

echo ""
echo -e "${C}Fixing Laravel permissions...${N}"

chown -R www-data:www-data \
    storage \
    bootstrap/cache

find storage bootstrap/cache -type d -exec chmod 775 {} \; 2>/dev/null || true
find storage bootstrap/cache -type f -exec chmod 664 {} \; 2>/dev/null || true

chmod -R ug+rwX storage bootstrap/cache

# ============================================================
# WWW-DATA WRITE TEST
# ============================================================

echo ""
echo -e "${C}Testing Laravel write permissions...${N}"

TEST_FILE="$PANEL_DIR/storage/framework/cache/data/.vizion_write_test"

if sudo -u www-data sh -c "touch '$TEST_FILE' && rm -f '$TEST_FILE'"; then
    echo -e "${G}Laravel write test passed.${N}"
else
    echo -e "${R}Laravel cannot write to storage.${N}"
    echo ""
    echo "Current permissions:"
    ls -ld "$PANEL_DIR/storage"
    ls -ld "$PANEL_DIR/storage/framework"
    ls -ld "$PANEL_DIR/storage/framework/cache"
    ls -ld "$PANEL_DIR/storage/framework/cache/data"
    exit 1
fi

# ============================================================
# LARAVEL CACHE CLEAR
# ============================================================

echo ""
echo -e "${C}Clearing Laravel caches...${N}"

php artisan view:clear || true
php artisan config:clear || true
php artisan route:clear || true
php artisan cache:clear || true

# ============================================================
# LARAVEL OPTIMIZE
# ============================================================

echo ""
echo -e "${C}Optimizing Laravel...${N}"

php artisan optimize || {
    echo -e "${Y}Laravel optimize returned an error.${N}"
    echo -e "${Y}Continuing so the panel can still be tested.${N}"
}

# ============================================================
# FINAL PERMISSIONS
# ============================================================

echo ""
echo -e "${C}Applying final permissions...${N}"

chown -R www-data:www-data \
    storage \
    bootstrap/cache

if [ -d "$PANEL_DIR/public/assets" ]; then
    chown -R www-data:www-data "$PANEL_DIR/public/assets"
    chmod -R ug+rwX "$PANEL_DIR/public/assets"
fi

find storage bootstrap/cache -type d -exec chmod 775 {} \; 2>/dev/null || true
find storage bootstrap/cache -type f -exec chmod 664 {} \; 2>/dev/null || true

# ============================================================
# PHP-FPM RESTART
# ============================================================

echo ""
echo -e "${C}Restarting PHP-FPM...${N}"

PHP_SERVICE=""

for SERVICE in php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}"; then
        PHP_SERVICE="$SERVICE"
        break
    fi
done

if [ -n "$PHP_SERVICE" ]; then
    systemctl restart "$PHP_SERVICE"
    echo -e "${G}Restarted $PHP_SERVICE${N}"
else
    echo -e "${Y}Could not automatically detect PHP-FPM service.${N}"
fi

# ============================================================
# FINAL ASSET CHECK
# ============================================================

echo ""
echo -e "${C}Checking generated frontend assets...${N}"

if compgen -G "$PANEL_DIR/public/assets/bundle.*.js" > /dev/null; then
    echo -e "${G}Frontend bundle found:${N}"
    find "$PANEL_DIR/public/assets" -maxdepth 1 -type f -name 'bundle.*.js' -printf '%f\n' | sort
else
    echo -e "${Y}WARNING: No bundle.*.js file was found.${N}"
fi

# ============================================================
# FINAL LARAVEL WRITE TEST
# ============================================================

echo ""
echo -e "${C}Running final storage test...${N}"

FINAL_TEST="$PANEL_DIR/storage/framework/cache/data/.vizion_final_test"

if sudo -u www-data sh -c "mkdir -p '$(dirname "$FINAL_TEST")' && touch '$FINAL_TEST' && rm -f '$FINAL_TEST'"; then
    echo -e "${G}Final storage test passed.${N}"
else
    echo -e "${R}Final storage test failed.${N}"
    exit 1
fi

# ============================================================
# COMPLETE
# ============================================================

echo ""
echo -e "${C}==============================================${N}"
echo -e "${G}       VIZION INSTALLATION COMPLETE${N}"
echo -e "${C}==============================================${N}"
echo ""
echo -e "${G}Version:${N} $VERSION"
echo -e "${G}Theme:${N} $THEME_TYPE"
echo -e "${G}Panel:${N} $PANEL_DIR"
echo -e "${G}URL:${N} $SITE_URL"
echo -e "${G}Backup:${N} $BACKUP_DIR"
echo ""
echo -e "${Y}Clear your browser cache and hard refresh the panel.${N}"
echo ""
echo -e "${G}Done.${N}"
echo ""
