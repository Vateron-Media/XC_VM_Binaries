# XC_VM — Build Architecture

This document describes the architecture of the **XC_VM** build system, based on Docker containers,
and explains the roles of all key components.

The goal of the architecture is **reproducible, isolated building of XC_VM binaries**
for different Linux distributions without polluting the host system.

---

## General Idea

The XC_VM build is performed according to the following principle:

1. A Docker image is created for each distribution
2. A single entrypoint is launched inside the container
3. EntryPoint selects the appropriate build script by `TARGET`
4. The Build script compiles:

   * NGINX
   * NGINX + RTMP
   * PHP-FPM 8.1
5. The result is assembled in `/home/xc_vm`
6. Binaries are packed into `<target>.tar.gz` and passed to the host

---

## Execution Flow (High-level)

```text
build_all.sh (host)
   |
   |--> docker build (BASE_IMAGE)
   |--> docker run (TARGET)
            |
            v
      docker/entrypoint.sh
            |
            v
      build/*.sh
            |
            v
      /home/xc_vm
            |
            v
      out/<target>.tar.gz
```

---

## Architecture Components

### 1. `build_all.sh` (host-side)

**Purpose:**
CLI wrapper for launching builds.

**Roles:**

* accepts command-line arguments
* allows you to run:

  * all builds
  * groups (debian / ubuntu)
  * individual targets
* builds Docker images
* launches containers with the required `TARGET`

**Examples:**

```bash
./build_all.sh              # all targets
./build_all.sh debian       # Debian 11/12/13
./build_all.sh ubuntu24     # only Ubuntu 24
./build_all.sh rocky        # Rocky Linux 9
```

---

### 2. Docker Images

#### Debian / Ubuntu

**One Dockerfile** is used:

```text
docker/debian/Dockerfile
```

The difference between distributions is set via:

```bash
--build-arg BASE_IMAGE=debian:12
--build-arg BASE_IMAGE=ubuntu:24.04
```

This allows you to:

* avoid Dockerfile duplication
* centralize dependency logic

---

#### Rocky Linux

Rocky Linux has a separate Dockerfile:

```text
docker/rocky/Dockerfile
```

Reasons:

* different package base (dnf)
* different dev-dependencies
* separate build logic

---

### 3. `docker/entrypoint.sh`

**Key build dispatcher inside the container.**

**Functions:**

1. Checks for `TARGET`
2. Selects a build script:

   * `build/all.sh` → Debian / Ubuntu
   * `build/rocky9.sh` → Rocky Linux
3. Starts the build
4. Packs the result
5. Sets permissions
6. Clears unnecessary files

---

### 4. Build Scripts

#### `build/all.sh`

**Universal autoscrip for Debian and Ubuntu.**

It:

* determines the distribution and version
* adapts compilation flags
* compiles:

  * NGINX
  * NGINX + RTMP
  * PHP-FPM 8.1
* takes into account differences:

  * OpenSSL
  * FORTIFY_SOURCE
  * toolchain

> ❗ `build/all.sh` is **not tied to a specific OS version**
> and scales to future Debian / Ubuntu.

---

#### `build/rocky9.sh`

Specialized script for Rocky Linux 9.

Reasons for a separate script:

* different set of dev-packages
* gcc / glibc features
* differences in static linking

---

## Result Structure

After building, the following is formed inside the container:

```text
/home/xc_vm
├── bin/
│   ├── nginx/
│   ├── nginx_rtmp/
│   ├── php/
│   └── network.py
```

EntryPoint:

* sets safe permissions
* removes configs, logs, and test files
* creates an archive:

```text
out/<target>.tar.gz
```

---

## Supported TARGET

| TARGET    | OS            |
| --------- | ------------- |
| debian_11 | Debian 11     |
| debian_12 | Debian 12     |
| debian_13 | Debian 13     |
| ubuntu_18 | Ubuntu 18.04  |
| ubuntu_20 | Ubuntu 20.04  |
| ubuntu_22 | Ubuntu 22.04  |
| ubuntu_24 | Ubuntu 24.04  |
| rocky_9   | Rocky Linux 9 |

---

## Architecture Principles

✔ Full build isolation
✔ One entrypoint — many targets
✔ Minimum Dockerfile
✔ Auto-adaptation to the distribution
✔ Ready for CI/CD
✔ Extensibility without refactoring

---

## Architecture Extension

To add a new distribution:

1. Add a build script (if needed)
2. Register `TARGET` in `entrypoint.sh`
3. Add an item to `build_all.sh`

In most cases, **the Dockerfile does not need to be changed**.

---