#!/usr/bin/env bash
# Vizion installer
API_URL="${VIZION_API:-https://YOUR-BOT-DOMAIN}"   # <- your bot/license server URL
REPO_ZIP="https://github.com/ElXora/VizionScript/raw/refs/heads/main/main.zip"   # <- main.zip in the same repo as this script
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
echo -e "\n1) Non-Blueprint\n2) Blueprint"; read -rp "Select type: " T
[ "$T" = "2" ] && TYPE="blueprint" || TYPE="non-blueprint"
echo -e "\n1) 2.0.8\n2) 2.1.0"; read -rp "Select version: " V
[ "$V" = "1" ] && VER="2.0.8" || VER="2.1.0"

IP=$(curl -s --max-time 5 https://api.ipify.org)
BODY=$(printf '{"email":"%s","key":"%s","ip":"%s","requestedType":"%s","requestedVersion":"%s"}' "$EMAIL" "$KEY" "$IP" "$TYPE" "$VER")

echo -ne "\nVerifying license..."
RESP=$(curl -s --max-time 20 -X POST -H 'Content-Type: application/json' -d "$BODY" "$API_URL/api/verify")
if ! echo "$RESP" | grep -q '"success":true'; then
  MSG=$(echo "$RESP" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
  echo -e "\n${R}✖ Invalid license${MSG:+ — $MSG}${N}"; exit 1
fi
echo -e " ${G}verified ✔${N}\n"

echo "Downloading Vizion ($TYPE $VER)..."
TMP=$(mktemp -d)
curl -fsSL -L "$REPO_ZIP" -o "$TMP/v.zip" || { echo -e "${R}Download failed${N}"; exit 1; }
unzip -q "$TMP/v.zip" -d "$TMP/src" || { echo -e "${R}Unzip failed${N}"; exit 1; }
SRC=$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -1); SRC=${SRC:-$TMP/src}

read -rp "Install into $PANEL_DIR ? [y/N]: " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; rm -rf "$TMP"; exit 0; }
cp -a "$SRC"/. "$PANEL_DIR"/
cd "$PANEL_DIR" && { [ "$TYPE" = "non-blueprint" ] && command -v yarn >/dev/null && yarn install && yarn build:production; }
rm -rf "$TMP"
echo -e "\n${G}✔ Vizion installed.${N}"
