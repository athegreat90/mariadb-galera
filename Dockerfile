# syntax=docker/dockerfile:1.19

# Pinned by digest: Dependabot can bump it, and base-image-watch.yml compares
# against it. Get a real digest with:
#   docker buildx imagetools inspect mariadb:11.8 --format '{{ .Manifest.Digest }}'
FROM mariadb:11.8@sha256:2439dcd7d14010ecd1ff7a4e1c5abe8e208c34fe35290744deeeaac3569043c3

ARG BASE_IMAGE_REF="docker.io/library/mariadb:11.8"
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
# installing is a cheap no-op if so. The `test -f` guard fails the build early
# if the wsrep provider is missing.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        galera-4 \
        mariadb-backup \
        socat \
        rsync \
        pv \
        gawk \
        iproute2 \
        netcat-openbsd \
        procps \
        ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    test -f /usr/lib/galera/libgalera_smm.so

COPY rootfs/ /

# Runtime-generated config and the SST-user bootstrap SQL are written by the
# entrypoint, which runs as `mysql`, so both dirs must be writable by it.
RUN set -eux; \
    mkdir -p /etc/mysql/galera.conf.d /docker-entrypoint-initdb.d; \
    chown -R mysql:mysql /etc/mysql/galera.conf.d /docker-entrypoint-initdb.d; \
    chmod 0755 /usr/local/bin/galera-entrypoint.sh /usr/local/bin/galera-healthcheck.sh

# 3306 SQL, 4567 replication (tcp+udp), 4568 IST, 4444 SST
EXPOSE 3306 4567/tcp 4567/udp 4568/tcp 4444/tcp

USER mysql

HEALTHCHECK --interval=15s --timeout=10s --start-period=120s --retries=10 \
    CMD ["/usr/local/bin/galera-healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/galera-entrypoint.sh"]
CMD ["mariadbd"]