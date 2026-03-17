# XC_VM — Docker Build System

This repository contains a **universal XC_VM binary build system** in isolated Docker containers
for different Linux distributions.

The system is designed for **deterministic builds**:

* `nginx`
* `nginx-rtmp`
* `php-fpm 8.1`

for specific distribution versions without polluting the host system.

Each build outputs a `.tar.gz` archive with a ready-made XC_VM environment.

---

## Key Features

* 🐳 Fully isolated build in Docker
* 📦 One archive = one distribution
* 🔁 Repeatable builds (CI/CD ready)
* 🧠 Automatic build logic for the OS inside the container
* 🧩 Scalable architecture (easy to add new distributions)

---

## Project Structure

```text
.
├── build/
│   ├── all.sh            # Universal build script (Debian / Ubuntu)
│   └── rocky9.sh         # Specific build script for Rocky Linux 9
│
├── docker/
│   ├── debian/
│   │   └── Dockerfile    # Base Dockerfile for Debian / Ubuntu
│   ├── rocky/
│   │   └── Dockerfile    # Dockerfile for Rocky Linux
│   └── entrypoint.sh     # Container entry point
│
├── out/                  # Build results (.tar.gz)
│
├── versions.json         # Centralized dependency versions (auto-updated)
├── check_versions.sh     # Script to check for new upstream releases
├── build_all.sh          # CLI build management utility
│
├── .github/
│   └── workflows/
│       └── check-versions.yml  # GitHub Actions: weekly version check
│
├── .gitignore
└── README.md
```

---

## Requirements

* Docker **20.10+**
* Linux (recommended)
* Sufficient free disk space

Docker check:

```bash
docker --version
```

---

## Quick Start

### Building all distributions

```bash
./build_all.sh
```

The following will happen sequentially:

* Docker images will be built
* XC_VM will be built inside the containers
* Automated tests will verify all binaries
* Archives will be created

Result:

```text
out/
├── debian_11.tar.gz
├── debian_12.tar.gz
├── debian_13.tar.gz
├── ubuntu_18.tar.gz
├── ubuntu_20.tar.gz
├── ubuntu_22.tar.gz
├── ubuntu_24.tar.gz
└── rocky_9.tar.gz
```

---

## CLI: target selection

`build_all.sh` supports running **all builds**, **groups**, or **a single distribution**.

### All builds

```bash
./build_all.sh
./build_all.sh all
```

### Groups

```bash
./build_all.sh debian
./build_all.sh ubuntu
```

### Single distribution

```bash
./build_all.sh debian12
./build_all.sh ubuntu24
./build_all.sh rocky9
```

### Help

```bash
./build_all.sh --help
```

---

## Supported targets

| TARGET      | Distribution    |
| ----------- | --------------- |
| debian_11   | Debian 11       |
| debian_12   | Debian 12       |
| debian_13   | Debian 13       |
| ubuntu_18   | Ubuntu 18.04    |
| ubuntu_20   | Ubuntu 20.04    |
| ubuntu_22   | Ubuntu 22.04    |
| ubuntu_24   | Ubuntu 24.04    |
| rocky_9     | Rocky Linux 9   |

---

## How the build system works

### 0. versions.json (version management)

All dependency versions are defined in a single `versions.json` file at the project root.
Build scripts read versions from this file at startup — no hardcoded versions in build scripts.

**Automatic updates**: A GitHub Actions workflow (`check-versions.yml`) runs weekly and:

1. Checks upstream releases for all components (nginx, openssl, zlib, pcre2, php, flv-module)
2. Updates `versions.json` if newer versions are found
3. Creates an auto-commit with the diff

**Manual check**:

```bash
# Check for updates (dry run)
./check_versions.sh

# Apply updates to versions.json
./check_versions.sh --apply
```

**Tracked components**:

| Component              | Source                                    |
| ---------------------- | ----------------------------------------- |
| nginx                  | nginx.org (stable)                        |
| openssl                | GitHub releases (3.x branch)              |
| zlib                   | GitHub releases                           |
| pcre2                  | GitHub releases                           |
| php                    | php.net (8.1.x branch)                    |
| nginx-http-flv-module  | GitHub releases                           |

---

### 1. build_all.sh (host)

* CLI build interface
* builds Docker images
* runs containers with the `TARGET` variable

---

### 2. Dockerfile

* sets up a clean distribution environment
* installs dependencies
* sets `ENTRYPOINT`

---

### 3. docker/entrypoint.sh (container)

* checks `TARGET`
* selects the appropriate build script:

```text
Debian / Ubuntu → build/all.sh
Rocky Linux     → build/rocky9.sh
```

* starts the build
* **runs automated tests** for all compiled binaries (see below)
* prepares binaries
* cleans up unnecessary files
* sets correct permissions
* packages the result into an archive

---

### 5. Automated Testing

After compilation and before packaging, `entrypoint.sh` runs a suite of tests that validate every built binary. If any test fails, the build is aborted and no archive is created.

#### NGINX tests

* Binary exists at expected path
* `nginx -V` outputs a valid version
* Required modules are present: `http_ssl`, `http_v2`, `http_realip`, `http_stub_status`, `http_auth_request`

#### NGINX RTMP tests

* Binary exists at expected path
* `nginx_rtmp -V` outputs a valid version
* RTMP/FLV module is included

#### PHP tests

* `php` and `php-fpm` binaries exist
* `php -v` reports PHP 8.x
* Required extensions are loaded: `curl`, `mbstring`, `openssl`, `pdo_mysql`, `mysqli`, `gd`, `sockets`, `opcache`, `bcmath`, `exif`, `sodium`
* `php-fpm -t` config validation (when config is available)
* Basic PHP code execution (`php -r`)

---

### 4. build/all.sh

A universal build script that **automatically adapts to the OS inside the container** and performs:

* `nginx` build
* `nginx-rtmp` build
* `php-fpm 8.1` build

All binaries are installed in:

```text
/home/xc_vm
```

---

## Output archive format

Each archive contains a ready-made hierarchy:

```text
bin/
├── nginx/
├── nginx_rtmp/
└── php/
```

The archive is completely self-contained and ready for deployment.

---

## Adding a new distribution

1. Create a build script in `build/`
2. Add the TARGET to `docker/entrypoint.sh`
3. (optional) add an alias to `build_all.sh`

In most cases, the Dockerfile **does not need to be changed**.

---

## Cleaning up Docker images (optional)

```bash
docker image prune -f
```

---

## Notes

* The host system does not receive any dependencies
* All builds are reproducible
* Every build is automatically tested before packaging
* The architecture is suitable for CI/CD (GitHub Actions, GitLab CI)

---

## License

See the main XC_VM repository.
