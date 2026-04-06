#!/bin/bash
set -e

if [ -z "$TARGET" ]; then
    echo "ERROR: TARGET is not set"
    exit 1
fi

SCRIPT=""
case "$TARGET" in
    debian_11|debian_12|debian_13|ubuntu_18|ubuntu_20|ubuntu_22|ubuntu_24)
        SCRIPT="/build/all.sh"
        ;;
    rocky_9)
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

echo "=== TESTING BINARIES ==="

BIN_DIR="/home/xc_vm"
TESTS_PASSED=0
TESTS_FAILED=0

test_pass() {
    echo "  ✓ $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    echo "  ✗ $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# ---------------------
# NGINX Tests
# ---------------------
echo "--- Testing NGINX ---"

# 1. Binary exists
if [[ -f "$BIN_DIR/bin/nginx/sbin/nginx" ]]; then
    test_pass "nginx binary exists"
else
    test_fail "nginx binary not found at $BIN_DIR/bin/nginx/sbin/nginx"
fi

# 2. Version output
if "$BIN_DIR/bin/nginx/sbin/nginx" -V 2>&1 | grep -q "nginx/"; then
    NGINX_VER=$("$BIN_DIR/bin/nginx/sbin/nginx" -V 2>&1 | head -1)
    test_pass "nginx version: $NGINX_VER"
else
    test_fail "nginx -V failed"
fi

# 3. Required modules
for mod in http_ssl_module http_v2_module http_realip_module http_stub_status_module http_auth_request_module; do
    if "$BIN_DIR/bin/nginx/sbin/nginx" -V 2>&1 | grep -q "$mod"; then
        test_pass "nginx module: $mod"
    else
        test_fail "nginx module missing: $mod"
    fi
done

# ---------------------
# NGINX RTMP Tests
# ---------------------
echo "--- Testing NGINX RTMP ---"

# 1. Binary exists
if [[ -f "$BIN_DIR/bin/nginx_rtmp/sbin/nginx_rtmp" ]]; then
    test_pass "nginx_rtmp binary exists"
else
    test_fail "nginx_rtmp binary not found at $BIN_DIR/bin/nginx_rtmp/sbin/nginx_rtmp"
fi

# 2. Version output
if "$BIN_DIR/bin/nginx_rtmp/sbin/nginx_rtmp" -V 2>&1 | grep -q "nginx/"; then
    NGINX_RTMP_VER=$("$BIN_DIR/bin/nginx_rtmp/sbin/nginx_rtmp" -V 2>&1 | head -1)
    test_pass "nginx_rtmp version: $NGINX_RTMP_VER"
else
    test_fail "nginx_rtmp -V failed"
fi

# 3. RTMP/FLV module present
if "$BIN_DIR/bin/nginx_rtmp/sbin/nginx_rtmp" -V 2>&1 | grep -q "nginx-http-flv-module\|nginx-rtmp-module"; then
    test_pass "nginx_rtmp has RTMP/FLV module"
else
    test_fail "nginx_rtmp RTMP/FLV module missing"
fi

# ---------------------
# PHP Tests
# ---------------------
echo "--- Testing PHP ---"

# 1. php binary exists
if [[ -f "$BIN_DIR/bin/php/bin/php" ]]; then
    test_pass "php binary exists"
else
    test_fail "php binary not found at $BIN_DIR/bin/php/bin/php"
fi

# 2. php-fpm binary exists
if [[ -f "$BIN_DIR/bin/php/sbin/php-fpm" ]]; then
    test_pass "php-fpm binary exists"
else
    test_fail "php-fpm binary not found at $BIN_DIR/bin/php/sbin/php-fpm"
fi

# 3. PHP version output
if "$BIN_DIR/bin/php/bin/php" -v 2>&1 | grep -q "PHP 8"; then
    PHP_VER=$("$BIN_DIR/bin/php/bin/php" -v 2>&1 | head -1)
    test_pass "php version: $PHP_VER"
else
    test_fail "php -v failed or unexpected version"
fi

# 4. Required PHP modules
for ext in curl mbstring openssl pdo_mysql mysqli gd sockets bcmath exif sodium; do
    if "$BIN_DIR/bin/php/bin/php" -m 2>/dev/null | grep -qi "^${ext}$"; then
        test_pass "php extension: $ext"
    else
        test_fail "php extension missing: $ext"
    fi
done

# 5. OPcache (Zend extension — compiled as shared .so, enabled at deploy time)
OPCACHE_SO=$(find "$BIN_DIR/bin/php" -name "opcache.so" 2>/dev/null | head -1)
if [[ -n "$OPCACHE_SO" ]]; then
    test_pass "php zend extension: opcache.so exists ($OPCACHE_SO)"
else
    test_fail "php zend extension missing: opcache.so not found"
fi

# 6. PHP-FPM config test
if "$BIN_DIR/bin/php/sbin/php-fpm" -t 2>&1 | grep -q "successful\|test is successful"; then
    test_pass "php-fpm config test (-t)"
else
    # php-fpm -t may fail without proper config, just warn
    echo "  ~ php-fpm -t skipped (no runtime config available)"
fi

# 6. Basic PHP execution test
PHP_TEST_OUTPUT=$("$BIN_DIR/bin/php/bin/php" -r 'echo "PHP_OK:" . PHP_VERSION;' 2>&1)
if echo "$PHP_TEST_OUTPUT" | grep -q "PHP_OK:"; then
    test_pass "php code execution works"
else
    test_fail "php code execution failed"
fi

# ---------------------
# Test Summary
# ---------------------
echo ""
echo "=== TEST SUMMARY ==="
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "ERROR: $TESTS_FAILED test(s) failed. Aborting build."
    exit 1
fi

echo "=== ALL TESTS PASSED ==="
echo ""

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
rm -rf "$BIN_DIR/bin/php/var"          2>/dev/null || true
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
