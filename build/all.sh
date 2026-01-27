#!/bin/bash
# Compilation script for XC_VM on Debian 11, 12 (Ubuntu 22) and Ubuntu 20.04
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
DISTRO_TYPE=""  # Detected in check_system()

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

    apt-get update -y

    # Base build dependencies (common для всех дистрибутивов)
    apt-get install -y \
        build-essential zlib1g zlib1g-dev libssl-dev \
        libgd-dev libxml2 libxml2-dev uuid-dev libxslt1-dev \
        unzip wget curl git lsb-release \
        python3 python3-pip python3-venv \
        libcurl4-gnutls-dev libbz2-dev libzip-dev autoconf automake \
        libtool m4 gcc make pkg-config libmaxminddb-dev libssh2-1-dev \
        libjpeg-dev libfreetype6-dev

    # PCRE selection: Debian 13 / Ubuntu 24 → PCRE2, иначе PCRE1
    if apt-cache show libpcre2-dev &> /dev/null; then
        log "Installing PCRE2 (Debian 13 / Ubuntu 24)"
        apt-get install -y libpcre2-8-0 libpcre2-dev
    else
        log "Installing PCRE1 (Debian 11 / 12 / Ubuntu 20 / 22)"
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

    # Fallback for Debian 11 / Ubuntu 20.04 or pipx failure
    if ! $USE_PIPX; then
        warn "pipx unavailable, using virtualenv"

        if ! command -v pyinstaller &> /dev/null; then
            log "Installing PyInstaller via venv..."
            python3 -m venv /opt/pyinstaller_env
            /opt/pyinstaller_env/bin/pip install --upgrade pip
            /opt/pyinstaller_env/bin/pip install pyinstaller
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

# Function to download NGINX dependencies
download_nginx_deps() {
    log "Downloading NGINX dependencies..."
    cd "$BUILD_DIR"

    # OpenSSL
    if [[ ! -d "openssl-3.5.1" ]]; then
        log "Downloading OpenSSL 3.5.1..."
        wget -q https://github.com/openssl/openssl/releases/download/openssl-3.5.1/openssl-3.5.1.tar.gz
        tar -xzf openssl-3.5.1.tar.gz
    fi

    # Zlib
    if [[ ! -d "zlib-1.3.1" ]]; then
        log "Downloading Zlib 1.3.1..."
        wget -q https://zlib.net/zlib-1.3.1.tar.gz
        tar -xzf zlib-1.3.1.tar.gz
    fi

    # PCRE selection based on OS
    . /etc/os-release
    if [[ "$ID" == "debian" && "$VERSION_ID" -ge 12 ]] || [[ "$ID" == "ubuntu" && "$VERSION_MAJOR" -ge 22 ]]; then
        # Use PCRE2
        if [[ ! -d "pcre2-10.42" ]]; then
            log "Downloading PCRE2 10.42..."
            wget -q https://github.com/PhilipHazel/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz
            tar -xzf pcre2-10.42.tar.gz
        fi
        PCRE_DIR="pcre2-10.42"
        PCRE_FLAGS=""
    else
        # Use PCRE1
        if [[ ! -d "pcre-8.45" ]]; then
            log "Downloading PCRE 8.45..."
            wget -q https://sourceforge.net/projects/pcre/files/pcre/8.45/pcre-8.45.tar.gz
            tar -xzf pcre-8.45.tar.gz
        fi
        PCRE_DIR="pcre-8.45"
        PCRE_FLAGS="--with-pcre-jit"
    fi

    # Compiler hardening flags
    NGINX_CFLAGS="-O2 -g -pipe -Wall -fexceptions -fstack-protector --param=ssp-buffer-size=4"

    # Static-only flags (used only for standard nginx)
    NGINX_STATIC_CFLAGS="-static -static-libgcc -m64 -mtune=generic -fPIC"

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
    if [[ ! -d "nginx-http-flv-module-1.2.12" ]]; then
        log "Downloading HTTP-FLV module..."
        if ! wget -q https://github.com/winshining/nginx-http-flv-module/archive/refs/tags/v1.2.12.zip; then
            error "Error downloading HTTP-FLV module"
        fi
        if ! unzip -q v1.2.12.zip; then
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
    if [[ ! -d "nginx-http-flv-module-1.2.12" ]]; then
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

    # Download NGINX
    if [[ ! -d "nginx-1.28.0" ]]; then
        log "Downloading NGINX 1.28.0..."
        wget -q https://nginx.org/download/nginx-1.28.0.tar.gz
        tar -xzf nginx-1.28.0.tar.gz
    fi

    cd nginx-1.28.0

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
        --with-ld-opt='-static -Wl,-z,relro -Wl,-z,now -pie' \
        --with-pcre="../$PCRE_DIR" \
        $PCRE_FLAGS \
        --with-zlib=../zlib-1.3.1 \
        --with-openssl=../openssl-3.5.1 \
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

    cd "$BUILD_DIR/nginx-1.28.0"

    # Clean previous configuration
    make clean || true

    log "Configuring NGINX with RTMP..."
    ./configure \
        --prefix="$XC_VM_DIR/bin/nginx_rtmp" \
        --add-module=../nginx-http-flv-module-1.2.12 \
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
        --with-zlib=../zlib-1.3.1 \
        --with-openssl=../openssl-3.5.1 \
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
}

# Function to compile PHP-FPM
build_php() {
    log "Compiling PHP-FPM 8.1.33..."

    cd "$BUILD_DIR"

    # Download PHP
    if [[ ! -d "php-8.1.33" ]]; then
        log "Downloading PHP 8.1.33..."
        wget -q -O php-8.1.33.tar.gz https://www.php.net/distributions/php-8.1.33.tar.gz
        tar -xzf php-8.1.33.tar.gz
    fi

    cd php-8.1.33

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
        --disable-mbregex \
        --with-pear

    # Compile and install
    log "Compiling PHP..."
    make -j$(nproc)
    make install

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

    # Install extensions using pecl if available
    if [[ -f "$XC_VM_DIR/bin/php/bin/pecl" ]]; then
        log "Installing extensions with PECL..."

        # Install maxminddb
        echo "yes" | "$XC_VM_DIR/bin/php/bin/pecl" install maxminddb || warn "Error installing maxminddb"

        # Install ssh2 (requires libssh2)
        apt-get install -y libssh2-1-dev
        echo "yes" | "$XC_VM_DIR/bin/php/bin/pecl" install ssh2 || warn "Error installing ssh2"

        # Install igbinary
        echo "yes" | "$XC_VM_DIR/bin/php/bin/pecl" install igbinary || warn "Error installing igbinary"

        # Install redis
        echo "yes" | "$XC_VM_DIR/bin/php/bin/pecl" install redis || warn "Error installing redis"

        # Add extensions to php.ini
        echo "extension=maxminddb.so" >> "$XC_VM_DIR/bin/php/lib/php.ini"
        echo "extension=ssh2.so" >> "$XC_VM_DIR/bin/php/lib/php.ini"
        echo "extension=igbinary.so" >> "$XC_VM_DIR/bin/php/lib/php.ini"
        echo "extension=redis.so" >> "$XC_VM_DIR/bin/php/lib/php.ini"
    else
        warn "PECL not found. Skipping extension installation."
    fi

    log "PHP extensions installed"
}

# Function to create network.py if it does not exist
create_network_py() {
    log "Downloading network.py from GitHub..."

    # Download network.py
    curl -fsSL "https://raw.githubusercontent.com/Vateron-Media/XC_VM/refs/heads/main/src/bin/network.py" -o "$XC_VM_DIR/bin/network.py"

    if [ $? -eq 0 ]; then
        log "network.py successfully downloaded to $XC_VM_DIR/bin/network.py"
    else
        log "Failed to download network.py"
        return 1
    fi
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

# Function to clean up temporary files
cleanup() {
    log "Cleaning up temporary files..."

    # Only clean compilation files, not the final binaries
    cd "$BUILD_DIR"

    # Remove downloaded files but keep the sources
    rm -f *.tar.gz *.zip 2>/dev/null || true

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
    log "Starting XC_VM compilation for Debian 12"

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

    # Extensions and additional binary
    install_php_extensions
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