# syntax=docker/dockerfile:1.19

# CI passes BASE_IMAGE as <ref>@<digest> from .github/base-images.json (one build
# per MariaDB series). The default only makes a bare local `docker build .` work.
ARG BASE_IMAGE="docker.io/library/mariadb:12.3"
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG BASE_IMAGE_REF="${BASE_IMAGE}"
ARG BASE_IMAGE_DIGEST=""
ARG BUILD_DATE=""
ARG VCS_REF=""

LABEL org.opencontainers.image.title="mariadb-galera" \
      org.opencontainers.image.description="MariaDB Galera Cluster image" \
      org.opencontainers.image.base.name="${BASE_IMAGE_REF}" \
      org.opencontainers.image.base.digest="${BASE_IMAGE_DIGEST}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

USER root

# galera-4 and mariadb-backup may already be present in the official image;
# installing is a cheap no-op if so. MariaDB >= 12.3 unbundled the Galera server
# hooks into `mariadb-server-galera` (11.8 has no such package), so it is added
# only when the repo offers it. The `test -f` guard fails the build early if the
# wsrep provider is missing.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; \
    pkgs="galera-4 mariadb-backup socat rsync pv gawk iproute2 netcat-openbsd procps ca-certificates"; \
    if apt-cache show mariadb-server-galera 2>/dev/null | grep -q '^Package:'; then \
        pkgs="mariadb-server-galera ${pkgs}"; \
    fi; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${pkgs}; \
    rm -rf /var/lib/apt/lists/*; \
    test -f /usr/lib/galera/libgalera_smm.so

COPY rootfs/ /

# Runtime-generated config and the SST-user bootstrap SQL are written by the
# entrypoint, which runs as `mysql`, so both dirs must be writable by it.
RUN set -eux; \
    mkdir -p /etc/mysql/galera.conf.d /docker-entrypoint-initdb.d; \
    chown -R mysql:mysql /etc/mysql/galera.conf.d /docker-entrypoint-initdb.d; \
    chmod 0755 /usr/local/bin/galera-entrypoint.sh /usr/local/bin/galera-healthcheck.sh \
               /usr/local/bin/galera-recover.sh

# 3306 SQL, 4567 replication (tcp+udp), 4568 IST, 4444 SST
EXPOSE 3306 4567/tcp 4567/udp 4568/tcp 4444/tcp

USER mysql

HEALTHCHECK --interval=15s --timeout=10s --start-period=120s --retries=10 \
    CMD ["/usr/local/bin/galera-healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/galera-entrypoint.sh"]
CMD ["mariadbd"]