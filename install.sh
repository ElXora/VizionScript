#!/usr/bin/env bash
# Vizion manager: install / fix bugs (white screen, 500) / uninstall (restore stock Pterodactyl)
API_URL="http://78.154.103.21:10532"
REPO_ZIP="https://github.com/ElXora/VizionScript/raw/refs/heads/main/main.zip"
BP_URL="${REPO_ZIP%main.zip}vizionmono.blueprint"   # vizionmono.blueprint sits next to main.zip in your repo
BP_ID="vizionmono"; BP_OLD_ID="viziontheme"
PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
RELEASES="${PTERO_RELEASE_BASE:-https://github.com/pterodactyl/panel/releases}"

C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
[ -t 0 ] || [ -n "${VIZION_STDIN:-}" ] || { [ -r /dev/tty ] && exec </dev/tty; }
clear 2>/dev/null; echo -e "${C}
 __     ___ _____ ___ ___  _  _
 \\ \\   / /_ _|__  / |_ _|/ _ \\| \\| |
  \\ \\ / / | |  / /   | || (_) | .\` |
   \\ V / |___|/___| |___|\\___/|_|
${N}        Vizion Manager\n"

say()  { echo -e "${C}➜ $*${N}"; }
ok()   { echo -e "  ${G}✔ $*${N}"; }
warn() { echo -e "  ${Y}! $*${N}"; }
die()  { echo -e "${R}✖ $*${N}"; exit 1; }
ask()  { local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------ helpers
find_panel() {
  while [ ! -f "$PANEL_DIR/artisan" ]; do
    echo -e "${Y}No Pterodactyl panel found in $PANEL_DIR${N}"
    read -rp "Enter the panel path (or press Enter to cancel): " P
    [ -n "$P" ] || exit 1; PANEL_DIR="${P%/}"
  done
  cd "$PANEL_DIR" || exit 1
  WEBUSER=$(stat -c %U "$PANEL_DIR/.env" 2>/dev/null || stat -c %U "$PANEL_DIR/artisan")
  { [ -z "$WEBUSER" ] || [ "$WEBUSER" = root ]; } && { id www-data >/dev/null 2>&1 && WEBUSER=www-data || WEBUSER=nginx; }
  WEBGROUP=$(id -gn "$WEBUSER" 2>/dev/null || echo "$WEBUSER")
}
art() {  # run artisan as the web user so cache/log files never become root-owned (classic cause of 500s)
  if [ "$(id -u)" = 0 ] && [ "$WEBUSER" != root ] && command -v runuser >/dev/null 2>&1; then
    (cd "$PANEL_DIR" && runuser -u "$WEBUSER" -- php artisan "$@")
  else (cd "$PANEL_DIR" && php artisan "$@"); fi
}
fix_perms() {
  mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
  chown -R "$WEBUSER:$WEBGROUP" "$PANEL_DIR" 2>/dev/null
  chmod -R ug+rwX storage bootstrap/cache 2>/dev/null
}
clear_caches() {
  rm -rf storage/framework/views/* storage/framework/cache/data/* bootstrap/cache/*.php 2>/dev/null
  art view:clear >/dev/null 2>&1; art config:clear >/dev/null 2>&1; art route:clear >/dev/null 2>&1; art cache:clear >/dev/null 2>&1
  art queue:restart >/dev/null 2>&1
  fix_perms
}
is_blueprint() { [ -d "$PANEL_DIR/.blueprint" ] && command -v blueprint >/dev/null 2>&1; }
bp_has() { [ -d "$PANEL_DIR/.blueprint/extensions/$1" ]; }
WRAP="resources/views/templates/wrapper.blade.php"
panel_version() { sed -n "s/.*'version' *=> *'\([^']*\)'.*/\1/p" "$PANEL_DIR/config/app.php" 2>/dev/null | head -1; }
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
latest_release() { [ -n "${PTERO_LATEST_VER:-}" ] && { echo "$PTERO_LATEST_VER"; return; }
  curl -sIL -o /dev/null -w '%{url_effective}' "$RELEASES/latest" 2>/dev/null | sed -n 's#.*/tag/v\{0,1\}\(.*\)#\1#p'; }
# Hooks the theme into the panel's own files without replacing them (keeps Blueprint's changes intact). Safe to repeat.
patch_vizion_backend() {
  mkdir -p public/vizion storage/app/vizion
  [ -f routes/vizion.php ] && ! grep -q "vizion.php" routes/api-client.php && printf "\nrequire __DIR__ . '/vizion.php';\n" >> routes/api-client.php
  if [ -f routes/vizion-admin.php ]; then
    grep -q "vizion-admin.php" routes/admin.php || printf "\nrequire __DIR__ . '/vizion-admin.php';\n" >> routes/admin.php
    local L=resources/views/layouts/admin.blade.php
    [ -f "$L" ] || return 0
    grep -q "admin.vizion.head" "$L" || sed -i "s#</head>#@include('admin.vizion.head')\n    </head>#" "$L"
    grep -q "route('admin.vizion')" "$L" || sed -i "0,/<li class=\"header\">MANAGEMENT<\/li>/s##<li class=\"{{ request()->routeIs('admin.vizion') ? 'active' : '' }}\">\n                            <a href=\"{{ route('admin.vizion') }}\"><i class=\"fa fa-paint-brush\"><\/i> <span>Appearance<\/span><\/a>\n                        <\/li>\n                        <li class=\"header\">MANAGEMENT<\/li>#" "$L"
  fi
}
vizion_full() { [ -f "$PANEL_DIR/resources/scripts/assets/css/VizionTheme.ts" ]; }
legacy_theme() { [ -d "$PANEL_DIR/public/themes/enigma_premium" ] || [ -f "$PANEL_DIR/resources/scripts/assets/css/EnigmaBusiness.ts" ]; }
svc_restart() { command -v systemctl >/dev/null 2>&1 || return 0
  local u; for u in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^(php[0-9.]*-fpm|nginx|apache2|pteroq)\.service$'); do
    systemctl restart "$u" >/dev/null 2>&1 && ok "restarted ${u%.service}"; done; }

# download + extract the stock panel release into $TMP/stock
fetch_stock() { # $1 = version (x.y.z) or "latest"
  local url; if [ "$1" = latest ]; then url="$RELEASES/latest/download/panel.tar.gz"; else url="$RELEASES/download/v$1/panel.tar.gz"; fi
  say "Downloading stock Pterodactyl ($1)..."
  curl -fsSL -L --max-time 300 "$url" -o "$TMP/panel.tar.gz" || return 1
  mkdir -p "$TMP/stock"; tar xzf "$TMP/panel.tar.gz" -C "$TMP/stock" 2>/dev/null || return 1
  [ -f "$TMP/stock/artisan" ] && [ -f "$TMP/stock/public/assets/manifest.json" ]
}

# ================================================================= INSTALL
do_install() {
  for c in curl unzip; do command -v $c >/dev/null || die "$c is required (apt install -y $c)"; done
  find_panel
  read -rp "Email used for your license: " EMAIL
  read -rp "License key: " KEY
  EMAIL=$(echo "$EMAIL" | tr -d '\r' | xargs); KEY=$(echo "$KEY" | tr -d '\r' | xargs)
  IP=$(curl -s --max-time 5 https://api.ipify.org)
  BODY=$(printf '{"email":"%s","key":"%s","ip":"%s"}' "$EMAIL" "$KEY" "$IP")
  echo -ne "\nVerifying license..."
  RESP=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d "$BODY" "$API_URL/api/verify")
  [ -n "$RESP" ] || die "\nCould not reach the license server. Try again later."
  if ! echo "$RESP" | grep -q '"success":true'; then
    MSG=$(echo "$RESP" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p'); die "\n${MSG:-Invalid license}"
  fi
  echo -e " ${G}verified ✔${N}\n"

  LT=$(echo "$RESP" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')   # only what the license allows can be installed
  if [ "$LT" = "blueprint" ] || [ "$LT" = "non-blueprint" ]; then TYPE="$LT"; echo -e "License type: ${G}$TYPE${N}"
  else echo -e "1) Non-Blueprint\n2) Blueprint"; read -rp "Select type: " T; [ "$T" = "2" ] && TYPE="blueprint" || TYPE="non-blueprint"; fi

  if legacy_theme; then warn "An older full Vizion/Enigma theme is installed. Run 'Uninstall' first for a clean result."
    ask "Continue anyway?" || exit 0; fi
  ask "Install Vizion ($TYPE) into $PANEL_DIR ?" || { echo "Cancelled."; exit 0; }

  if [ "$TYPE" = "blueprint" ]; then
    command -v blueprint >/dev/null || die "Blueprint is not installed on this panel. Install Blueprint first (blueprint.zip), then run this installer again."
    curl -fsSL -L "$BP_URL" -o "$PANEL_DIR/$BP_ID.blueprint" || die "Download failed"
    unzip -tq "$PANEL_DIR/$BP_ID.blueprint" >/dev/null 2>&1 || { rm -f "$PANEL_DIR/$BP_ID.blueprint"; die "Downloaded file is not a valid .blueprint package"; }
    blueprint -install "$BP_ID"; RC=$?
    rm -f "$PANEL_DIR/$BP_ID.blueprint"
    [ $RC -eq 0 ] || die "Blueprint install failed - see the output above."
    clear_caches
    echo -e "\n${G}✔ Vizion (Blueprint) installed. Hard-refresh your browser (Ctrl+Shift+R).${N}"; return
  fi

  say "Downloading Vizion..."
  curl -fsSL -L "$REPO_ZIP" -o "$TMP/v.zip" || die "Download failed"
  unzip -q "$TMP/v.zip" -d "$TMP/src" || die "Unzip failed"
  F=$(find "$TMP/src" -path '*/resources/scripts/assets/css/VizionTheme.ts' | head -1)
  if [ -n "$F" ]; then
    # ---- full theme: copy the source files, then compile them (the big server cards live in the source,
    #      so the old prebuilt assets in main.zip must NOT be used). Set VIZION_PREBUILT=1 only if main.zip
    #      ships freshly built assets.
    SRC="${F%/resources/scripts/assets/css/VizionTheme.ts}"
    PV=$(panel_version)
    BUILD=1; [ -n "${VIZION_PREBUILT:-}" ] && BUILD=0
    if [ -d "$PANEL_DIR/.blueprint" ]; then
      warn "Blueprint is installed on this panel. The prebuilt assets would replace Blueprint's compiled UI, so the theme is built from source instead (Node 22+)."
      warn "The theme replaces the sidebar, dashboard and server-list files, so extension buttons Blueprint adds to those areas will not show."
      ask "Continue?" || { echo "Cancelled."; exit 0; }
    fi
    [ -n "$PV" ] && ! [[ "$PV" == 1.12.* ]] && warn "Panel version is $PV: the theme is made for 1.12.x"
    if [ $BUILD = 1 ]; then
      command -v node >/dev/null || die "Node.js 22+ is required to build. Install it first (https://nodejs.org)."
      [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -ge 22 ] || die "Node 22 or newer is required (found $(node -v))."
    fi
    rm -f public/assets/*.js public/assets/*.map 2>/dev/null   # old hashed bundles from the previous build
    cp -a "$SRC"/. "$PANEL_DIR"/ || die "Copy failed"
    if [ $BUILD = 1 ]; then
      rm -f public/assets/*.js public/assets/*.map public/assets/manifest.json 2>/dev/null   # drop the stale bundles copied from main.zip
      command -v yarn >/dev/null || npm i -g yarn
      say "Building the panel with the new server cards (a few minutes, needs ~2 GB RAM)..."
      export NODE_OPTIONS=--openssl-legacy-provider
      yarn install --frozen-lockfile && yarn build:production || die "Build failed - the theme files are copied but not active. Fix the error above and run: yarn build:production"
    fi
    [ -f public/assets/manifest.json ] || die "public/assets/manifest.json is missing"
    patch_vizion_backend
    if [ -n "${VIZION_CARD_IMAGE:-}" ] && [ -f "$VIZION_CARD_IMAGE" ]; then
      cp -f "$VIZION_CARD_IMAGE" "public/vizion/card-default.${VIZION_CARD_IMAGE##*.}" && ok "default server-card picture installed"
    fi
    clear_caches
    echo -e "\n${G}✔ Vizion installed. Hard-refresh your browser (Ctrl+Shift+R).${N}"
    echo -e "  Admins: open ${Y}Admin → Appearance${N} to change the look, banner and links for everyone."
    echo -e "  White screen or 500 error? Run this script again and choose ${Y}Fix bugs${N}."; return
  fi
  # ---- Vizion Mono (CSS + JS only, no build)
  V=$(find "$TMP/src" -path '*/public/themes/vizion/vizion.css' | head -1)
  [ -n "$V" ] || die "main.zip contains neither the full theme nor public/themes/vizion/vizion.css"
  mkdir -p public/themes/vizion && cp -a "$(dirname "$V")"/. public/themes/vizion/
  [ -f "$WRAP.vizion-bak" ] || cp -p "$WRAP" "$WRAP.vizion-bak"
  REV=$(date +%s)   # new number on every install so browsers never keep an old cached theme
  if grep -q "themes/vizion/vizion.css" "$WRAP"; then
    sed -i -E "s#(themes/vizion/vizion\.(css|js))\?v=[0-9]+#\1?v=$REV#g" "$WRAP"
  else
    sed -i "s#</head>#    <link rel=\"stylesheet\" href=\"/themes/vizion/vizion.css?v=$REV\">\n    <script defer src=\"/themes/vizion/vizion.js?v=$REV\"></script>\n</head>#" "$WRAP"
  fi
  grep -q "themes/vizion/vizion.css" "$WRAP" || die "Could not patch $WRAP"
  clear_caches
  echo -e "\n${G}✔ Vizion Mono installed. Hard-refresh your browser (Ctrl+Shift+R).${N}"
  echo -e "  If you ever get a white screen or 500 error, run this script again and choose ${Y}Fix bugs${N}."
}

# ================================================================= FIX BUGS
diagnose_log() {
  local log err; log=$(ls -t storage/logs/laravel-*.log 2>/dev/null | head -1); [ -n "$log" ] || { ok "no Laravel error log"; return; }
  err=$(grep -E '^\[[0-9-]+ [0-9:]+\] [A-Za-z]+\.(ERROR|CRITICAL|EMERGENCY)' "$log" | tail -1 | cut -c1-260)
  [ -n "$err" ] || { ok "no recent errors in $(basename "$log")"; return; }
  warn "last error: $err"
  case "$err" in
    *"Permission denied"*|*"failed to open stream"*) ok "looks like a permissions problem - already repaired above" ;;
    *"encryption key"*) warn "APP_KEY is missing in .env. On a fresh panel run: php artisan key:generate --force (on a live panel restore your old key instead - changing it breaks encrypted data)" ;;
    *"SQLSTATE"*|*"Connection refused"*|*"Access denied"*)
      warn "database problem - checking the database service"
      for s in mariadb mysql mysqld; do systemctl list-unit-files "$s.service" >/dev/null 2>&1 && ! systemctl is-active --quiet "$s" 2>/dev/null && systemctl start "$s" 2>/dev/null && ok "started $s"; done
      warn "also check DB_HOST / DB_USERNAME / DB_PASSWORD in $PANEL_DIR/.env" ;;
    *"not found"*|*"Target class"*) warn "a PHP class is missing - repairing composer autoload"
      command -v composer >/dev/null && (composer install --no-dev --optimize-autoloader --no-interaction >/dev/null 2>&1 && ok "composer install done") ;;
  esac
}
check_assets() {   # prints missing files; returns 1 when the panel's JS bundle is broken
  local man=public/assets/manifest.json bad=0 f
  if [ ! -f "$man" ] && [ -f public/assets/assets-manifest.json ]; then cp public/assets/assets-manifest.json "$man"; ok "recreated manifest.json from assets-manifest.json"; fi
  [ -f "$man" ] || { warn "public/assets/manifest.json is missing"; return 1; }
  while read -r f; do [ -f "public$f" ] || { warn "manifest points to a missing file: $f"; bad=1; }; done < <(grep -oE '"src": *"[^"]+"' "$man" | sed -E 's/.*"([^"]+)"$/\1/')
  return $bad
}
http_check() {
  local url code a
  url=$(grep -E '^APP_URL=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"' \r")
  [ -n "$url" ] || { warn "APP_URL not set, skipping web test"; return; }
  code=$(curl -sk -L --max-time 20 -o "$TMP/login.html" -w '%{http_code}' "$url/auth/login" 2>/dev/null)
  if [ "$code" = 200 ]; then ok "login page answers 200"; else warn "login page answers $code ($url/auth/login)"; fi
  for a in $(grep -oE 'src="[^"]+\.js[^"]*"' "$TMP/login.html" 2>/dev/null | cut -d'"' -f2 | head -6); do
    case "$a" in http*) ;; *) a="$url$a";; esac
    code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "$a" 2>/dev/null)
    [ "$code" = 200 ] && ok "asset 200: ${a##*/}" || warn "asset $code: $a"
  done
  if [ ! -s "$TMP/login.html" ]; then warn "could not load the page (is $url reachable from this server?)"; fi
}
do_fix() {
  find_panel
  say "1/7 Environment"
  PHPV=$(php -r 'echo PHP_VERSION;' 2>/dev/null); [ -n "$PHPV" ] || die "php was not found"
  php -r 'exit(version_compare(PHP_VERSION,"8.2.0","<")?1:0);' && ok "PHP $PHPV" || warn "PHP $PHPV is older than 8.2 - Pterodactyl 1.12 needs PHP 8.2+"
  [ -f .env ] || warn ".env is missing"
  grep -qE '^APP_KEY=.+' .env 2>/dev/null || warn "APP_KEY is empty in .env"
  if [ ! -d vendor ] || [ ! -f vendor/autoload.php ]; then
    warn "vendor/ is missing"; command -v composer >/dev/null && composer install --no-dev --optimize-autoloader --no-interaction && ok "composer install done"
  else ok "vendor/ present"; fi

  say "2/7 Permissions"; fix_perms; ok "owner $WEBUSER:$WEBGROUP, storage + bootstrap/cache writable"

  say "3/7 Caches"; clear_caches; ok "views, config, routes and cache cleared"

  say "4/7 Theme wiring"
  if [ -f routes/vizion-admin.php ]; then patch_vizion_backend && ok "routes, admin menu and admin theme are hooked in"; fi
  if grep -q "themes/vizion/" "$WRAP" 2>/dev/null && [ ! -f public/themes/vizion/vizion.css ]; then
    sed -i '/themes\/vizion\//d' "$WRAP"; warn "theme files were missing - removed the broken theme links (re-run Install to add them back)"
  else ok "ok"; fi
  [ "$(grep -c 'themes/vizion/vizion.css' "$WRAP" 2>/dev/null)" -gt 1 ] && { warn "duplicate theme links found - fixing"; awk '!(/themes\/vizion\// && seen[$0]++)' "$WRAP" > "$TMP/w" && cat "$TMP/w" > "$WRAP"; }

  say "5/7 Panel assets (white screen)"
  if check_assets; then ok "manifest and JS bundles are complete"; else
    if is_blueprint || vizion_full; then
      warn "the panel needs a rebuild"
      if command -v yarn >/dev/null && command -v node >/dev/null && ask "Rebuild now (yarn build:production, a few minutes)?"; then
        export NODE_OPTIONS=--openssl-legacy-provider; yarn install --frozen-lockfile && yarn build:production && ok "rebuilt" || warn "build failed - run 'blueprint -rerun-install'"
      else vizion_full && warn "run: yarn build:production (or run this script again and choose Install)" || warn "run: blueprint -rerun-install"; fi
    else
      VER=$(panel_version)
      if is_semver "$VER" && ask "Restore the stock compiled assets of Pterodactyl $VER?"; then
        if fetch_stock "$VER"; then rm -rf public/assets && cp -a "$TMP/stock/public/assets" public/assets && ok "assets restored" || warn "copy failed"
        else warn "could not download the release"; fi
      else warn "could not fix assets automatically"; fi
    fi
    check_assets && ok "assets verified" || true
  fi
  fix_perms

  say "6/7 Services"; art queue:restart >/dev/null 2>&1; svc_restart

  say "7/7 Web test"; http_check; diagnose_log
  echo -e "\n${G}✔ Done.${N} Hard-refresh the browser (Ctrl+Shift+R). Still broken? Send me the lines marked with '!' above."
}

# ================================================================= UNINSTALL
do_uninstall() {
  find_panel
  echo -e "${Y}This removes Vizion completely and puts the stock Pterodactyl theme back.${N}"
  ask "Continue?" || { echo "Cancelled."; exit 0; }

  if is_blueprint; then
    say "Removing the Blueprint extension(s)"
    for id in "$BP_ID" "$BP_OLD_ID"; do bp_has "$id" && { blueprint -remove "$id" && ok "removed $id" || warn "blueprint -remove $id failed"; }; done
    sed -i '/themes\/vizion\//d' "$WRAP" 2>/dev/null; rm -rf public/themes/vizion
    clear_caches
    echo -e "\n${G}✔ Vizion removed. Blueprint itself is untouched. Hard-refresh your browser (Ctrl+Shift+R).${N}"; return
  fi

  INST=$(panel_version); DEF="$INST"; is_semver "$DEF" || DEF=""
  LAT=$(latest_release)
  echo -e "Installed panel version : ${G}${INST:-unknown}${N}   Latest release: ${G}${LAT:-unknown}${N}"
  echo -e "The stock theme must match your panel version. Press Enter to restore ${DEF:-the version you type}, or type another version / 'latest' (only when also upgrading the panel)."
  read -rp "Version to restore [${DEF:-latest}]: " WANT; WANT=${WANT:-${DEF:-latest}}
  [ "$WANT" = latest ] && [ -n "$LAT" ] && { WANTV="$LAT"; } || WANTV="$WANT"
  { is_semver "$WANTV" || [ "$WANT" = latest ]; } || die "Invalid version: $WANTV"
  fetch_stock "$WANTV" || die "Could not download the stock release ($WANTV). Nothing was changed."

  BK="/root/vizion-backup-$(date +%Y%m%d-%H%M%S).tar.gz"; [ -w /root ] || BK="$PWD/vizion-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  say "Backing up current files to $BK"
  tar czf "$BK" app routes resources public config tailwind.config.js package.json yarn.lock webpack.config.js 2>/dev/null && ok "backup saved"

  say "Removing the theme"
  sed -i '/themes\/vizion\//d' "$WRAP" 2>/dev/null
  rm -rf public/themes/vizion public/themes/enigma_premium public/assets resources/scripts resources/views public/themes
  rm -rf public/vizion storage/app/vizion routes/vizion.php routes/vizion-admin.php app/Http/Controllers/Admin/VizionController.php
  ok "theme files removed"

  say "Restoring stock Pterodactyl $WANTV"
  cp -a "$TMP/stock/." "$PANEL_DIR/" || die "Restore failed - your backup is at $BK"
  ok "stock files restored (the same way the official panel upgrade does it)"
  if [ "$WANTV" != "$INST" ]; then
    say "Version changed - updating dependencies and database"
    command -v composer >/dev/null && composer install --no-dev --optimize-autoloader --no-interaction
  fi
  art migrate --seed --force >/dev/null 2>&1 && ok "database up to date"
  clear_caches; svc_restart
  echo -e "\n${G}✔ Vizion uninstalled - stock Pterodactyl theme restored.${N} Hard-refresh the browser (Ctrl+Shift+R)."
  echo -e "  Backup of the old files: $BK"
}

# ================================================================= MENU
ACTION="${1:-}"
if [ -z "$ACTION" ]; then
  echo -e "  ${G}1)${N} Install Vizion\n  ${G}2)${N} Fix bugs  ${C}(white screen / 500 server error)${N}\n  ${G}3)${N} Uninstall Vizion  ${C}(restore stock Pterodactyl theme)${N}\n  ${G}0)${N} Exit\n"
  read -rp "Select an option: " ACTION
fi
case "$ACTION" in
  1|install)   do_install ;;
  2|fix)       do_fix ;;
  3|uninstall) do_uninstall ;;
  *)           echo "Bye."; exit 0 ;;
esac
