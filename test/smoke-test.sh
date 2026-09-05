#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?usage: smoke-test.sh IMAGE}"
NAME="galera-smoke-$$"

cleanup() { docker logs "$NAME" 2>&1 | tail -n 50 || true; docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" \
  -e MARIADB_ROOT_PASSWORD=smoketest \
  -e MARIADB_GALERA_CLUSTER_NAME=smoke \
  -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes \
  -e MARIADB_GALERA_MARIABACKUP_PASSWORD=smokebackup \
  "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = "healthy" ]; then
    size="$(docker exec -e MYSQL_PWD=smoketest "$NAME" \
      mariadb --protocol=socket -uroot -N -B \
      -e "SHOW STATUS LIKE 'wsrep_cluster_size'" | awk '{print $2}')"
    provider="$(docker exec -e MYSQL_PWD=smoketest "$NAME" \
      mariadb --protocol=socket -uroot -N -B \
      -e "SHOW STATUS LIKE 'wsrep_provider_version'" | awk '{print $2}')"
    [ "$size" = "1" ] || { echo "expected cluster size 1, got '$size'" >&2; exit 1; }
    echo "OK: single-node cluster synced, wsrep provider ${provider}"
    exit 0
  fi
  sleep 5
done

echo "container never became healthy" >&2
exit 1