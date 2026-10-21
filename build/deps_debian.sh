#!/bin/bash
# Build dependencies for Debian 12/13 and Ubuntu 20.04/22.04/24.04.
# Run once by docker/debian/Dockerfile in its own image layer (keyed only on this
# file), so builds reuse the installed toolchain instead of re-running apt.
set -e

. /etc/os-release
VERSION_MAJOR="${VERSION_ID%%.*}"

apt-get update -y

# Base build dependencies (common to all distributions)
apt-get install -y \
    build-essential zlib1g zlib1g-dev libssl-dev \
    libgd-dev libxml2 libxml2-dev uuid-dev libxslt1-dev \
    unzip wget curl git lsb-release \
    python3 python3-pip python3-venv \
    libcurl4-gnutls-dev libbz2-dev libzip-dev autoconf automake \
    libtool m4 gcc make pkg-config libmaxminddb-dev \
    libjpeg-dev libfreetype6-dev libsodium-dev libonig-dev \
    ccache

# Debian's ccache ships gcc/g++ masquerade links but no cc; nginx and PHP build with cc.
ln -sf /usr/bin/ccache /usr/lib/ccache/cc

# PCRE selection: Debian 12+ / Ubuntu 22+ -> PCRE2, otherwise PCRE1
if [[ "$ID" == "debian" && "$VERSION_MAJOR" -ge 12 ]] || [[ "$ID" == "ubuntu" && "$VERSION_MAJOR" -ge 22 ]]; then
    echo "Installing PCRE2 (Debian 12+ / Ubuntu 22+)"
    apt-get install -y libpcre2-8-0 libpcre2-dev
else
    echo "Installing PCRE1 (Ubuntu 20)"
    apt-get install -y libpcre3 libpcre3-dev
fi

# pipx available only on Debian 12+ and Ubuntu 22+
USE_PIPX=false
if [[ "$ID" == "debian" && "$VERSION_MAJOR" -ge 12 ]] || [[ "$ID" == "ubuntu" && "$VERSION_MAJOR" -ge 22 ]]; then
    USE_PIPX=true
fi

if $USE_PIPX; then
    # python3-full exists only on newer systems
    if apt-cache show python3-full &> /dev/null; then
        apt-get install -y pipx python3-full
    else
        apt-get install -y pipx
    fi
    # Installs into /root/.local/bin, which the Dockerfile puts on PATH.
    pipx install pyinstaller || USE_PIPX=false
fi

apt-get clean
rm -rf /var/lib/apt/lists/*

# Fallback for Ubuntu 20.04 or pipx failure
if ! $USE_PIPX; then
    echo "pipx unavailable, installing PyInstaller via venv"
    python3 -m venv /opt/pyinstaller_env
    /opt/pyinstaller_env/bin/pip install --upgrade pip
    /opt/pyinstaller_env/bin/pip install pyinstaller
    ln -sf /opt/pyinstaller_env/bin/pyinstaller /usr/local/bin/pyinstaller
fi

PATH="/root/.local/bin:$PATH" pyinstaller --version
