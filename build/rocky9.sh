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
VERSIONS_FILE="/build/versions.json"

# Version variables (loaded from versions.json in load_versions)
V_NGINX=""
V_OPENSSL=""
V_ZLIB=""
V_PCRE=""
V_PHP=""
V_FLV_MODULE=""
V_RTMP=""

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
    V_RTMP=$(_json_ver nginx_rtmp_module "$vfile")

    for var in V_NGINX V_OPENSSL V_ZLIB V_PCRE V_PHP V_FLV_MODULE V_RTMP; do
        if [[ -z "${!var}" ]]; then
            error "Failed to parse $var from versions.json"
        fi
    done

    log "Loaded versions: nginx=$V_NGINX openssl=$V_OPENSSL zlib=$V_ZLIB pcre=$V_PCRE php=$V_PHP flv=$V_FLV_MODULE rtmp=$V_RTMP"
}

# Logging
log()   { echo -e "${GREEN}[$(date '+%F %T')] $1${NC}"; echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; echo "[ERROR] $1" >> "$LOG_FILE"; exit 1; }
warn()  { echo -e "${YELLOW}[WARN] $1${NC}"; echo "[WARN] $1" >> "$LOG_FILE"; }
info()  { echo -e "${BLUE}[INFO] $1${NC}"; echo "[INFO] $1" >> "$LOG_FILE"; }

# fetch_cached <filename> <url> [mirror...] — prefer the host-mounted cache
# (build_all.sh pre-downloads into ./downloads, mounted read-only at /build/downloads).
# Falls back to the network, trying each URL in turn. Writes to "$filename" in cwd.
fetch_cached() {
    local filename="$1"; shift
    local cache="/build/downloads/$filename"
    if [[ -f "$cache" && $(stat -c%s "$cache" 2>/dev/null || echo 0) -ge 1024 ]]; then
        cp -f "$cache" "$filename"
        log "✓ ${filename}: from /build/downloads (cached)"
        return 0
    fi
    local url
    for url in "$@"; do
        if wget -q --timeout=30 --connect-timeout=15 --tries=2 -O "$filename" "$url" &&
            [[ $(stat -c%s "$filename" 2>/dev/null || echo 0) -ge 1024 ]]; then
            return 0
        fi
        rm -f "$filename"
    done
    return 1
}

# Print the download URLs for a versions.json key (one per line), substituting
# {VERSION} and {ARCH}. All links live in versions.json so they can be edited
# there without touching this script.
#   $1 = json key, $2 = version (optional), $3 = arch (optional)
_json_urls() {
    sed -n "/\"$1\"[[:space:]]*:[[:space:]]*{/,/]/p" "$VERSIONS_FILE" |
        grep -oE 'https?://[^"]+' |
        sed -e "s/{VERSION}/${2:-}/g" -e "s/{ARCH}/${3:-}/g"
}

# fetch_json <key> <filename> [version] [arch] — resolve the mirror list from
# versions.json and fetch (cache-aware via fetch_cached).
fetch_json() {
    local key="$1" filename="$2" version="${3:-}" arch="${4:-}"
    local urls=()
    mapfile -t urls < <(_json_urls "$key" "$version" "$arch")
    if [[ ${#urls[@]} -eq 0 ]]; then
        return 1
    fi
    fetch_cached "$filename" "${urls[@]}"
}

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
        perl-core glibc-static libstdc++-static zlib-static pcre-static oniguruma-devel \
        libsodium libsodium-devel

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
        fetch_json openssl "openssl-${V_OPENSSL}.tar.gz" "$V_OPENSSL" \
            || error "Failed to download OpenSSL ${V_OPENSSL}"
        tar -xzf openssl-${V_OPENSSL}.tar.gz
    fi

    if [[ ! -d "zlib-${V_ZLIB}" ]]; then
        log "Descargando Zlib ${V_ZLIB}..."
        fetch_json zlib "zlib-${V_ZLIB}.tar.gz" "$V_ZLIB" \
            || error "Failed to download Zlib ${V_ZLIB}"
        tar -xzf zlib-${V_ZLIB}.tar.gz
    fi

    if [[ ! -d "pcre-${V_PCRE}" ]]; then
        log "Descargando PCRE ${V_PCRE}..."
        fetch_json pcre "pcre-${V_PCRE}.tar.gz" "$V_PCRE" \
            || error "Failed to download PCRE ${V_PCRE} from all sources"
        tar -xzf pcre-${V_PCRE}.tar.gz
    fi
    log "Dependencias NGINX descargadas"
}

# Descargar módulos NGINX
download_nginx_modules() {
    log "Descargando módulos NGINX..."
    cd "$BUILD_DIR"

    if [[ ! -d "nginx-http-flv-module-${V_FLV_MODULE}" ]]; then
        fetch_json nginx_http_flv_module "nginx-http-flv-module-${V_FLV_MODULE}.zip" "$V_FLV_MODULE" \
            || error "Error downloading HTTP-FLV module"
        unzip -q nginx-http-flv-module-${V_FLV_MODULE}.zip
    fi

    if [[ ! -d "nginx-rtmp-module-${V_RTMP}" ]]; then
        fetch_json nginx_rtmp_module "nginx-rtmp-module-${V_RTMP}.tar.gz" "$V_RTMP" \
            || error "Error downloading RTMP module"
        tar -xzf nginx-rtmp-module-${V_RTMP}.tar.gz
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
        fetch_json nginx "nginx-${V_NGINX}.tar.gz" "$V_NGINX" \
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
        fetch_json php "php-${V_PHP}.tar.gz" "$V_PHP" \
            || error "Error downloading PHP"
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
        --with-sodium \
        --with-pear

    make -j$(nproc)
    make install
    cp php.ini-development "$XC_VM_DIR/bin/php/lib/php.ini"
    cp sapi/fpm/php-fpm.conf "$XC_VM_DIR/bin/php/etc/php-fpm.conf.default"
    cp sapi/fpm/www.conf "$XC_VM_DIR/bin/php/etc/php-fpm.d/www.conf.default"
    log "PHP-FPM listo"
}

# Install the ionCube Loader. Required at runtime for ioncube_v1 modules
# (IonCube-encoded PHP). The loader is a Zend extension and MUST load BEFORE
# xcvm_core.so — registered here right after build_php so it is the first
# (zend_)extension line in php.ini.
install_ioncube_loader() {
    log "Installing ionCube Loader..."
    cd "$BUILD_DIR"

    # PHP major.minor (e.g. 8.1 from 8.1.34) selects the matching loader .so.
    local php_mm="${V_PHP%.*}"

    local arch arch_tag loader_pkg
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  arch_tag="x86-64" ;;
        aarch64|arm64) arch_tag="aarch64" ;;
        *) warn "ionCube: unsupported architecture '$arch' — skipping loader"; return 0 ;;
    esac
    loader_pkg="ioncube_loaders_lin_${arch_tag}.tar.gz"

    if ! fetch_json ioncube "$loader_pkg" "" "$arch_tag"; then
        warn "ionCube: download failed — skipping loader"; return 0
    fi

    rm -rf ioncube
    tar -xzf "$loader_pkg" || { warn "ionCube: extract failed — skipping loader"; return 0; }

    # PHP-FPM here is non-thread-safe, so use the non-_ts loader for this PHP.
    local loader_so="ioncube/ioncube_loader_lin_${php_mm}.so"
    if [[ ! -f "$loader_so" ]]; then
        warn "ionCube: no loader for PHP ${php_mm} in bundle ($loader_so) — skipping"; return 0
    fi

    local ext_dir
    ext_dir="$("$XC_VM_DIR/bin/php/bin/php-config" --extension-dir)"
    mkdir -p "$ext_dir"
    cp "$loader_so" "$ext_dir/ioncube_loader_lin_${php_mm}.so"
    chmod 0755 "$ext_dir/ioncube_loader_lin_${php_mm}.so"

    echo "zend_extension=$ext_dir/ioncube_loader_lin_${php_mm}.so" >> "$XC_VM_DIR/bin/php/lib/php.ini"

    if "$XC_VM_DIR/bin/php/bin/php" -v 2>/dev/null | grep -qi 'ionCube'; then
        log "✓ ionCube Loader ${php_mm} installed and active ($ext_dir)"
    else
        warn "ionCube Loader installed but not detected by 'php -v' — check php.ini ordering"
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

# Build the private PHP extension (sources mounted at /build/ext_src)
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
    install_ioncube_loader
    build_php_extension
    build_network_binary

    # Free temp build directory
    rm -rf "$BUILD_DIR" 2>/dev/null || true

    log "✅ Compilación finalizada en $XC_VM_DIR/bin"
}

# Flags
case "$1" in
    -h|--help) echo "Uso: sudo $0 [-h|--help]"; exit 0 ;;
    -c|--clean) rm -rf "$BUILD_DIR" "$XC_VM_DIR/bin"; exit 0 ;;
    *) main ;;
esac