#!/bin/bash
# Script de compilación para XC_VM en Rocky Linux 9 / AlmaLinux 9 / RHEL 9
# Autor: melcocha14@gmail.com  – adaptado Rocky 9
# Versión: 1.9-r9
# Fecha: 2025-12-22

set -e

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Variables
XC_VM_DIR="/home/xc_vm"
BUILD_DIR="/tmp/xc_vm_build"
LOG_FILE="/tmp/xc_vm_build.log"

# Version variables (loaded from versions.json in load_versions)
V_NGINX=""
V_OPENSSL=""
V_ZLIB=""
V_PCRE=""
V_PHP=""
V_FLV_MODULE=""

# Load versions from versions.json
load_versions() {
    local vfile="/build/versions.json"
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
    V_PHP=$(_json_ver php "$vfile")
    V_FLV_MODULE=$(_json_ver nginx_http_flv_module "$vfile")

    for var in V_NGINX V_OPENSSL V_ZLIB V_PCRE V_PHP V_FLV_MODULE; do
        if [[ -z "${!var}" ]]; then
            error "Failed to parse $var from versions.json"
        fi
    done

    log "Loaded versions: nginx=$V_NGINX openssl=$V_OPENSSL zlib=$V_ZLIB pcre=$V_PCRE php=$V_PHP flv=$V_FLV_MODULE"
}

# Logging
log()   { echo -e "${GREEN}[$(date '+%F %T')] $1${NC}"; echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; echo "[ERROR] $1" >> "$LOG_FILE"; exit 1; }
warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; echo "[WARN] $1" >> "$LOG_FILE"; }
info()  { echo -e "${BLUE}[INFO] $1${NC}"; echo "[INFO] $1" >> "$LOG_FILE"; }

# Verificar root
check_root() {
    [[ $EUID -eq 0 ]] || error "Ejecuta este script como root: sudo $0"
    log "Ejecutándose como root - ✓"
}

# Verificar sistema compatible
check_system() {
    . /etc/os-release
    case "$ID" in
        rocky|almalinux|rhel) [[ "${VERSION_ID%%.*}" -ge 9 ]] || error "Se requiere Rocky/Alma/RHEL 9+" ;;
        *) error "Sistema no soportado" ;;
    esac
    log "Sistema compatible: $ID $VERSION_ID"
}

# Instalar dependencias Rocky 9
install_dependencies() {
    log "Instalando dependencias del sistema..."
    dnf install -y epel-release
    dnf config-manager --set-enabled crb      # PowerTools en clones
    dnf groupinstall -y "Development Tools"
    dnf install -y --allowerasing \
        pcre-devel zlib-devel openssl-devel gd-devel libxml2-devel \
        libuuid-devel libxslt-devel unzip wget curl git python3 python3-pip \
        libcurl-devel bzip2-devel libzip-devel autoconf automake libtool \
        m4 gcc gcc-c++ make pkgconfig libmaxminddb-devel libssh2-devel \
        libjpeg-turbo-devel freetype-devel python3-virtualenv perl-FindBin perl-devel \
        perl-core glibc-static libstdc++-static zlib-static pcre-static oniguruma-devel

    # pyinstaller vía pipx
    if ! command -v pipx &>/dev/null; then
        python3 -m pip install --user pipx
        python3 -m pipx ensurepath
    fi
    export PATH="$HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc

    if ! command -v pyinstaller &>/dev/null; then
        pipx install pyinstaller || {
            python3 -m venv /tmp/pyinstaller_env
            /tmp/pyinstaller_env/bin/pip install pyinstaller
            ln -sf /tmp/pyinstaller_env/bin/pyinstaller /usr/local/bin/pyinstaller
        }
    fi
    log "Dependencias instaladas"
}

# Crear directorios
setup_directories() {
    log "Configurando directorios..."
    mkdir -p "$XC_VM_DIR/bin"
    [[ -n "$SUDO_USER" ]] && chown -R "$SUDO_USER:$SUDO_USER" "$XC_VM_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    log "Directorios configurados"
}

# Descargar dependencias NGINX
download_nginx_deps() {
    log "Descargando dependencias NGINX..."
    cd "$BUILD_DIR"

    if [[ ! -d "openssl-${V_OPENSSL}" ]]; then
        log "Descargando OpenSSL ${V_OPENSSL}..."
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            https://github.com/openssl/openssl/releases/download/openssl-${V_OPENSSL}/openssl-${V_OPENSSL}.tar.gz
        tar -xzf openssl-${V_OPENSSL}.tar.gz
    fi

    if [[ ! -d "zlib-${V_ZLIB}" ]]; then
        log "Descargando Zlib ${V_ZLIB}..."
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            https://zlib.net/zlib-${V_ZLIB}.tar.gz
        tar -xzf zlib-${V_ZLIB}.tar.gz
    fi

    if [[ ! -d "pcre-${V_PCRE}" ]]; then
        log "Descargando PCRE ${V_PCRE}..."
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            https://sourceforge.net/projects/pcre/files/pcre/${V_PCRE}/pcre-${V_PCRE}.tar.gz
        tar -xzf pcre-${V_PCRE}.tar.gz
    fi
    log "Dependencias NGINX descargadas"
}

# Descargar módulos NGINX
download_nginx_modules() {
    log "Descargando módulos NGINX..."
    cd "$BUILD_DIR"

    if [[ ! -d "nginx-http-flv-module-${V_FLV_MODULE}" ]]; then
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            https://github.com/winshining/nginx-http-flv-module/archive/refs/tags/v${V_FLV_MODULE}.zip -O v${V_FLV_MODULE}.zip
        unzip -q v${V_FLV_MODULE}.zip
    fi

    if [[ ! -d "nginx-rtmp-module-1.2.2" ]]; then
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            https://github.com/arut/nginx-rtmp-module/archive/refs/tags/v1.2.2.tar.gz -O nginx-rtmp-module-1.2.2.tar.gz
        tar -xzf nginx-rtmp-module-1.2.2.tar.gz
    fi
    log "Módulos NGINX descargados"
}

# Compilar OpenSSL estático
build_openssl() {
    log "Compilando OpenSSL ${V_OPENSSL} estático..."
    cd "$BUILD_DIR/openssl-${V_OPENSSL}"
    ./Configure linux-x86_64 no-shared no-tests -fPIC --prefix="$BUILD_DIR/openssl-${V_OPENSSL}/.openssl"
    make -j$(nproc)
    make install_sw
    log "OpenSSL ${V_OPENSSL} listo"
}

# NGINX estándar
build_nginx() {
    log "Compilando NGINX estándar..."
    cd "$BUILD_DIR"

    [[ -d nginx-${V_NGINX} ]] || {
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            https://nginx.org/download/nginx-${V_NGINX}.tar.gz \
            || wget -q --timeout=30 --connect-timeout=15 --tries=3 \
                https://github.com/nginx/nginx/releases/download/release-${V_NGINX}/nginx-${V_NGINX}.tar.gz \
            || error "Error downloading NGINX"
        tar -xzf nginx-${V_NGINX}.tar.gz
    }
    cd nginx-${V_NGINX}

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
        --with-cc-opt='-static -static-libgcc -O2 -g -pipe -Wall -U_FORTIFY_SOURCE -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic -fPIC' \
        --with-ld-opt='-static -Wl,-z,relro -Wl,-z,now -pie -lpthread -ldl' \
        --with-pcre=../pcre-${V_PCRE} \
        --with-pcre-jit \
        --with-zlib=../zlib-${V_ZLIB} \
        --with-openssl=../openssl-${V_OPENSSL} \
        --with-openssl-opt="no-shared no-tests -fPIC"

    make -j$(nproc)
    make install
    log "NGINX estándar listo"
}

# NGINX + RTMP
build_nginx_rtmp() {
    log "Compilando NGINX con RTMP..."
    cd "$BUILD_DIR/nginx-${V_NGINX}"
    make clean || true

    ./configure \
        --prefix="$XC_VM_DIR/bin/nginx_rtmp" \
        --add-module=../nginx-http-flv-module-${V_FLV_MODULE} \
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
        --with-cc-opt='-static -static-libgcc -O2 -g -pipe -Wall -U_FORTIFY_SOURCE -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic -fPIC' \
        --with-ld-opt='-static -Wl,-z,relro -Wl,-z,now' \
        --with-openssl=../openssl-${V_OPENSSL} \
        --with-openssl-opt="no-shared no-tests -fPIC"		

    make -j$(nproc)
    make install
    mv "$XC_VM_DIR/bin/nginx_rtmp/sbin/nginx" "$XC_VM_DIR/bin/nginx_rtmp/sbin/nginx_rtmp"
    log "NGINX-RTMP listo"
}

# PHP-FPM
build_php() {
    log "Compilando PHP-FPM ${V_PHP}..."
    cd "$BUILD_DIR"

    [[ -d php-${V_PHP} ]] || {
        wget -q --timeout=30 --connect-timeout=15 --tries=3 \
            -O php-${V_PHP}.tar.gz https://www.php.net/distributions/php-${V_PHP}.tar.gz
        tar -xzf php-${V_PHP}.tar.gz
    }
    cd php-${V_PHP}

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

    make -j$(nproc)
    make install
    cp php.ini-development "$XC_VM_DIR/bin/php/lib/php.ini"
    cp sapi/fpm/php-fpm.conf "$XC_VM_DIR/bin/php/etc/php-fpm.conf.default"
    cp sapi/fpm/www.conf "$XC_VM_DIR/bin/php/etc/php-fpm.d/www.conf.default"
    log "PHP-FPM listo"
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

# Main
main() {
    log "Iniciando compilación de XC_VM para Rocky Linux 9"
    load_versions
    check_root
    check_system
    install_dependencies
    setup_directories

    download_nginx_deps
    build_openssl
    download_nginx_modules

    build_nginx
    build_nginx_rtmp
    build_php
    build_network_binary

    log "✅ Compilación finalizada en $XC_VM_DIR/bin"
}

# Flags
case "$1" in
    -h|--help) echo "Uso: sudo $0 [-h|--help]"; exit 0 ;;
    -c|--clean) rm -rf "$BUILD_DIR" "$XC_VM_DIR/bin"; exit 0 ;;
    *) main ;;
esac