#!/bin/bash
set -e

if [ -z "$TARGET" ]; then
    echo "ERROR: TARGET is not set"
    exit 1
fi

SCRIPT=""
case "$TARGET" in
    debian_11|debian_12|debian_13|ubuntu20|ubuntu24)
        SCRIPT="/build/all.sh"
        ;;
    rocky9)
        SCRIPT="/build/rocky9.sh"
        ;;
    *)
        echo "ERROR: Unknown TARGET: $TARGET"
        exit 1
        ;;
esac

if [ ! -f "$SCRIPT" ]; then
    echo "ERROR: Build script not found: $SCRIPT"
    exit 1
fi

echo "=== BUILD START: $TARGET ==="
bash "$SCRIPT" "$@"

echo "=== PACKAGING BINARIES ==="

OUT_DIR="/build/out"
BIN_DIR="/home/xc_vm"
ARCHIVE_NAME="${TARGET}.tar.gz"

mkdir -p "$OUT_DIR"

if [ ! -d "$BIN_DIR" ] || [ -z "$(ls -A "$BIN_DIR" 2>/dev/null)" ]; then
    echo "ERROR: $BIN_DIR is empty or does not exist"
    exit 1
fi

# --- Set permissions ---
echo "Setting permissions..."

# nginx
find "$BIN_DIR/bin/nginx" -type d -exec chmod 750 {} \; 2>/dev/null || true
find "$BIN_DIR/bin/nginx" -type f -exec chmod 550 {} \; 2>/dev/null || true
chmod 0755 "$BIN_DIR/bin/nginx/conf" 2>/dev/null || true
chmod 0755 "$BIN_DIR/bin/nginx/conf/server.crt" 2>/dev/null || true
chmod 0755 "$BIN_DIR/bin/nginx/conf/server.key" 2>/dev/null || true
chmod 0755 "$BIN_DIR/bin/nginx_rtmp/conf" 2>/dev/null || true

# php
find "$BIN_DIR/bin/php" -type f -exec chmod 550 {} \; 2>/dev/null || true
chmod 0750 "$BIN_DIR/bin/php/etc" 2>/dev/null || true
chmod 0644 "$BIN_DIR/bin/php/etc/"*.conf 2>/dev/null || true
chmod 0750 "$BIN_DIR/bin/php/sessions" 2>/dev/null || true
chmod 0750 "$BIN_DIR/bin/php/sockets" 2>/dev/null || true
find "$BIN_DIR/bin/php/var" -type d -exec chmod 750 {} \; 2>/dev/null || true
chmod 0551 "$BIN_DIR/bin/php/bin/php" 2>/dev/null || true
chmod 0551 "$BIN_DIR/bin/php/sbin/php-fpm" 2>/dev/null || true
chmod 0755 "$BIN_DIR/bin/php/lib/php/extensions/no-debug-non-zts-20210902" 2>/dev/null || true

# --- Remove unneeded files ---
echo "Cleaning up unneeded files..."

rm -rf "$BIN_DIR/bin/nginx/conf"       2>/dev/null || true
rm -rf "$BIN_DIR/bin/nginx/html"       2>/dev/null || true
rm -rf "$BIN_DIR/bin/nginx/logs"       2>/dev/null || true

rm -rf "$BIN_DIR/bin/nginx_rtmp/conf"  2>/dev/null || true
rm -rf "$BIN_DIR/bin/nginx_rtmp/html"  2>/dev/null || true
rm -rf "$BIN_DIR/bin/nginx_rtmp/logs"  2>/dev/null || true

rm -rf "$BIN_DIR/bin/php/etc"          2>/dev/null || true
rm -rf "$BIN_DIR/bin/php/lib/php.ini"  2>/dev/null || true
rm -rf "$BIN_DIR/bin/php/lib/php/doc"  2>/dev/null || true
rm -rf "$BIN_DIR/bin/php/lib/php/test" 2>/dev/null || true

rm -f  "$BIN_DIR/bin/network.py"       2>/dev/null || true

# --- Remove old archive if exists ---
if [[ -f "$OUT_DIR/$ARCHIVE_NAME" ]]; then
    echo "Old archive found, removing..."
    rm -f "$OUT_DIR/$ARCHIVE_NAME"
fi

# --- Create archive ---
echo "Creating archive $ARCHIVE_NAME..."
tar -C "$BIN_DIR" -czf "$OUT_DIR/$ARCHIVE_NAME" .
echo "✓ Archive created at $OUT_DIR/$ARCHIVE_NAME"

echo "=== BUILD DONE: $TARGET ==="
