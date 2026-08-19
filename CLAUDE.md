# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker-based, host-isolated build system that compiles XC_VM runtime **binaries** —
`nginx`, `nginx_rtmp` (RTMP/FLV), and `php-fpm 8.1` (with ionCube, OPcache, and a private
`xcvm_core` extension) — for several Linux distributions. There is no application source code
here; the deliverable is one self-contained `out/<target>.tar.gz` per distribution.

## Common commands

```bash
./build_all.sh              # build all targets (debian 11/12/13, ubuntu 20/22/24, rocky 9)
./build_all.sh debian       # group: all Debian targets
./build_all.sh ubuntu24     # single target
./build_all.sh rocky9       # Rocky Linux 9
./build_all.sh --help

./check_versions.sh         # dry-run: report newer upstream releases
./check_versions.sh --apply # write updates into versions.json
```

- A target is **skipped** if its `out/<target>.tar.gz` already exists. Delete the archive to force a rebuild.
- Per-target build logs land in `logs/<target>.log`.
- `out/`, `logs/`, and `downloads/` are gitignored (build artifacts / caches).
- `./build_all.sh ffmpeg` builds a **fully static** FFmpeg 8.1 (every codec compiled from
  source and baked into the binary; only glibc stays dynamic) via `docker/ffmpeg/Dockerfile`
  (Debian 11 → oldest glibc, forward-compatible). It is **opt-in** — not part of the default
  `all` run — and outputs `out/ffmpeg.tar.gz`. The build self-verifies with `readelf -d` and
  aborts if any non-glibc library is dynamically linked. Logic lives in `build_ffmpeg.sh`.

## The xcvm_core extension is built elsewhere; this repo only receives it

The `xcvm_core.so` is coupled only to (a) the PHP 8.1 ABI — **identical on every target**,
same PHP source — and (b) the SONAME of the distro's system OpenSSL/libsodium/curl/glibc,
which differs. So shipping a new extension never rebuilds `nginx`/`php`/`nginx_rtmp` — only
the tiny `.so` changes. **The build lives in the private extension repo**
(`XC_VM_CoreExtention`, `build_script/build_release.sh`): it pulls the PHP toolchain out of
this repo's published runtime archives (`bin/php` inside `<target>.tar.gz` — no PHP recompile),
compiles one `.so` **per OpenSSL-ABI group** on the group's oldest-glibc member
(`openssl1.1` = debian11/ubuntu20 built on debian11; `openssl3` =
rocky9/ubuntu22/debian12/ubuntu24/debian13 built on rocky9), load-tests each on every member's
own PHP, and publishes a GitHub Release.

This repo's only role is to **receive** those assets: `.github/workflows/sync-xcvm-core.yml`
is triggered (repository_dispatch `xcvm_core_released`) by the extension repo's release,
downloads the group archives with a private-read token (secret `XCVM_CORE_PAT`), commits them
under `bin/xcvm_core/<version>/` (+ `SHA256SUMS`), and stamps `versions.json → "xcvm_core".version`
(the single source of truth for the extension version). The private token stays in CI; customer
servers only ever see this public repo. Servers hot-swap the `.so` and reload php-fpm
(`kill -USR2`). Token setup/rotation is documented in the extension repo's `docs/10-release-ci.md`.

## There are no unit tests or linters

The only "tests" are binary-validation checks baked into `docker/entrypoint.sh`, run inside the
container after compilation and **before** packaging. If any check fails the build aborts and no
archive is produced. They verify each binary exists, reports a sane version, and includes required
modules/extensions (nginx http_ssl/v2/realip/etc., RTMP/FLV module, PHP `curl`/`mbstring`/`pdo_mysql`/
`gd`/`opcache`/`sodium`/…, and `xcvm_core.so` when extension sources are mounted). To exercise them,
run a build for the relevant target.

## Architecture / control flow

```
build_all.sh (host)
  ├─ download_deps()      pre-fetch all sources once → downloads/ (mounted RO into every container)
  ├─ docker build         debian/ubuntu share docker/debian/Dockerfile via --build-arg BASE_IMAGE;
  │                       rocky uses docker/rocky/Dockerfile
  └─ docker run -e TARGET=<target>
         └─ docker/entrypoint.sh         dispatch by TARGET
               ├─ build/all.sh           Debian + Ubuntu (auto-adapts to distro/version)
               │   └─ rocky → build/rocky9.sh
               ├─ <binary validation tests>
               └─ package /home/xc_vm → /build/out/<target>.tar.gz
```

Key conventions to preserve when editing:

- **`versions.json` is the single source of truth** for both dependency versions and download URLs.
  Build scripts read it at runtime — never hardcode versions or URLs in scripts. Each `url` is an
  ordered **mirror list** tried in turn; `{VERSION}` and `{ARCH}` are substituted. `check_versions.sh`
  (and the weekly `.github/workflows/check-versions.yml` action) auto-bump versions and commit them.

- **Build output goes to `/home/xc_vm/bin/{nginx,nginx_rtmp,php}/`** inside the container; the host's
  `out/` is bind-mounted to `/build/out` to receive the archive.

- **Private PHP extension (`xcvm_core`)** sources are *not* in this repo. `build_all.sh` mounts
  `$EXT_SRC_DIR` (default `../XC_VM_CoreExtention/extension`, overridable via the `EXT_SRC_DIR` env var)
  read-only at `/build/ext_src`. If absent, the extension is skipped with a warning rather than failing.

- **PHP extension ordering matters**: in `build/all.sh::main`, ionCube loads first, then OPcache, then
  other extensions — this order is reflected in php.ini and must be kept.

## Adding a new distribution

1. Add a build script under `build/` only if the package base differs (Debian/Ubuntu reuse `build/all.sh`).
2. Register the `TARGET` case in `docker/entrypoint.sh`.
3. Add a CLI case + `build` call in `build_all.sh`.
The Dockerfile usually does not need changes (BASE_IMAGE handles Debian/Ubuntu variants).
