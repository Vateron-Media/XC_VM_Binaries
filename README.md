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
├── build_all.sh          # CLI build management utility
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
* Archives will be created

Result:

```text
out/
├── debian_11.tar.gz
├── debian_12.tar.gz
├── debian_13.tar.gz
├── ubuntu20.tar.gz
├── ubuntu24.tar.gz
└── rocky9.tar.gz
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

| TARGET    | Distribution   |
| --------- | ------------- |
| debian_11 | Debian 11     |
| debian_12 | Debian 12     |
| debian_13 | Debian 13     |
| ubuntu20  | Ubuntu 20.04  |
| ubuntu24  | Ubuntu 24.04  |
| rocky9    | Rocky Linux 9 |

---

## How the build system works

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
* prepares binaries
* cleans up unnecessary files
* sets correct permissions
* packages the result into an archive

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
* The architecture is suitable for CI/CD (GitHub Actions, GitLab CI)

---

## License

See the main XC_VM repository.
