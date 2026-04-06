#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/out"
LOG_DIR="$ROOT_DIR/logs"
DOCKER_DIR="$ROOT_DIR/docker"

mkdir -p "$OUT_DIR" "$LOG_DIR"

# ----------------------
# Build function
# ----------------------
build() {
    local name=$1
    local base=$2
    local target=$3
    local dockerfile=$4
    local logfile="$LOG_DIR/${target}.log"

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
    build ubuntu18 ubuntu:18.04 ubuntu_18 "$DOCKER_DIR/debian/Dockerfile"
    build ubuntu20 ubuntu:20.04 ubuntu_20 "$DOCKER_DIR/debian/Dockerfile"
    build ubuntu22 ubuntu:22.04 ubuntu_22 "$DOCKER_DIR/debian/Dockerfile"
    build ubuntu24 ubuntu:24.04 ubuntu_24 "$DOCKER_DIR/debian/Dockerfile"
}

build_rocky() {
    local logfile="$LOG_DIR/rocky_9.log"

    echo ">>> IMAGE: rocky9 (log: $logfile)"

    docker build \
        -t xcvm-builder:rocky9 \
        -f "$DOCKER_DIR/rocky/Dockerfile" \
        "$ROOT_DIR" 2>&1 | tee "$logfile"

    echo ">>> BUILD: rocky_9"

    docker run --rm \
        -e TARGET=rocky_9 \
        -v "$OUT_DIR:/build/out" \
        xcvm-builder:rocky9 2>&1 | tee -a "$logfile"

    echo ">>> Log saved: $logfile"
}

# ----------------------
# CLI
# ----------------------
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
    ubuntu18)
        build ubuntu18 ubuntu:18.04 ubuntu_18 "$DOCKER_DIR/debian/Dockerfile"
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
        echo "  ./build.sh ubuntu18   Build Ubuntu 18.04 (TARGET=ubuntu_18)"
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

echo "=== XC_VM BUILD COMPLETED ==="
