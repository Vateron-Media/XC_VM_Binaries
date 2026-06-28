#!/bin/bash
# Compilation script for XC_VM on Debian 11/12 and Ubuntu 20.04/22.04/24.04
# Author: melcocha14@gmail.com
# Version: 1.8 (Improved with pipx and automatic detection of network.py)
# Date: 2025-12-10


set -e  # Exit if any command fails

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variables
XC_VM_DIR="/home/xc_vm"
BUILD_DIR="/tmp/xc_vm_build"
LOG_FILE="/tmp/xc_vm_build.log"
VERSIONS_FILE="/build/versions.json"
DISTRO_TYPE=""  # Detected in check_system()

# Version variables (loaded from versions.json in load_versions)
V_NGINX=""
V_OPENSSL=""
V_ZLIB=""
V_PCRE=""
V_PCRE2=""
V_PHP=""
V_FLV_MODULE=""

# Print the download URLs for a versions.json key (one per line), substituting
# {VERSION} and {ARCH}. All links live in versions.json so they can be edited
# there without touching this script.
#   $1 = json key, $2 = version (optional), $3 = arch (optional)
_json_urls() {
    sed -n "/\"$1\"[[:space:]]*:[[:space:]]*{/,/]/p" "$VERSIONS_FILE" |
        grep -oE 'https?://[^"]+' |
        sed -e "s/{VERSION}/${2:-}/g" -e "s/{ARCH}/${3:-}/g"
}

# download_json <key> <output-file> [version] [arch] — resolve the mirror list
# from versions.json and download (cache-aware via download_with_stats).
download_json() {
    local key="$1" file="$2" version="${3:-}" arch="${4:-}"
    local urls=()
    mapfile -t urls < <(_json_urls "$key" "$version" "$arch")
    if [[ ${#urls[@]} -eq 0 ]]; then
        error "No URLs in versions.json for '$key'"
    fi
    download_with_stats "${urls[0]}" "$file" "${urls[@]:1}"
}

# Load versions from versions.json
load_versions() {
    local vfile="$VERSIONS_FILE"
    if [[ ! -f "$vfile" ]]; then
        error "versions.json not found at $vfile"
    fi

    # Parse JSON with grep/sed (no python3 needed in minimal containers)
    _json_ver() {
        grep -A2 "\"${1}\"" "$2" | grep '"version"' | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
    }

    V_NGINX=$(_json_ver nginx "$vfile")
    V_OPENSSL=$(_json_ver openssl "$vfile")
    V_ZLIB=$(_json_ver zlib "$vfile")
    V_PCRE=$(_json_ver pcre "$vfile")
    V_PCRE2=$(_json_ver pcre2 "$vfile")
    V_PHP=$(_json_ver php "$vfile")
    V_FLV_MODULE=$(_json_ver nginx_http_flv_module "$vfile")

    # Validate that all versions were parsed
    for var in V_NGINX V_OPENSSL V_ZLIB V_PCRE V_PCRE2 V_PHP V_FLV_MODULE; do
        if [[ -z "${!var}" ]]; then
            error "Failed to parse $var from versions.json"
        fi
    done

    log "Loaded versions from versions.json:"
    log "  nginx=$V_NGINX openssl=$V_OPENSSL zlib=$V_ZLIB"
    log "  pcre=$V_PCRE pcre2=$V_PCRE2 php=$V_PHP flv=$V_FLV_MODULE"
}

# Function for logging
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    echo "[ERROR] $1" >> "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
    echo "[WARN] $1" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
    echo "[INFO] $1" >> "$LOG_FILE"
}

# Function to check if it is running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script MUST be run as root to function correctly."
        error "Run: sudo $0"
        exit 1
    fi
    log "Running as root - ✓"
}

# Function to check the operating system
check_system() {
    log "Checking operating system..."

    # Попробуем lsb_release
    if command -v lsb_release &> /dev/null; then
        OS=$(lsb_release -si)
        VERSION=$(lsb_release -sr)
    else
        # fallback на /etc/os-release
        . /etc/os-release
        OS="$ID"
        VERSION="$VERSION_ID"
    fi

    # Нормализуем имя дистрибутива
    case "$OS" in
        Debian|debian)
            DISTRO_TYPE="Debian"
            ;;
        Ubuntu|ubuntu)
            DISTRO_TYPE="Ubuntu"
            ;;
        *)
            error "Unsupported OS: $OS"
            ;;
    esac

    # Версия для сравнения (целое число)
    # Берем только основную версию до точки
    VERSION_MAJOR="${VERSION%%.*}"

    log "System detected: $DISTRO_TYPE $VERSION (major: $VERSION_MAJOR)"
}


# Function to install system dependencies
install_dependencies() {
    log "Installing system dependencies..."

    # Source os-release early so $ID is available for all distro-specific checks
    . /etc/os-release

    apt-get update -y

    # Base build dependencies (common для всех дистрибутивов)
    apt-get install -y \
        build-essential zlib1g zlib1g-dev libssl-dev \
        libgd-dev libxml2 libxml2-dev uuid-dev libxslt1-dev \
        unzip wget curl git lsb-release \
        python3 python3-pip python3-venv \
        libcurl4-gnutls-dev libbz2-dev libzip-dev autoconf automake \
        libtool m4 gcc make pkg-config libmaxminddb-dev libssh2-1-dev \
        libjpeg-dev libfreetype6-dev libsodium-dev libonig-dev

    # PCRE selection: Debian 12+ / Ubuntu 22+ -> PCRE2, otherwise PCRE1
    if [[ "$ID" == "debian" && "$VERSION_MAJOR" -ge 12 ]] || [[ "$ID" == "ubuntu" && "$VERSION_MAJOR" -ge 22 ]]; then
        log "Installing PCRE2 (Debian 12+ / Ubuntu 22+)"
        apt-get install -y libpcre2-8-0 libpcre2-dev
    else
        log "Installing PCRE1 (Debian 11 / Ubuntu 18 / Ubuntu 20)"
        apt-get install -y libpcre3 libpcre3-dev
    fi

    # Detect OS version
    . /etc/os-release
    log "Detected OS: $PRETTY_NAME"

    USE_PIPX=false

    # pipx available only on:
    # - Debian 12+ (12,13)
    # - Ubuntu 22+ (22,24)
    if [[ "$ID" == "debian" ]]; then
        if [[ "$VERSION_MAJOR" -ge 12 ]]; then
            USE_PIPX=true
        fi
    elif [[ "$ID" == "ubuntu" ]]; then
        if [[ "$VERSION_MAJOR" -ge 22 ]]; then
            USE_PIPX=true
        fi
    fi

    if $USE_PIPX; then
        log "pipx supported on this system"

        if ! command -v pipx &> /dev/null; then
            log "Installing pipx..."

            # python3-full exists only on newer systems
            if apt-cache show python3-full &> /dev/null; then
                apt-get install -y pipx python3-full
            else
                apt-get install -y pipx
            fi
        fi

        pipx ensurepath
        export PATH="$HOME/.local/bin:$PATH"

        grep -q '.local/bin' /root/.bashrc || \
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc

        if ! command -v pyinstaller &> /dev/null; then
            log "Installing PyInstaller with pipx..."
            pipx install pyinstaller || USE_PIPX=false
        fi
    fi

    # Free disk space: clean apt cache (after pipx install)
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # Fallback for Debian 11 / Ubuntu 20.04 or pipx failure
    if ! $USE_PIPX; then
        warn "pipx unavailable, using virtualenv"

        if ! command -v pyinstaller &> /dev/null; then
            log "Installing PyInstaller via venv..."
            python3 -m venv /opt/pyinstaller_env

            # Pin versions for Python < 3.8 (e.g. Ubuntu 18.04 with Python 3.6)
            if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)'; then
                /opt/pyinstaller_env/bin/pip install --upgrade pip
                /opt/pyinstaller_env/bin/pip install pyinstaller
            else
                warn "Python < 3.8 detected, using compatible versions"
                /opt/pyinstaller_env/bin/pip install --upgrade "pip<22"
                /opt/pyinstaller_env/bin/pip install "pyinstaller<5"
            fi

            ln -sf /opt/pyinstaller_env/bin/pyinstaller /usr/local/bin/pyinstaller
        fi
    fi

    # Verify
    if command -v pyinstaller &> /dev/null; then
        log "✓ PyInstaller available: $(pyinstaller --version)"
    else
        error "Could not install PyInstaller"
    fi

    log "Dependencies installed correctly"
}

# Function to create necessary directories
setup_directories() {
    log "Configuring directories..."

    # Create base directories
    mkdir -p "$XC_VM_DIR/bin"
    # Assign permissions to the user if it exists, if not, keep as root
    if id -u "$SUDO_USER" 2>/dev/null; then
        chown -R $SUDO_USER:$SUDO_USER "$XC_VM_DIR"
    fi

    # Create temporary build directory
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    log "Directories configured"
}

download_with_stats() {
    local url="$1"
    local file="$2"
    shift 2
    local mirror_urls=("$@")
    local filename
    filename=$(basename "$file")

    # Prefer the host-mounted cache (build_all.sh pre-downloads into ./downloads,
    # mounted read-only at /build/downloads). Fall back to the network if absent.
    local cache="/build/downloads/$filename"
    if [[ -f "$cache" && $(stat -c%s "$cache" 2>/dev/null || echo 0) -ge 1024 ]]; then
        cp -f "$cache" "$file"
        log "✓ ${filename}: from /build/downloads (cached)"
        return 0
    fi

    local all_urls=("$url" "${mirror_urls[@]}")
    local attempt=0
    local max_attempts=${#all_urls[@]}

    for try_url in "${all_urls[@]}"; do
        attempt=$((attempt + 1))

        if (( max_attempts > 1 )); then
            echo -ne "${BLUE}[INFO] Downloading ${filename} (source ${attempt}/${max_attempts})...${NC}"
        else
            echo -ne "${BLUE}[INFO] Downloading ${filename}...${NC}"
        fi

        local start_ts end_ts size duration speed size_mb
        start_ts=$(date +%s)

        local wget_status=0
        # Quiet download with progress, timeout and retries
        if wget --help 2>&1 | grep -q '\-\-show-progress'; then
            wget -q --show-progress --progress=bar:force:noscroll \
                --timeout=30 --connect-timeout=15 --tries=2 \
                -O "$file" "$try_url" 2>&1 || wget_status=$?
        else
            # Fallback for older wget
            wget -q --timeout=30 --connect-timeout=15 --tries=2 \
                -O "$file" "$try_url" || wget_status=$?
        fi

        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))

        # Clear the line and show result
        echo -ne "\r\033[K"

        if [[ $wget_status -eq 0 && -f "$file" ]]; then
            size=$(stat -c%s "$file")
            # Skip empty or suspiciously small files (< 1KB)
            if (( size < 1024 )); then
                warn "Downloaded file too small (${size} bytes), trying next source..."
                rm -f "$file"
                continue
            fi
            size_mb=$((size / 1024 / 1024))
            if (( duration > 0 )); then
                speed=$((size / duration / 1024))
            else
                speed=$((size / 1024))
            fi
            log "✓ ${filename}: ${size_mb} MB in ${duration}s (~${speed} KB/s)"
            return 0
        else
            rm -f "$file"
            if (( attempt < max_attempts )); then
                warn "Download failed from source ${attempt}, trying next mirror..."
            fi
        fi
    done

    echo -e "${RED}[ERROR] Download failed: ${filename} (all sources exhausted)${NC}"
    echo "[ERROR] Download failed: $file" >> "$LOG_FILE"
    return 1
}

# Function to download NGINX dependencies
download_nginx_deps() {
    log "Downloading NGINX dependencies..."
    cd "$BUILD_DIR"

    # OpenSSL
    if [[ ! -d "openssl-${V_OPENSSL}" ]]; then
        download_json openssl "openssl-${V_OPENSSL}.tar.gz" "$V_OPENSSL"
        tar -xzf openssl-${V_OPENSSL}.tar.gz
    fi

    # Zlib
    if [[ ! -d "zlib-${V_ZLIB}" ]]; then
        download_json zlib "zlib-${V_ZLIB}.tar.gz" "$V_ZLIB"
        tar -xzf zlib-${V_ZLIB}.tar.gz
    fi

    # PCRE selection based on OS
    . /etc/os-release
    if [[ "$ID" == "debian" && "$VERSION_MAJOR" -ge 12 ]] || [[ "$ID" == "ubuntu" && "$VERSION_MAJOR" -ge 22 ]]; then
        # Use PCRE2
        if [[ ! -d "pcre2-${V_PCRE2}" ]]; then
            download_json pcre2 "pcre2-${V_PCRE2}.tar.gz" "$V_PCRE2"
            tar -xzf pcre2-${V_PCRE2}.tar.gz
        fi

        PCRE_DIR="pcre2-${V_PCRE2}"
        PCRE_FLAGS=""

    else
        if [[ ! -d "pcre-${V_PCRE}" ]]; then
            download_json pcre "pcre-${V_PCRE}.tar.gz" "$V_PCRE"
            tar -xzf pcre-${V_PCRE}.tar.gz
        fi

        PCRE_DIR="pcre-${V_PCRE}"
        PCRE_FLAGS="--with-pcre-jit"
    fi

    # Compiler hardening flags
    NGINX_CFLAGS="-O2 -g -pipe -Wall -fexceptions -fstack-protector --param=ssp-buffer-size=4"

    # Static-only flags (used only for standard nginx)
    NGINX_STATIC_CFLAGS="-static -static-libgcc -m64 -mtune=generic -fPIC"

    # Static linker flags — disable PIE on older toolchains (GCC < 10)
    if [[ "$DISTRO_TYPE" == "Ubuntu" && "$VERSION_MAJOR" -le 20 ]]; then
        NGINX_STATIC_LDFLAGS='-static -Wl,-z,relro -Wl,-z,now'
    else
        NGINX_STATIC_LDFLAGS='-static -Wl,-z,relro -Wl,-z,now -pie'
    fi

    # Ubuntu 24 already defines _FORTIFY_SOURCE internally
    if [[ "$DISTRO_TYPE" != "Ubuntu" || "$VERSION_MAJOR" -ne 24 ]]; then
        NGINX_CFLAGS+=" -Wp,-D_FORTIFY_SOURCE=2"
        log "FORTIFY_SOURCE enabled"
    else
        log "FORTIFY_SOURCE disabled (Ubuntu 24)"
    fi

    log "NGINX dependencies downloaded"
}

# Function to download NGINX modules
download_nginx_modules() {
    log "Downloading NGINX modules..."

    cd "$BUILD_DIR"

    # FLV Module
    if [[ ! -d "nginx-http-flv-module-${V_FLV_MODULE}" ]]; then
        download_json nginx_http_flv_module "nginx-http-flv-module-${V_FLV_MODULE}.zip" "$V_FLV_MODULE" \
            || error "Error downloading HTTP-FLV module"
        if ! unzip -q nginx-http-flv-module-${V_FLV_MODULE}.zip; then
            error "Error extracting HTTP-FLV module"
        fi
    fi

    # RTMP Module
    # if [[ ! -d "nginx-rtmp-module-1.2.2" ]]; then
    #     log "Downloading RTMP module..."
    #     rm -f nginx-rtmp-module-1.2.2.tar.gz  # Clean previous download file if it exists
    #     rm -f v1.2.2.tar.gz  # Clean possible file with incorrect name

    #     # Download from GitHub forcing the correct name
    #     log "Downloading RTMP module from GitHub..."
    #     wget --no-check-certificate --timeout=30 -O nginx-rtmp-module-1.2.2.tar.gz \
    #         https://github.com/arut/nginx-rtmp-module/archive/refs/tags/v1.2.2.tar.gz

    #     # Verify that the file was downloaded
    #     if [[ ! -f "nginx-rtmp-module-1.2.2.tar.gz" ]]; then
    #         # If the name doesn't work, try with codeload
    #         log "Trying from codeload..."
    #         wget --no-check-certificate --timeout=30 -O nginx-rtmp-module-1.2.2.tar.gz \
    #             https://codeload.github.com/arut/nginx-rtmp-module/tar.gz/v1.2.2
    #     fi

    #     # Final verification
    #     if [[ ! -f "nginx-rtmp-module-1.2.2.tar.gz" ]]; then
    #         error "Could not download RTMP module from any source"
    #     fi

    #     log "File downloaded, verifying size..."
    #     ls -la nginx-rtmp-module-1.2.2.tar.gz

    #     if ! tar -xzf nginx-rtmp-module-1.2.2.tar.gz; then
    #         error "Error extracting RTMP module"
    #     fi
    # fi

    # Verify that the modules were downloaded correctly
    if [[ ! -d "nginx-http-flv-module-${V_FLV_MODULE}" ]]; then
        error "HTTP-FLV module was not downloaded correctly"
    fi

    # if [[ ! -d "nginx-rtmp-module-1.2.2" ]]; then
    #     error "RTMP module was not downloaded correctly"
    # fi

    log "✓ NGINX modules downloaded correctly"
}

# Function to compile standard NGINX
build_nginx() {
    log "Compiling standard NGINX..."
    cd "$BUILD_DIR"

    # Download NGINX (with mirrors — nginx.org can be slow)
    if [[ ! -d "nginx-${V_NGINX}" ]]; then
        download_json nginx "nginx-${V_NGINX}.tar.gz" "$V_NGINX" \
            || error "Error downloading NGINX"
        tar -xzf nginx-${V_NGINX}.tar.gz
    fi

    cd nginx-${V_NGINX}

    # Configure compilation
    log "Configuring NGINX..."
    ./configure \
        --prefix="$XC_VM_DIR/bin/nginx" \
        --with-compat \
        --with-http_auth_request_module \
        --with-file-aio \
        --with-threads \
        --with-http_gzip_static_module \
        --with-http_realip_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_v2_module \
        --with-cc-opt="$NGINX_STATIC_CFLAGS $NGINX_CFLAGS" \
        --with-ld-opt="$NGINX_STATIC_LDFLAGS" \
        --with-pcre="../$PCRE_DIR" \
        $PCRE_FLAGS \
        --with-zlib=../zlib-${V_ZLIB} \
        --with-openssl=../openssl-${V_OPENSSL} \
        --with-openssl-opt=no-nextprotoneg

    # Compile and install
    log "Compiling NGINX..."
    make -j$(nproc)
    make install

    # Verify installation
    if [[ -f "$XC_VM_DIR/bin/nginx/sbin/nginx" ]]; then
        log "NGINX compiled successfully"
        "$XC_VM_DIR/bin/nginx/sbin/nginx" -V
    else
        error "NGINX was not compiled correctly"
    fi

    log "Standard NGINX compiled and installed"
}

# Function to compile NGINX with RTMP
build_nginx_rtmp() {
    log "Compiling NGINX with RTMP..."

    cd "$BUILD_DIR/nginx-${V_NGINX}"

    # Clean previous configuration
    make clean || true

    log "Configuring NGINX with RTMP..."
    ./configure \
        --prefix="$XC_VM_DIR/bin/nginx_rtmp" \
        --add-module=../nginx-http-flv-module-${V_FLV_MODULE} \
        --with-compat \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_auth_request_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_realip_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_slice_module \
        --with-http_gzip_static_module \
        --with-file-aio \
        --with-threads \
        --with-http_sub_module \
        --with-pcre="../$PCRE_DIR" \
        $PCRE_FLAGS \
        --with-zlib=../zlib-${V_ZLIB} \
        --with-openssl=../openssl-${V_OPENSSL} \
        --with-openssl-opt="no-shared -fPIC" \
        --with-cc-opt="$NGINX_CFLAGS" \
        --with-ld-opt='-Wl,-z,relro -Wl,-z,now -pie'

    log "Compiling NGINX RTMP..."
    make -j$(nproc)
    make install

    # Rename executable
    if [[ -f "$XC_VM_DIR/bin/nginx_rtmp/sbin/nginx" ]]; then
        mv "$XC_VM_DIR/bin/nginx_rtmp/sbin/nginx" "$XC_VM_DIR/bin/nginx_rtmp/sbin/nginx_rtmp"
        log "NGINX RTMP compiled successfully"
    else
        warn "Could not find NGINX RTMP binary"
    fi

    log "NGINX with RTMP compiled and installed"

    # Free disk space: remove nginx/openssl/zlib/pcre sources (no longer needed)
    log "Freeing disk space after NGINX builds..."
    cd "$BUILD_DIR"
    rm -rf nginx-${V_NGINX} openssl-${V_OPENSSL} zlib-${V_ZLIB} \
           pcre-* pcre2-* ngx_* nginx-http-flv-module-* \
           maxmind lua-* headers-more-* 2>/dev/null || true
    rm -f *.tar.gz *.zip 2>/dev/null || true
    log "Freed disk space successfully"
}

# Function to compile PHP-FPM
build_php() {
    log "Compiling PHP-FPM ${V_PHP}..."

    cd "$BUILD_DIR"

    # Download PHP
    if [[ ! -d "php-${V_PHP}" ]]; then
        download_json php "php-${V_PHP}.tar.gz" "$V_PHP" || error "Error downloading PHP"
        tar -xzf php-${V_PHP}.tar.gz
    fi

    cd php-${V_PHP}

    # Configure compilation
    log "Configuring PHP..."
    ./configure \
        --prefix="$XC_VM_DIR/bin/php" \
        --enable-fpm \
        --with-fpm-user=xc_vm \
        --with-fpm-group=xc_vm \
        --with-openssl \
        --with-zlib \
        --with-curl \
        --enable-mbstring \
        --with-pdo-mysql \
        --with-mysqli \
        --enable-gd \
        --with-jpeg \
        --with-freetype \
        --enable-static \
        --disable-shared \
        --enable-opcache \
        --without-sqlite3 \
        --without-pdo-sqlite \
        --enable-mysqlnd \
        --disable-cgi \
        --enable-sockets \
        --enable-shmop \
        --enable-sysvsem \
        --enable-sysvshm \
        --enable-sysvmsg \
        --enable-calendar \
        --disable-rpath \
        --enable-inline-optimization \
        --enable-pcntl \
        --enable-mbregex \
        --enable-exif \
        --enable-bcmath \
        --with-mhash \
        --with-gettext \
        --with-xmlrpc \
        --with-xsl \
        --with-libxml \
        --with-sodium=/usr \
        --with-pear

    # Compile and install
    log "Compiling PHP..."
    make -j$(nproc)
    make install

    # Verify sodium extension availability
    if ! "$XC_VM_DIR/bin/php/bin/php" -m | grep -qi '^sodium$'; then
        error "PHP sodium extension not available. Check libsodium-dev and rebuild."
    fi

    # Copy configuration files
    cp php.ini-development "$XC_VM_DIR/bin/php/lib/php.ini"
    cp sapi/fpm/php-fpm.conf "$XC_VM_DIR/bin/php/etc/php-fpm.conf.default"
    cp sapi/fpm/www.conf "$XC_VM_DIR/bin/php/etc/php-fpm.d/www.conf.default"

    log "PHP-FPM compiled and installed"
}

# Function to install PHP extensions
install_php_extensions() {
    log "Installing PHP extensions..."

    cd "$BUILD_DIR"

    # Set PATH for PHP
    export PATH="$XC_VM_DIR/bin/php/bin:$PATH"

    local pecl="$XC_VM_DIR/bin/php/bin/pecl"
    if [[ ! -x "$pecl" ]]; then
        warn "PECL not found at $pecl. Skipping extension installation."
        return 0
    fi

    log "Installing extensions with PECL..."

    local ext_dir
    ext_dir="$("$XC_VM_DIR/bin/php/bin/php-config" --extension-dir)"
    mkdir -p "$ext_dir"

    # Update PECL channel to avoid protocol warnings
    "$pecl" channel-update pecl.php.net || true

    _pecl_ext maxminddb maxminddb.so
    _pecl_ext ssh2      ssh2.so
    _pecl_ext igbinary  igbinary.so
    _pecl_ext redis     redis.so

    log "PHP extensions installed"
}

# _pecl_ext <pecl-package> <so-filename> — build/install one PECL extension and
# register it in php.ini ONLY if its .so was actually produced. A failed build
# must not leave a dangling "extension=" line: that triggers a PHP startup
# warning on every run (e.g. "Unable to load dynamic library 'maxminddb.so'").
# Missing extensions are surfaced loudly here and hard-failed by
# verify_php_extensions. Relies on $pecl and $ext_dir set by the caller.
_pecl_ext() {
    local pkg="$1" so="$2"
    log "Installing PHP extension: $pkg"
    echo "yes" | "$pecl" install "$pkg" || warn "pecl install $pkg reported an error"
    if [[ -f "$ext_dir/$so" ]]; then
        echo "extension=$so" >> "$XC_VM_DIR/bin/php/lib/php.ini"
        log "✓ $pkg installed ($ext_dir/$so)"
    else
        warn "✗ $pkg: $so not built/installed in $ext_dir — not adding to php.ini"
    fi
}

# Verify that every PHP extension we expect is actually loaded. The PECL installs
# above only warn on failure, so without this check a build can finish
# "successfully" while silently missing extensions the application needs.
verify_php_extensions() {
    log "Verifying PHP extensions..."

    local php_bin="$XC_VM_DIR/bin/php/bin/php"
    [[ -x "$php_bin" ]] || error "PHP binary not found at $php_bin — cannot verify extensions"

    # Names as printed by 'php -m' (matched case-insensitively, whole word).
    # opcache shows up as "Zend OPcache". Covers both compiled-in (configure
    # flags in build_php) and PECL-installed extensions.
    local required=(
        bcmath calendar curl exif gd gettext libxml mbstring mysqli
        mysqlnd opcache openssl pcntl pdo_mysql shmop sockets sodium
        sysvmsg sysvsem sysvshm xsl zlib
        igbinary maxminddb redis ssh2
    )

    # Snapshot loaded modules once (lowercased) instead of spawning php per check.
    local loaded
    loaded="$("$php_bin" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"

    local missing=() ext
    for ext in "${required[@]}"; do
        grep -qiw -- "$ext" <<< "$loaded" || missing+=("$ext")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing PHP extensions: ${missing[*]} (full module list in $LOG_FILE)"
    fi

    log "✓ All ${#required[@]} required PHP extensions present"

    # ionCube Loader is added to php.ini conditionally (per architecture);
    # report its status without failing the build.
    if grep -qw 'ioncube loader' <<< "$loaded"; then
        log "✓ ionCube Loader present"
    else
        warn "ionCube Loader not loaded — ioncube_v1 modules will not run"
    fi
}

# Function to install the ionCube Loader.
# Required at runtime for ioncube_v1 modules (which ship as IonCube-encoded
# PHP). The loader is a Zend extension and MUST be loaded BEFORE xcvm_core.so —
# we register it here, right after build_php and before any other (zend_)extension
# is appended to php.ini, so it is always the first one PHP loads.
install_ioncube_loader() {
    log "Installing ionCube Loader..."

    cd "$BUILD_DIR"

    # PHP major.minor (e.g. 8.1 from 8.1.34) selects the matching loader .so.
    local php_mm="${V_PHP%.*}"

    # ionCube ships one bundle per CPU architecture.
    local arch arch_tag loader_pkg
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  arch_tag="x86-64" ;;
        aarch64|arm64) arch_tag="aarch64" ;;
        *) warn "ionCube: unsupported architecture '$arch' — skipping loader"; return 0 ;;
    esac
    loader_pkg="ioncube_loaders_lin_${arch_tag}.tar.gz"

    download_json ioncube "${loader_pkg}" "" "$arch_tag" \
        || { warn "ionCube: download failed — skipping loader"; return 0; }

    rm -rf ioncube
    tar -xzf "${loader_pkg}" || { warn "ionCube: extract failed — skipping loader"; return 0; }

    # PHP-FPM here is built non-thread-safe (no --enable-zts), so use the
    # non-_ts loader matching the PHP version.
    local loader_so="ioncube/ioncube_loader_lin_${php_mm}.so"
    if [[ ! -f "$loader_so" ]]; then
        warn "ionCube: no loader for PHP ${php_mm} in bundle ($loader_so) — skipping"
        return 0
    fi

    local ext_dir
    ext_dir="$("$XC_VM_DIR/bin/php/bin/php-config" --extension-dir)"
    mkdir -p "$ext_dir"
    cp "$loader_so" "$ext_dir/ioncube_loader_lin_${php_mm}.so"
    chmod 0755 "$ext_dir/ioncube_loader_lin_${php_mm}.so"

    echo "zend_extension=$ext_dir/ioncube_loader_lin_${php_mm}.so" >> "$XC_VM_DIR/bin/php/lib/php.ini"

    # Verify the loader is recognised (CLI uses the same php.ini).
    if "$XC_VM_DIR/bin/php/bin/php" -v 2>/dev/null | grep -qi 'ionCube'; then
        log "✓ ionCube Loader ${php_mm} installed and active ($ext_dir)"
    else
        warn "ionCube Loader installed but not detected by 'php -v' — check php.ini ordering"
    fi
}

# Enable Zend OPcache in php.ini.
# OPcache is a Zend extension: --enable-opcache builds opcache.so into the
# extension dir, but PHP never loads it unless php.ini carries an explicit
# 'zend_extension=...opcache.so' line. The copied php.ini-development keeps that
# line commented, so without this step 'php -m' omits "Zend OPcache" and
# verify_php_extensions hard-fails. Registered AFTER install_ioncube_loader so
# the ionCube loader stays the first zend_extension in php.ini.
enable_opcache() {
    log "Enabling Zend OPcache..."

    local php_ini="$XC_VM_DIR/bin/php/lib/php.ini"
    local ext_dir
    ext_dir="$("$XC_VM_DIR/bin/php/bin/php-config" --extension-dir)"

    if [[ ! -f "$ext_dir/opcache.so" ]]; then
        warn "opcache.so not found in $ext_dir — was PHP built with --enable-opcache?"
        return 0
    fi

    echo "zend_extension=$ext_dir/opcache.so" >> "$php_ini"

    if "$XC_VM_DIR/bin/php/bin/php" -v 2>/dev/null | grep -qi 'Zend OPcache'; then
        log "✓ Zend OPcache enabled ($ext_dir/opcache.so)"
    else
        warn "opcache.so registered but not detected by 'php -v' — check php.ini ordering"
    fi
}

# Function to create network.py if it does not exist
create_network_py() {
    # Prefer the host-mounted cache, fall back to GitHub.
    if [[ -f /build/downloads/network.py ]]; then
        log "Using cached network.py from /build/downloads"
        cp -f /build/downloads/network.py "$XC_VM_DIR/bin/network.py"
        return 0
    fi

    log "Downloading network.py..."

    # URL(s) come from versions.json (network_py).
    local u
    for u in $(_json_urls network_py); do
        if curl -fsSL "$u" -o "$XC_VM_DIR/bin/network.py"; then
            log "network.py successfully downloaded to $XC_VM_DIR/bin/network.py"
            return 0
        fi
    done

    log "Failed to download network.py"
    return 1
}

build_network_binary() {
    log "Compiling network binary..."

    # Ensure PyInstaller exists
    if ! command -v pyinstaller &>/dev/null; then
        error "PyInstaller is not available. Install dependencies first."
    fi

    # Ensure bin directory exists
    mkdir -p "$XC_VM_DIR/bin"
    cd "$XC_VM_DIR/bin"

    # Always download fresh network.py
    create_network_py

    if [[ ! -f "network.py" ]]; then
        error "network.py is missing after download"
    fi

    log "Compiling network.py with PyInstaller..."

    export PATH="$HOME/.local/bin:$PATH"

    if pyinstaller --onefile --name network --strip network.py; then
        if [[ -f "dist/network" ]]; then
            mv dist/network ./network
            chmod +x network
            rm -rf build dist network.spec __pycache__

            log "✓ Binary network compiled: $XC_VM_DIR/bin/network"

            # Verify the binary
            if [[ -f "./network" ]]; then
                log "Verifying binary..."
                ./network --version || log "Binary network created (without version verification)"
            fi
        else
            error "Binary network was not generated"
        fi
    else
        error "PyInstaller compilation failed"
    fi
}

# Function to build the private PHP extension (sources mounted at /build/ext_src)
build_php_extension() {
    local ext_src="/build/ext_src"
    if [[ ! -d "$ext_src" ]]; then
        warn "Extension sources not mounted at $ext_src — skipping xcvm_core build"
        return 0
    fi

    log "Building PHP extension (xcvm_core)..."

    local phpize="$XC_VM_DIR/bin/php/bin/phpize"
    local php_config="$XC_VM_DIR/bin/php/bin/php-config"

    if [[ ! -x "$phpize" ]]; then
        warn "phpize not found at $phpize — skipping extension build"
        return 0
    fi

    local ext_build="/tmp/xcvm_core_build"
    rm -rf "$ext_build"
    cp -r "$ext_src" "$ext_build"
    cd "$ext_build"

    "$phpize"
    ./configure --with-php-config="$php_config" --enable-xcvm_core
    make build-modules

    local ext_dir
    ext_dir="$("$php_config" --extension-dir)"
    cp modules/xcvm_core.so "$ext_dir/"
    chmod 0755 "$ext_dir/xcvm_core.so"

    # Verify the extension actually loads
    if "$XC_VM_DIR/bin/php/bin/php" -d "extension=$ext_dir/xcvm_core.so" -r 'echo "ok";' > /dev/null 2>&1; then
        log "✓ xcvm_core.so installed and loads correctly ($ext_dir)"
    else
        warn "xcvm_core.so installed but failed to load — check dependencies"
    fi

    rm -rf "$ext_build"
}

# Function to clean up temporary files
cleanup() {
    log "Cleaning up temporary files..."

    # Only clean compilation files, not the final binaries
    cd "$BUILD_DIR"

    # Remove downloaded archives
    rm -f *.tar.gz *.zip 2>/dev/null || true

    # Remove source/build directories to reclaim space
    rm -rf nginx-${V_NGINX} php-${V_PHP} openssl-${V_OPENSSL} zlib-${V_ZLIB} \
           pcre-* pcre2-* ngx_* nginx-http-flv-module-* \
           maxmind lua-* headers-more-* ioncube 2>/dev/null || true

    # Clean apt cache
    apt-get clean 2>/dev/null || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true

    log "Cleanup completed"
}

# Function to show final summary
show_summary() {
    log "============================================"
    log "         COMPILATION COMPLETED"
    log "============================================"
    log "Compiled files available in: $XC_VM_DIR/bin/"
    log ""

    # Verify standard NGINX
    if [[ -f "$XC_VM_DIR/bin/nginx/sbin/nginx" ]]; then
        info "✓ Standard NGINX: $XC_VM_DIR/bin/nginx/sbin/nginx"
        info "  Verify: $XC_VM_DIR/bin/nginx/sbin/nginx -V"
    else
        warn "✗ Standard NGINX not found"
    fi

    # Verify NGINX RTMP
    if [[ -f "$XC_VM_DIR/bin/nginx_rtmp/sbin/nginx_rtmp" ]]; then
        info "✓ NGINX with RTMP: $XC_VM_DIR/bin/nginx_rtmp/sbin/nginx_rtmp"
    else
        warn "✗ NGINX RTMP not found"
    fi

    # Verify PHP
    if [[ -f "$XC_VM_DIR/bin/php/sbin/php-fpm" ]]; then
        info "✓ PHP-FPM: $XC_VM_DIR/bin/php/sbin/php-fpm"
    else
        warn "✗ PHP-FPM not found"
    fi

    # Verify network binary
    if [[ -f "$XC_VM_DIR/bin/network" ]]; then
        info "✓ Binary network: $XC_VM_DIR/bin/network"
    else
        warn "✗ Binary network not found"
    fi

    log ""
    log "Full log available in: $LOG_FILE"
    log "============================================"
}

# Main compilation function
main() {
    log "Starting XC_VM compilation"

    # Load version config
    load_versions

    # Initial checks
    check_root
    check_system

    # Installation and configuration
    install_dependencies
    setup_directories

    # Download dependencies and modules
    download_nginx_deps
    download_nginx_modules

    # Compilation of applications
    build_nginx
    build_nginx_rtmp
    build_php

    # ionCube Loader first (must precede xcvm_core and other extensions in php.ini)
    install_ioncube_loader

    # Zend OPcache next (after ionCube so the loader stays first in php.ini)
    enable_opcache

    # Extensions and additional binary
    install_php_extensions
    build_php_extension
    verify_php_extensions
    build_network_binary

    # Cleanup and summary
    cleanup
    show_summary

    log "Compilation finished successfully!"
}

# Flags
case "$1" in
    -h|--help) echo "Uso: sudo $0 [-h|--help]"; exit 0 ;;
    -c|--clean) rm -rf "$BUILD_DIR" "$XC_VM_DIR/bin"; exit 0 ;;
    *) main ;;
esac