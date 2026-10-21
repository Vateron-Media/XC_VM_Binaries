FROM rockylinux:9

WORKDIR /build

# Build dependencies first, in a layer keyed only on the deps script: script edits
# and version bumps reuse it. Refresh with `docker build --no-cache`.
COPY build/deps_rocky9.sh /tmp/deps_rocky9.sh
RUN bash /tmp/deps_rocky9.sh && rm /tmp/deps_rocky9.sh

# ccache masquerades as gcc/cc; its cache is a per-target volume (build_all.sh).
ENV PATH="/usr/lib64/ccache:/root/.local/bin:${PATH}" \
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
