#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/out"
DOCKER_DIR="$ROOT_DIR/docker"

mkdir -p "$OUT_DIR"

# ----------------------
# Build function
# ----------------------
build() {
    local name=$1
    local base=$2
    local target=$3
    local dockerfile=$4

    echo ">>> IMAGE: $name"

    docker build \
        --build-arg BASE_IMAGE="$base" \
        -t "xcvm-builder:$name" \
        -f "$dockerfile" \
        "$ROOT_DIR"

    echo ">>> BUILD: $target"

    docker run --rm \
        -e TARGET="$target" \
        -v "$OUT_DIR:/build/out" \
        "xcvm-builder:$name"
}

# ----------------------
# Build groups
# ----------------------
build_debian() {
    build debian11 debian:11 debian_11 "$DOCKER_DIR/debian/Dockerfile"
    build debian12 debian:12 debian_12 "$DOCKER_DIR/debian/Dockerfile"
    build debian13 debian:13 debian_13 "$DOCKER_DIR/debian/Dockerfile"
}

build_ubuntu() {
    build ubuntu20 ubuntu:20.04 ubuntu20 "$DOCKER_DIR/debian/Dockerfile"
    build ubuntu24 ubuntu:24.04 ubuntu24 "$DOCKER_DIR/debian/Dockerfile"
}

build_rocky() {
    echo ">>> IMAGE: rocky9"

    docker build \
        -t xcvm-builder:rocky9 \
        -f "$DOCKER_DIR/rocky/Dockerfile" \
        "$ROOT_DIR"

    docker run --rm \
        -e TARGET=rocky9 \
        -v "$OUT_DIR:/build/out" \
        xcvm-builder:rocky9
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
    ubuntu20)
        build ubuntu20 ubuntu:20.04 ubuntu20 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    ubuntu24)
        build ubuntu24 ubuntu:24.04 ubuntu24 "$DOCKER_DIR/debian/Dockerfile"
        ;;
    rocky|rocky9)
        build_rocky
        ;;
    -h|--help)
        echo "Usage:"
        echo "  ./build.sh            Build all"
        echo "  ./build.sh all        Build all"
        echo "  ./build.sh debian     Build all Debian"
        echo "  ./build.sh debian13   Build Debian 13"
        echo "  ./build.sh ubuntu     Build all Ubuntu"
        echo "  ./build.sh ubuntu24   Build Ubuntu 24"
        echo "  ./build.sh rocky      Build Rocky 9"
        exit 0
        ;;
    *)
        echo "Unknown target: $1"
        echo "Run ./build.sh --help"
        exit 1
        ;;
esac

echo "=== XC_VM BUILD COMPLETED ==="
