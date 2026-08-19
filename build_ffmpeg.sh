#!/bin/bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────────────────────
# XC_VM FFmpeg static builder
#
# Builds a *portable* FFmpeg 8.1 + ffprobe where every codec/library is compiled
# from source as a static .a and linked INTO the binary. The only dynamic
# dependencies left are the glibc family (libc/libm/libpthread/libdl/librt) plus
# libgcc_s — present on every Linux host. No libx264.so / libx265.so / etc. is
# ever looked up on the target system.
#
# Why this exists: the previous version installed distro -dev packages (which on
# Debian/Ubuntu ship only shared .so) and relied on --pkg-config-flags=--static.
# With no .a available the linker silently fell back to .so, producing a binary
# that needed libx264.so & friends at runtime — libraries absent on the deploy
# host. This rewrite removes that failure mode entirely and verifies the result.
#
# Intended to run as root inside a clean Debian 11 container (old glibc → forward
# compatible). See docker/ffmpeg/Dockerfile and `./build_all.sh ffmpeg`.
#
# Output: $OUT_DIR/ffmpeg, $OUT_DIR/ffprobe, $OUT_DIR/ffmpeg.tar.gz
# ──────────────────────────────────────────────────────────────────────────────

# ── Versions (single place to bump; kept here rather than versions.json because
#    none of these are tracked by check_versions.sh) ───────────────────────────
V_ZLIB="1.3.1"
V_BZIP2="1.0.8"
V_OPENSSL="3.4.1"
V_EXPAT="2.6.4"          # tag R_2_6_4
V_FREETYPE="2.13.3"
V_FRIBIDI="1.0.16"
V_HARFBUZZ="10.2.0"
V_FONTCONFIG="2.16.0"
V_LIBASS="0.17.3"
V_X265="4.1"
V_VPX="1.15.0"
V_AOM="3.11.0"           # git tag
V_DAV1D="1.5.1"
V_OPUS="1.5.2"
V_LAME="3.100"
V_FDKAAC="2.0.3"
V_OGG="1.3.5"
V_VORBIS="1.3.7"
V_THEORA="1.1.1"
V_FFMPEG="${V_FFMPEG:-8.1}"   # release tarball (== git tag nX.Y); override: V_FFMPEG=7.1
# Label for the output archive / release asset (the panel's ffmpeg_bin/<label> dir).
# Defaults to the built version; override when the panel dir name differs, e.g.
# FF_LABEL=8.0 while building FFmpeg 8.1.
FF_LABEL="${FF_LABEL:-$V_FFMPEG}"

# ── Paths ─────────────────────────────────────────────────────────────────────
DEPS_PREFIX="/opt/ffmpeg_deps"          # static libs land here
FF_PREFIX="/opt/ffmpeg_build"           # ffmpeg install prefix
SRC_DIR="/tmp/ffmpeg_src"               # extracted sources
DL_DIR="/tmp/ffmpeg_dl"                 # downloaded archives (cache)
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)/out}"
NPROC="$(nproc)"
JOBS="-j${NPROC}"

# ── Logging ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
msg()  { echo -e "${GREEN}[*]${NC} $*"; }
step() { echo -e "${CYAN}[==]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ── Build environment: make every tool prefer our static prefix ────────────────
export PATH="$DEPS_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/lib64/pkgconfig"
export CFLAGS="-I$DEPS_PREFIX/include -O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$DEPS_PREFIX/lib -L$DEPS_PREFIX/lib64"

mkdir -p "$DEPS_PREFIX" "$FF_PREFIX" "$SRC_DIR" "$DL_DIR" "$OUT_DIR"

# ── Helpers ────────────────────────────────────────────────────────────────────
# dl <dest> <url> [mirror...] — download with retries, skip if already cached.
dl() {
    local out="$1"; shift
    if [[ -f "$out" && "$(stat -c%s "$out" 2>/dev/null || echo 0)" -ge 1024 ]]; then
        return 0
    fi
    local u
    for u in "$@"; do
        msg "GET $(basename "$out") <- $u"
        if wget -q --timeout=30 --connect-timeout=15 --tries=2 -O "$out" "$u"; then
            return 0
        fi
        rm -f "$out"
    done
    die "download failed: $(basename "$out")"
}

# fetch <archive-name> <url> [mirror...] — download + extract into $SRC_DIR.
# Sets global SRC to the extracted top-level directory.
fetch() {
    local fname="$1"; shift
    local arch="$DL_DIR/$fname"
    dl "$arch" "$@"
    local top
    top="$(tar tf "$arch" 2>/dev/null | head -1 | cut -d/ -f1)"
    [[ -n "$top" ]] || die "cannot determine top dir of $fname"
    rm -rf "${SRC_DIR:?}/$top"
    tar xf "$arch" -C "$SRC_DIR"
    SRC="$SRC_DIR/$top"
}

# git_fetch <dir> <branch> <url> [mirror...] — shallow clone. Sets global SRC.
git_fetch() {
    local dir="$1" branch="$2"; shift 2
    SRC="$SRC_DIR/$dir"
    [[ -d "$SRC/.git" ]] && { msg "cached clone: $dir"; return 0; }
    rm -rf "$SRC"
    local u
    for u in "$@"; do
        msg "CLONE $dir ($branch) <- $u"
        if git clone --depth 1 --branch "$branch" "$u" "$SRC" 2>/dev/null; then
            return 0
        fi
        rm -rf "$SRC"
    done
    die "clone failed: $dir"
}

# done_stamp / is_done — let the script be re-run on a host without rebuilding
# everything. (In the one-shot container this is a no-op.)
is_done()   { [[ -f "$DEPS_PREFIX/.done-$1" ]]; }
done_stamp(){ touch "$DEPS_PREFIX/.done-$1"; }

# build <name> <body-fn> — wraps stamp handling + section banner.
build() {
    local name="$1" fn="$2"
    if is_done "$name"; then msg "skip $name (already built)"; return 0; fi
    step "Building $name"
    "$fn"
    done_stamp "$name"
}

# ── Build-tool installation (Debian) ───────────────────────────────────────────
install_build_tools() {
    step "Installing build tools (APT)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        build-essential yasm nasm cmake git pkg-config \
        autoconf automake libtool gperf texinfo \
        wget tar xz-utils unzip ca-certificates \
        python3 python3-pip ninja-build perl
    # Debian 11 ships meson 0.56; some recent libs want newer — use a fresh pip one.
    pip3 install --quiet --upgrade meson ninja
    hash -r
    msg "Tool versions: $(gcc -dumpversion) / nasm $(nasm -v | awk '{print $3}') / meson $(meson --version) / cmake $(cmake --version | head -1 | awk '{print $3}')"
}

# ── Generic build recipes ──────────────────────────────────────────────────────
autotools() { ./configure --prefix="$DEPS_PREFIX" --enable-static --disable-shared "$@" && make $JOBS && make install; }
cmake_static() {
    local src="$1"; shift
    mkdir -p build && cd build
    cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        "$@" "$src"
    make $JOBS && make install
}
meson_static() {
    meson setup build --prefix="$DEPS_PREFIX" --libdir=lib --buildtype=release \
        --default-library=static "$@"
    ninja -C build && ninja -C build install
}

# ── Dependency builds (order matters: deps before dependents) ──────────────────
b_zlib() {
    fetch "zlib-${V_ZLIB}.tar.gz" \
        "https://zlib.net/zlib-${V_ZLIB}.tar.gz" \
        "https://github.com/madler/zlib/releases/download/v${V_ZLIB}/zlib-${V_ZLIB}.tar.gz"
    cd "$SRC"; ./configure --prefix="$DEPS_PREFIX" --static; make $JOBS; make install
}

b_bzip2() {
    fetch "bzip2-${V_BZIP2}.tar.gz" \
        "https://sourceware.org/pub/bzip2/bzip2-${V_BZIP2}.tar.gz"
    cd "$SRC"
    make $JOBS libbz2.a CFLAGS="-fPIC -O2 -D_FILE_OFFSET_BITS=64"
    make install PREFIX="$DEPS_PREFIX"
}

b_openssl() {
    fetch "openssl-${V_OPENSSL}.tar.gz" \
        "https://github.com/openssl/openssl/releases/download/openssl-${V_OPENSSL}/openssl-${V_OPENSSL}.tar.gz"
    cd "$SRC"
    ./Configure no-shared no-tests --prefix="$DEPS_PREFIX" --libdir=lib \
        --openssldir="$DEPS_PREFIX/ssl" linux-x86_64
    make $JOBS; make install_sw
}

b_expat() {
    fetch "expat-${V_EXPAT}.tar.xz" \
        "https://github.com/libexpat/libexpat/releases/download/R_${V_EXPAT//./_}/expat-${V_EXPAT}.tar.xz"
    cd "$SRC"; autotools --without-docbook --without-examples --without-tests
}

b_freetype() {  # first pass: no harfbuzz (breaks the freetype<->harfbuzz cycle)
    fetch "freetype-${V_FREETYPE}.tar.xz" \
        "https://download.savannah.gnu.org/releases/freetype/freetype-${V_FREETYPE}.tar.xz" \
        "https://downloads.sourceforge.net/freetype/freetype-${V_FREETYPE}.tar.xz"
    cd "$SRC"; autotools --with-harfbuzz=no --with-brotli=no --with-png=no
}

b_fribidi() {
    fetch "fribidi-${V_FRIBIDI}.tar.xz" \
        "https://github.com/fribidi/fribidi/releases/download/v${V_FRIBIDI}/fribidi-${V_FRIBIDI}.tar.xz"
    cd "$SRC"; autotools --disable-debug
}

b_harfbuzz() {
    fetch "harfbuzz-${V_HARFBUZZ}.tar.xz" \
        "https://github.com/harfbuzz/harfbuzz/releases/download/${V_HARFBUZZ}/harfbuzz-${V_HARFBUZZ}.tar.xz"
    cd "$SRC"
    meson_static -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
        -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
}

b_fontconfig() {
    fetch "fontconfig-${V_FONTCONFIG}.tar.xz" \
        "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${V_FONTCONFIG}.tar.xz"
    cd "$SRC"; autotools --disable-docs --sysconfdir=/etc --localstatedir=/var
}

b_libass() {
    fetch "libass-${V_LIBASS}.tar.xz" \
        "https://github.com/libass/libass/releases/download/${V_LIBASS}/libass-${V_LIBASS}.tar.xz"
    cd "$SRC"; autotools
}

b_x264() {
    git_fetch "x264" "stable" \
        "https://code.videolan.org/videolan/x264.git" \
        "https://github.com/mirror/x264.git"
    cd "$SRC"
    ./configure --prefix="$DEPS_PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl
    make $JOBS; make install
}

b_x265() {
    fetch "x265_${V_X265}.tar.gz" \
        "https://ftp.videolan.org/pub/videolan/x265/x265_${V_X265}.tar.gz" \
        "https://bitbucket.org/multicoreware/x265_git/downloads/x265_${V_X265}.tar.gz"
    cd "$SRC"
    cmake_static "$SRC/source" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF
}

b_vpx() {
    fetch "libvpx-${V_VPX}.tar.gz" \
        "https://github.com/webmproject/libvpx/archive/refs/tags/v${V_VPX}.tar.gz"
    cd "$SRC"
    ./configure --prefix="$DEPS_PREFIX" --enable-static --disable-shared --enable-pic \
        --enable-vp9-highbitdepth --disable-examples --disable-tools --disable-docs --disable-unit-tests
    make $JOBS; make install
}

b_aom() {
    git_fetch "aom" "v${V_AOM}" \
        "https://aomedia.googlesource.com/aom"
    cd "$SRC"
    cmake_static "$SRC" -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 \
        -DCONFIG_AV1_ENCODER=1 -DCONFIG_AV1_DECODER=1
}

b_dav1d() {
    fetch "dav1d-${V_DAV1D}.tar.gz" \
        "https://code.videolan.org/videolan/dav1d/-/archive/${V_DAV1D}/dav1d-${V_DAV1D}.tar.gz"
    cd "$SRC"; meson_static -Denable_tools=false -Denable_tests=false
}

b_opus() {
    fetch "opus-${V_OPUS}.tar.gz" \
        "https://github.com/xiph/opus/releases/download/v${V_OPUS}/opus-${V_OPUS}.tar.gz" \
        "https://downloads.xiph.org/releases/opus/opus-${V_OPUS}.tar.gz"
    cd "$SRC"; autotools --disable-doc --disable-extra-programs
}

b_lame() {
    fetch "lame-${V_LAME}.tar.gz" \
        "https://downloads.sourceforge.net/lame/lame-${V_LAME}.tar.gz"
    cd "$SRC"; autotools --enable-nasm --disable-frontend
}

b_fdkaac() {
    fetch "fdk-aac-${V_FDKAAC}.tar.gz" \
        "https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v${V_FDKAAC}.tar.gz"
    cd "$SRC"; ./autogen.sh; autotools
}

b_ogg() {
    fetch "libogg-${V_OGG}.tar.gz" \
        "https://downloads.xiph.org/releases/ogg/libogg-${V_OGG}.tar.gz" \
        "https://github.com/xiph/ogg/releases/download/v${V_OGG}/libogg-${V_OGG}.tar.gz"
    cd "$SRC"; autotools
}

b_vorbis() {
    fetch "libvorbis-${V_VORBIS}.tar.gz" \
        "https://downloads.xiph.org/releases/vorbis/libvorbis-${V_VORBIS}.tar.gz"
    cd "$SRC"; autotools --disable-docs --disable-examples --with-ogg="$DEPS_PREFIX"
}

b_theora() {
    fetch "libtheora-${V_THEORA}.tar.gz" \
        "https://downloads.xiph.org/releases/theora/libtheora-${V_THEORA}.tar.gz"
    cd "$SRC"
    autotools --disable-examples --disable-asm --disable-oggtest --disable-vorbistest \
        --disable-spec --with-ogg="$DEPS_PREFIX" --with-vorbis="$DEPS_PREFIX"
}

build_dependencies() {
    build zlib       b_zlib
    build bzip2      b_bzip2
    build openssl    b_openssl
    build expat      b_expat
    build freetype   b_freetype
    build fribidi    b_fribidi
    build harfbuzz   b_harfbuzz
    build fontconfig b_fontconfig
    build libass     b_libass
    build x264       b_x264
    build x265       b_x265
    build vpx        b_vpx
    build aom        b_aom
    build dav1d      b_dav1d
    build opus       b_opus
    build lame       b_lame
    build fdkaac     b_fdkaac
    build ogg        b_ogg
    build vorbis     b_vorbis
    build theora     b_theora
}

# ── FFmpeg ─────────────────────────────────────────────────────────────────────
build_ffmpeg() {
    step "Building FFmpeg ${V_FFMPEG}"
    fetch "ffmpeg-${V_FFMPEG}.tar.xz" \
        "https://ffmpeg.org/releases/ffmpeg-${V_FFMPEG}.tar.xz"
    cd "$SRC"
    make distclean 2>/dev/null || true

    # NB: we deliberately do NOT pass -static (would static-link glibc → segfaults
    # in getaddrinfo/NSS). Only our prefix has .a files, so all codecs link static
    # automatically; libstdc++/libgcc are folded in via the -static-* flags. glibc
    # stays dynamic. The result is verified afterwards by verify_static().
    ./configure \
        --prefix="$FF_PREFIX" \
        --pkg-config-flags=--static \
        --extra-cflags="-I$DEPS_PREFIX/include" \
        --extra-ldflags="-L$DEPS_PREFIX/lib -L$DEPS_PREFIX/lib64 -static-libgcc -static-libstdc++" \
        --extra-libs="-lpthread -lm -ldl -lstdc++" \
        --extra-version="XCVM" \
        --enable-static --disable-shared --enable-pic \
        --disable-debug --disable-doc --disable-ffplay \
        --enable-gpl --enable-version3 --enable-nonfree \
        --enable-runtime-cpudetect \
        --enable-openssl \
        --enable-zlib --enable-bzlib \
        --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom --enable-libdav1d \
        --enable-libopus --enable-libmp3lame --enable-libfdk-aac \
        --enable-libvorbis --enable-libtheora \
        --enable-libass --enable-libfreetype --enable-libfribidi --enable-libharfbuzz --enable-fontconfig
    make $JOBS
    make install
}

# ── Verification: fail the build if any non-glibc lib is dynamically needed ─────
# This is the guard that makes "libraries are baked in" a checked invariant
# rather than a hope. Allowed NEEDED entries are the glibc family + libgcc_s,
# which exist on every Linux host.
verify_static() {
    local bin="$1"
    local allow='^(libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|ld-linux.*|linux-vdso.*)\.so'
    step "Verifying $bin has no external library dependencies"
    "$bin" -version >/dev/null 2>&1 || die "$bin does not run"

    local needed bad=()
    needed="$(readelf -d "$bin" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')"
    echo "$needed" | sed 's/^/    NEEDED /'
    local lib
    while read -r lib; do
        [[ -z "$lib" ]] && continue
        if ! [[ "$lib" =~ $allow ]]; then
            bad+=("$lib")
        fi
    done <<< "$needed"

    if [[ ${#bad[@]} -gt 0 ]]; then
        die "NOT self-contained — external dynamic deps remain: ${bad[*]}"
    fi
    msg "✓ self-contained (only glibc/libgcc dynamic deps)"
}

# ── Package ────────────────────────────────────────────────────────────────────
package() {
    step "Packaging into $OUT_DIR"
    local ff="$FF_PREFIX/bin/ffmpeg" fp="$FF_PREFIX/bin/ffprobe"
    [[ -x "$ff" ]] || die "ffmpeg not built"
    [[ -x "$fp" ]] || die "ffprobe not built"

    install -m 0755 "$ff" "$OUT_DIR/ffmpeg"
    install -m 0755 "$fp" "$OUT_DIR/ffprobe"
    strip --strip-unneeded "$OUT_DIR/ffmpeg" "$OUT_DIR/ffprobe" 2>/dev/null || true

    verify_static "$OUT_DIR/ffmpeg"
    verify_static "$OUT_DIR/ffprobe"

    cat > "$OUT_DIR/BUILD_INFO" <<EOF
Built by : XC_VM FFmpeg static builder
FFmpeg   : ${V_FFMPEG}
Date     : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
OS       : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)
glibc    : $(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')
Arch     : $(uname -m)
Strategy : all codecs static, glibc dynamic (verified self-contained)
EOF

    # Per-version archive: out/ffmpeg/ffmpeg_<label>.tar.gz (the dir groups all
    # versions; the filename is already the release-asset name, so upload needs no
    # rename and md5sum yields the exact name the panel's getAssetHash looks up).
    mkdir -p "$OUT_DIR/ffmpeg"
    ( cd "$OUT_DIR" && tar czf "ffmpeg/ffmpeg_${FF_LABEL}.tar.gz" ffmpeg ffprobe BUILD_INFO )
    msg "Archive: $OUT_DIR/ffmpeg/ffmpeg_${FF_LABEL}.tar.gz ($(du -h "$OUT_DIR/ffmpeg" | cut -f1) ffmpeg binary)"
}

# ── Summary of enabled features ────────────────────────────────────────────────
show_features() {
    local ff="$OUT_DIR/ffmpeg"
    step "Enabled features"
    local f
    for f in libx264 libx265 libvpx libaom libdav1d libopus libmp3lame libfdk-aac \
             libvorbis libtheora libass libfreetype libfontconfig libharfbuzz; do
        if "$ff" -version 2>/dev/null | grep -q -- "--enable-$f"; then
            echo -e "   ${GREEN}✓${NC} $f"
        else
            echo -e "   ${RED}✗${NC} $f"
        fi
    done
    echo -e "   HLS demux/mux : $("$ff" -formats 2>/dev/null | grep -q ' hls' && echo "✓" || echo "✗")"
    echo -e "   DASH demux/mux: $("$ff" -formats 2>/dev/null | grep -q ' dash' && echo "✓" || echo "✗")"
    echo -e "   TLS (https)   : $("$ff" -protocols 2>/dev/null | grep -q 'https' && echo "✓" || echo "✗")"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    [[ "$(id -u)" -eq 0 ]] || die "must run as root"
    step "XC_VM FFmpeg static builder — FFmpeg ${V_FFMPEG}, all codecs baked in"
    command -v apt-get >/dev/null 2>&1 || die "this builder targets Debian (apt-get not found)"

    install_build_tools
    build_dependencies
    build_ffmpeg
    package
    show_features

    msg "✅ DONE — portable FFmpeg in $OUT_DIR"
}

case "${1:-}" in
    -h|--help)
        echo "Usage: OUT_DIR=/path $0"
        echo "Builds a fully static (glibc-dynamic only) FFmpeg ${V_FFMPEG} with all codecs baked in."
        echo "Run as root, ideally inside the Debian 11 container (./build_all.sh ffmpeg)."
        exit 0 ;;
    *) main ;;
esac
