#!/bin/bash
# Checks for latest versions of all build dependencies
# and updates versions.json if newer versions are found.
#
# Usage:
#   ./check_versions.sh          # check and print diff
#   ./check_versions.sh --apply  # update versions.json in place
#
# Dependencies: curl, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/versions.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo -e "${RED}versions.json not found at $VERSIONS_FILE${NC}"
    exit 1
fi

for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || { echo -e "${RED}$cmd is required but not installed${NC}"; exit 1; }
done

CHANGES=0
declare -A NEW_VERSIONS

current_version() {
    jq -r ".${1}.version" "$VERSIONS_FILE"
}

# ─── NGINX (stable branch) ───
check_nginx() {
    local cur
    cur=$(current_version nginx)
    # Parse the download page for the latest stable version
    local latest
    latest=$(curl -fsSL --max-time 15 "https://nginx.org/en/download.html" \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1)
    if [[ -z "$latest" ]]; then
        echo -e "${YELLOW}[SKIP] nginx: could not fetch latest version${NC}"
        return
    fi
    if [[ "$cur" != "$latest" ]]; then
        echo -e "${GREEN}[UPDATE] nginx: $cur → $latest${NC}"
        NEW_VERSIONS[nginx]="$latest"
        CHANGES=$((CHANGES + 1))
    else
        echo "  [OK] nginx: $cur"
    fi
}

# ─── OpenSSL (latest 3.x release) ───
check_openssl() {
    local cur
    cur=$(current_version openssl)
    local latest
    latest=$(curl -fsSL --max-time 15 "https://api.github.com/repos/openssl/openssl/releases" \
        | jq -r '[.[] | select(.tag_name | startswith("openssl-3.")) | .tag_name] | first' \
        | sed 's/^openssl-//')
    if [[ -z "$latest" || "$latest" == "null" ]]; then
        echo -e "${YELLOW}[SKIP] openssl: could not fetch latest version${NC}"
        return
    fi
    if [[ "$cur" != "$latest" ]]; then
        echo -e "${GREEN}[UPDATE] openssl: $cur → $latest${NC}"
        NEW_VERSIONS[openssl]="$latest"
        CHANGES=$((CHANGES + 1))
    else
        echo "  [OK] openssl: $cur"
    fi
}

# ─── zlib ───
check_zlib() {
    local cur
    cur=$(current_version zlib)
    local latest
    latest=$(curl -fsSL --max-time 15 "https://api.github.com/repos/madler/zlib/releases/latest" \
        | jq -r '.tag_name' \
        | sed 's/^v//')
    if [[ -z "$latest" || "$latest" == "null" ]]; then
        echo -e "${YELLOW}[SKIP] zlib: could not fetch latest version${NC}"
        return
    fi
    if [[ "$cur" != "$latest" ]]; then
        echo -e "${GREEN}[UPDATE] zlib: $cur → $latest${NC}"
        NEW_VERSIONS[zlib]="$latest"
        CHANGES=$((CHANGES + 1))
    else
        echo "  [OK] zlib: $cur"
    fi
}

# ─── PCRE2 ───
check_pcre2() {
    local cur
    cur=$(current_version pcre2)
    local latest
    latest=$(curl -fsSL --max-time 15 "https://api.github.com/repos/PhilipHazel/pcre2/releases/latest" \
        | jq -r '.tag_name' \
        | sed 's/^pcre2-//')
    if [[ -z "$latest" || "$latest" == "null" ]]; then
        echo -e "${YELLOW}[SKIP] pcre2: could not fetch latest version${NC}"
        return
    fi
    if [[ "$cur" != "$latest" ]]; then
        echo -e "${GREEN}[UPDATE] pcre2: $cur → $latest${NC}"
        NEW_VERSIONS[pcre2]="$latest"
        CHANGES=$((CHANGES + 1))
    else
        echo "  [OK] pcre2: $cur"
    fi
}

# ─── PHP 8.1.x (latest patch) ───
check_php() {
    local cur
    cur=$(current_version php)
    local latest
    latest=$(curl -fsSL --max-time 15 "https://www.php.net/releases/index.php?json&version=8.1" \
        | jq -r '.version // empty')
    if [[ -z "$latest" ]]; then
        echo -e "${YELLOW}[SKIP] php: could not fetch latest version${NC}"
        return
    fi
    if [[ "$cur" != "$latest" ]]; then
        echo -e "${GREEN}[UPDATE] php: $cur → $latest${NC}"
        NEW_VERSIONS[php]="$latest"
        CHANGES=$((CHANGES + 1))
    else
        echo "  [OK] php: $cur"
    fi
}

# ─── nginx-http-flv-module ───
check_flv_module() {
    local cur
    cur=$(current_version nginx_http_flv_module)
    local latest
    latest=$(curl -fsSL --max-time 15 "https://api.github.com/repos/winshining/nginx-http-flv-module/releases/latest" \
        | jq -r '.tag_name' \
        | sed 's/^v//')
    if [[ -z "$latest" || "$latest" == "null" ]]; then
        echo -e "${YELLOW}[SKIP] nginx_http_flv_module: could not fetch latest version${NC}"
        return
    fi
    if [[ "$cur" != "$latest" ]]; then
        echo -e "${GREEN}[UPDATE] nginx_http_flv_module: $cur → $latest${NC}"
        NEW_VERSIONS[nginx_http_flv_module]="$latest"
        CHANGES=$((CHANGES + 1))
    else
        echo "  [OK] nginx_http_flv_module: $cur"
    fi
}

# ─── Run all checks ───
echo "=== Checking for latest versions ==="
echo ""
check_nginx
check_openssl
check_zlib
check_pcre2
check_php
check_flv_module
echo ""

# ─── Apply updates ───
if [[ $CHANGES -eq 0 ]]; then
    echo "All versions are up to date."
    exit 0
fi

echo "$CHANGES update(s) found."

if [[ "${1:-}" != "--apply" ]]; then
    echo "Run with --apply to update versions.json"
    exit 0
fi

echo "Applying updates to versions.json..."

TMP_FILE=$(mktemp)
cp "$VERSIONS_FILE" "$TMP_FILE"

for key in "${!NEW_VERSIONS[@]}"; do
    ver="${NEW_VERSIONS[$key]}"
    jq --arg k "$key" --arg v "$ver" '.[$k].version = $v' "$TMP_FILE" > "${TMP_FILE}.new"
    mv "${TMP_FILE}.new" "$TMP_FILE"
done

# Update the _updated timestamp
jq --arg d "$(date +%Y-%m-%d)" '._updated = $d' "$TMP_FILE" > "${TMP_FILE}.new"
mv "${TMP_FILE}.new" "$TMP_FILE"

mv "$TMP_FILE" "$VERSIONS_FILE"

echo -e "${GREEN}versions.json updated successfully.${NC}"
