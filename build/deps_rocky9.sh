#!/bin/bash
# Build dependencies for Rocky Linux 9. Run once by docker/rocky/Dockerfile in its
# own image layer (keyed only on this file), so builds reuse the installed
# toolchain instead of re-running dnf.
set -e

dnf install -y epel-release
dnf config-manager --set-enabled crb      # PowerTools en clones
dnf groupinstall -y "Development Tools"
dnf install -y --allowerasing \
    pcre-devel zlib-devel openssl-devel gd-devel libxml2-devel \
    libuuid-devel libxslt-devel unzip wget curl git python3 python3-pip \
    libcurl-devel bzip2-devel libzip-devel autoconf automake libtool \
    m4 gcc gcc-c++ make pkgconfig libmaxminddb-devel \
    libjpeg-turbo-devel freetype-devel python3-virtualenv perl-FindBin perl-devel \
    perl-core glibc-static libstdc++-static zlib-static pcre-static oniguruma-devel \
    libsodium libsodium-devel ccache
dnf clean all
# nginx and PHP build with cc: make sure ccache masquerades as it too.
ln -sf /usr/bin/ccache /usr/lib64/ccache/cc

# pyinstaller via pipx (into /root/.local/bin, which the Dockerfile puts on PATH)
python3 -m pip install --user pipx
export PATH="/root/.local/bin:$PATH"
pipx install pyinstaller || {
    python3 -m venv /opt/pyinstaller_env
    /opt/pyinstaller_env/bin/pip install pyinstaller
    ln -sf /opt/pyinstaller_env/bin/pyinstaller /usr/local/bin/pyinstaller
}
pyinstaller --version
