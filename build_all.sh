#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/out"
LOG_DIR="$ROOT_DIR/logs"
DOCKER_DIR="$ROOT_DIR/docker"
DOWNLOADS_DIR="$ROOT_DIR/downloads"
VERSIONS_FILE="$ROOT_DIR/versions.json"

# Path to PHP extension sources — stays outside this repo, never committed.
# Overridable via the EXT_SRC_DIR env var; defaults to the XC_VM_CoreExtention repo
# checked out alongside this one.
EXT_SRC_DIR="${EXT_SRC_DIR:-$ROOT_DIR/../XC_VM_CoreExtention/extension}"

mkdir -p "$OUT_DIR" "$LOG_DIR" "$DOWNLOADS_DIR"

# ----------------------
# Pre-download all source archives once on the host
# ----------------------
# Each container otherwise downloads the same sources independently (up to 7x per
# full build). We fetch them once into downloads/ and mount that folder read-only
# into every container, which prefers the cached copy and falls back to the network
# if a file is missing. Host-side download failures are non-fatal — the container
# will still fetch from the network as before.
# Parse a "version" field from versions.json.
_json_ver() {
    grep -A2 "\"${1}\"" "$VERSIONS_FILE" | grep '"version"' | head -1 |
        sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Print the download URLs for a versions.json key (one per line), substituting
# {VERSION} and {ARCH}. URLs live entirely in versions.json so links can be
# changed there without touching this script.
#   $1 = json key, $2 = version (optional), $3 = arch (optional)
_json_urls() {
    sed -n "/\"$1\"[[:space:]]*:[[:space:]]*{/,/]/p" "$VERSIONS_FILE" |
        grep -oE 'https?://[^"]+' |
        sed -e "s/{VERSION}/${2:-}/g" -e "s/{ARCH}/${3:-}/g"
}

# fetch_dep <filename> <url> [mirror...] — skip if already cached and non-empty.
fetch_dep() {
    local filename="$1"
    shift
    local dest="$DOWNLOADS_DIR/$filename"

    if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge 1024 ]; then
        echo "    SKIP (cached): $filename"
        return 0
    fi

    if [ "$#" -eq 0 ]; then
        echo "    [WARN] no URLs in versions.json for $filename — skipping"
        return 0
    fi

    local url
    for url in "$@"; do
        echo "    GET: $filename <- $url"
        if wget -q --timeout=30 --connect-timeout=15 --tries=2 -O "$dest" "$url" &&
            [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge 1024 ]; then
            return 0
        fi
        rm -f "$dest"
    done

    echo "    [WARN] could not pre-download $filename — container will fetch it from the network"
    return 0
}

# fetch_json <json-key> <filename> [version] [arch] — resolve URLs from
# versions.json (mirrors included) and pre-download into downloads/.
fetch_json() {
    local key="$1" filename="$2" version="${3:-}" arch="${4:-}"
    local urls=()
    mapfile -t urls < <(_json_urls "$key" "$version" "$arch")
    fetch_dep "$filename" "${urls[@]}"
}

download_deps() {
    if [ ! -f "$VERSIONS_FILE" ]; then
        echo "[WARN] $VERSIONS_FILE not found — skipping host pre-download"
        return 0
    fi

    echo ">>> Pre-downloading source archives into $DOWNLOADS_DIR"

    local v_nginx v_openssl v_zlib v_pcre v_pcre2 v_php v_flv
    v_nginx=$(_json_ver nginx)
    v_openssl=$(_json_ver openssl)
    v_zlib=$(_json_ver zlib)
    v_pcre=$(_json_ver pcre)
    v_pcre2=$(_json_ver pcre2)
    v_php=$(_json_ver php)
    v_flv=$(_json_ver nginx_http_flv_module)

    fetch_json nginx                 "nginx-${v_nginx}.tar.gz"                    "$v_nginx"
    fetch_json openssl               "openssl-${v_openssl}.tar.gz"               "$v_openssl"
    fetch_json zlib                  "zlib-${v_zlib}.tar.gz"                     "$v_zlib"
    # Both PCRE and PCRE2 — old targets (debian11/ubuntu20) use PCRE, others PCRE2.
    fetch_json pcre                  "pcre-${v_pcre}.tar.gz"                     "$v_pcre"
    fetch_json pcre2                 "pcre2-${v_pcre2}.tar.gz"                   "$v_pcre2"
    fetch_json php                   "php-${v_php}.tar.gz"                       "$v_php"
    fetch_json nginx_http_flv_module "nginx-http-flv-module-${v_flv}.zip"        "$v_flv"

    # ionCube loader bundle for the host architecture (containers share host arch).
    local arch arch_tag
    arch="$(uname -m)"
    case "$arch" in
        x86_64 | amd64) arch_tag="x86-64" ;;
        aarch64 | arm64) arch_tag="aarch64" ;;
        *) arch_tag="" ; echo "    [WARN] unsupported arch '$arch' for ionCube pre-download" ;;
    esac
    if [ -n "$arch_tag" ]; then
        fetch_json ioncube "ioncube_loaders_lin_${arch_tag}.tar.gz" "" "$arch_tag"
    fi

    # network.py helper script.
    fetch_json network_py "network.py"

    echo ">>> Pre-download complete"
}

# ----------------------
# Build function
# ----------------------
build() {
    local name=$1
    local base=$2
    local target=$3
    local dockerfile=$4
    local logfile="$LOG_DIR/${target}.log"

    if [ -f "$OUT_DIR/${target}.tar.gz" ]; then
        echo ">>> SKIP: $target (archive already exists in out/)"
        return 0
    fi

    local ext_args=()
    if [ -d "$EXT_SRC_DIR" ]; then
        ext_args=(-v "$EXT_SRC_DIR:/build/ext_src:ro")
    else
        echo "[WARN] Extension sources not found at $EXT_SRC_DIR — license_ext will be skipped"
    fi

    echo ">>> IMAGE: $name (log: $logfile)"

    docker build \
        --build-arg BASE_IMAGE="$base" \
        -t "xcvm-builder:$name" \
        -f "$dockerfile" \
        "$ROOT_DIR" 2>&1 | tee "$logfile"

    echo ">>> BUILD: $target"

    docker run --rm \
        -e TARGET="$target" \
        -v "$OUT_DIR:/build/out" \
        -v "$DOWNLOADS_DIR:/build/downloads:ro" \
        "${ext_args[@]}" \
        "xcvm-builder:$name" 2>&1 | tee -a "$logfile"

    echo ">>> Log saved: $logfile"
}

# ----------------------
# Build groups
# ----------------------
build_debian() {
    build debian11 debian:11 debian_11 "$DOCKER_DIR/debian/Dockerfile"
    build debian12 debian:12 debian_12 "$DOCKER_DIR/debian/Dockerfile" # debian12 and ubuntu22
    build debian13 debian:13 debian_13 "$DOCKER_DIR/debian/Dockerfile"
}

build_ubuntu() {
    build ubuntu20 ubuntu:20.04 ubuntu_20 "$DOCKER_DIR/debian/Dockerfile"
    build ubuntu22 ubuntu:22.04 ubuntu_22 "$DOCKER_DIR/debian/Dockerfile"
    build ubuntu24 ubuntu:24.04 ubuntu_24 "$DOCKER_DIR/debian/Dockerfile"
}

build_rocky() {
    local logfile="$LOG_DIR/rocky_9.log"

    if [ -f "$OUT_DIR/rocky_9.tar.gz" ]; then
        echo ">>> SKIP: rocky_9 (archive already exists in out/)"
        return 0
    fi

    local ext_args=()
    if [ -d "$EXT_SRC_DIR" ]; then
        ext_args=(-v "$EXT_SRC_DIR:/build/ext_src:ro")
    else
        echo "[WARN] Extension sources not found at $EXT_SRC_DIR — license_ext will be skipped"
    fi

    echo ">>> IMAGE: rocky9 (log: $logfile)"

    docker build \
        -t xcvm-builder:rocky9 \
        -f "$DOCKER_DIR/rocky/Dockerfile" \
        "$ROOT_DIR" 2>&1 | tee "$logfile"

    echo ">>> BUILD: rocky_9"

    docker run --rm \
        -e TARGET=rocky_9 \
        -v "$OUT_DIR:/build/out" \
        -v "$DOWNLOADS_DIR:/build/downloads:ro" \
        "${ext_args[@]}" \
        xcvm-builder:rocky9 2>&1 | tee -a "$logfile"

    echo ">>> Log saved: $logfile"
}

# ----------------------
# CLI
# ----------------------
case "$1" in
    ""|all|debian|debian11|debian12|debian13|ubuntu|ubuntu20|ubuntu22|ubuntu24|rocky|rocky9)
        download_deps
        ;;
esac

case "$1" in
    ""|all)
        build_debian
        build_ubuntu
        build_rocky
        ;;
    debian)
        build_debian
        ;;
    debian11)
        build debian11 debian:11 debian_11 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    debian12)
        build debian12 debian:12 debian_12 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    debian13)
        build debian13 debian:13 debian_13 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    ubuntu)
        build_ubuntu
        ;;
    ubuntu20)
        build ubuntu20 ubuntu:20.04 ubuntu_20 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    ubuntu22)
        build ubuntu22 ubuntu:22.04 ubuntu_22 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    ubuntu24)
        build ubuntu24 ubuntu:24.04 ubuntu_24 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    rocky|rocky9)
        build_rocky
        ;;
    -h|--help)
        echo "Usage:"
        echo "  ./build.sh            Build all targets"
        echo "  ./build.sh all        Build all targets"
        echo "  ./build.sh debian     Build all Debian targets (debian11/12/13)"
        echo "  ./build.sh debian11   Build Debian 11 (TARGET=debian_11)"
        echo "  ./build.sh debian12   Build Debian 12 (TARGET=debian_12)"
        echo "  ./build.sh debian13   Build Debian 13 (TARGET=debian_13)"
        echo "  ./build.sh ubuntu     Build all Ubuntu targets"
        echo "  ./build.sh ubuntu20   Build Ubuntu 20.04 (TARGET=ubuntu_20)"
        echo "  ./build.sh ubuntu22   Build Ubuntu 22.04 (TARGET=ubuntu_22)"
        echo "  ./build.sh ubuntu24   Build Ubuntu 24.04 (TARGET=ubuntu_24)"
        echo "  ./build.sh rocky      Build Rocky 9 (TARGET=rocky_9)"
        exit 0
        ;;
    *)
        echo "Unknown target: $1"
        echo "Run ./build.sh --help"
        exit 1
        ;;
esac

# ----------------------
# Generate checksums
# ----------------------
if ls "$OUT_DIR"/*.tar.gz 1>/dev/null 2>&1; then
    echo ">>> Generating hashes.md5..."
    (cd "$OUT_DIR" && md5sum *.tar.gz > hashes.md5)
    echo ">>> Checksums saved: $OUT_DIR/hashes.md5"
fi

echo "=== XC_VM BUILD COMPLETED ==="
