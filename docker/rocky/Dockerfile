FROM rockylinux:9

WORKDIR /build

# Entrypoint
COPY docker/entrypoint.sh /entrypoint.sh

# Build scripts
COPY build/ /build/

RUN chmod +x /entrypoint.sh \
    && find /build -type f -name "*.sh" -exec chmod +x {} \;

ENTRYPOINT ["/entrypoint.sh"]
