ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /build

# Build dependencies first, in a layer keyed only on the deps script: script edits
# and version bumps reuse it. Refresh with `docker build --no-cache`.
COPY build/deps_debian.sh /tmp/deps_debian.sh
RUN bash /tmp/deps_debian.sh && rm /tmp/deps_debian.sh

# ccache masquerades as gcc/cc; its cache is a per-target volume (build_all.sh).
ENV PATH="/usr/lib/ccache:/root/.local/bin:${PATH}" \
    CCACHE_DIR=/ccache \
    CCACHE_MAXSIZE=2G

# Entrypoint
COPY docker/entrypoint.sh /entrypoint.sh

# Build scripts and version config
COPY build/ /build/
COPY versions.json /build/versions.json

RUN chmod +x /entrypoint.sh \
    && find /build -type f -name "*.sh" -exec chmod +x {} \;

ENTRYPOINT ["/entrypoint.sh"]
