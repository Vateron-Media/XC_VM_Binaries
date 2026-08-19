# Static FFmpeg builder — Debian 11 gives the oldest glibc of all targets, so the
# resulting binary is forward-compatible with every newer distro we ship.
FROM debian:11

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /build

# Build script (installs its own apt build-deps and compiles every codec from source).
COPY build_ffmpeg.sh /build/build_ffmpeg.sh
RUN chmod +x /build/build_ffmpeg.sh

# The script writes ffmpeg/ffprobe/ffmpeg.tar.gz here; mount the host out/ onto it.
ENV OUT_DIR=/out

ENTRYPOINT ["/build/build_ffmpeg.sh"]
