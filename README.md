# mariadb-galera

A container image for running a **MariaDB 11.8 + Galera 4** multi-primary cluster —
synchronous replication, read/write on every node, automatic node provisioning via
state transfer.

It is built on the official [`mariadb`](https://hub.docker.com/_/mariadb) image and
only adds the Galera provider plus a small entrypoint wrapper, so **everything the
upstream image does still works** (`MARIADB_DATABASE`, `MARIADB_USER`,
`docker-entrypoint-initdb.d/`, the `*_FILE` secret convention, and so on). Images are
published for `linux/amd64` and `linux/arm64`.

For image internals, config layering, and CI, see [`CLAUDE.md`](CLAUDE.md).

## Image

```
ghcr.io/athegreat90/mariadb-galera
```

| Tag | Meaning |
|-----|---------|
| `11.8` | Latest build of the 11.8 series (moves) |
| `latest` | Same as `11.8` |
| `11.8-YYYYMMDD-HHmmss` | Immutable, timestamped build — **use this in production** |
| `sha-<git-sha>` | Build from a specific commit |

You can also pin by digest (`...@sha256:...`). Every published manifest carries
build provenance and an SBOM.

## Ports

| Port | Purpose |
|------|---------|
| `3306/tcp` | Client SQL connections |
| `4567/tcp` + `4567/udp` | Galera replication traffic |
| `4568/tcp` | IST (incremental state transfer) |
| `4444/tcp` | SST (snapshot state transfer, mariabackup) |

All four must be reachable **between nodes**. Only `3306` needs to be reachable by
clients.

## Configuration

All configuration is through environment variables. Secrets also accept a `_FILE`
variant (e.g. `MARIADB_ROOT_PASSWORD_FILE=/run/secrets/root_pw`); setting both a
variable and its `_FILE` form is an error.

| Variable | Default | Notes |
|----------|---------|-------|
| `MARIADB_ROOT_PASSWORD` / `_FILE` | — | Root password. Falls back to `MYSQL_ROOT_PASSWORD`. Required unless you use the upstream `MARIADB_ALLOW_EMPTY_ROOT_PASSWORD` / `MARIADB_RANDOM_ROOT_PASSWORD`. |
| `MARIADB_GALERA_MARIABACKUP_PASSWORD` / `_FILE` | — | **Required.** Password for the SST user that nodes use to copy data to each other. Must be identical on every node. |
| `MARIADB_GALERA_CLUSTER_NAME` | `galera` | Logical cluster name. **Must match on every node.** |
| `MARIADB_GALERA_CLUSTER_ADDRESS` | `gcomm://` | `gcomm://host1,host2,host3` — the list of cluster members. Bare `gcomm://` means "start a new cluster" (see bootstrap below). |
| `MARIADB_GALERA_NODE_NAME` | container hostname | This node's name in the cluster. |
| `MARIADB_GALERA_NODE_ADDRESS` | auto-detected | The address other nodes use to reach this one. Auto-detected from the default route; set it explicitly on multi-NIC hosts or when detection is wrong. |
| `MARIADB_GALERA_CLUSTER_BOOTSTRAP` | `no` | Set to `yes` on **exactly one** node to create a brand-new cluster (adds `--wsrep-new-cluster`). All other nodes leave this unset and join it. |
| `MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP` | `no` | Recovery only. With `CLUSTER_BOOTSTRAP=yes`, forces `safe_to_bootstrap: 1` in `grastate.dat` so a node that wasn't cleanly shut down can still bootstrap. |
| `MARIADB_GALERA_MARIABACKUP_USER` | `mariabackup` | Username for the SST account. |
| `MARIADB_GALERA_SST_METHOD` | `mariabackup` | State-transfer method. `mariabackup` is non-blocking and recommended. |
| `MARIADB_GALERA_EXTRA_FLAGS` | — | Extra space-separated flags appended to `mariadbd`. |

**Initialization vars** (`MARIADB_DATABASE`, `MARIADB_USER`, `MARIADB_PASSWORD`,
scripts in `/docker-entrypoint-initdb.d/`, …) behave exactly as in the upstream
image, but they only take effect on the **first start of the bootstrap node** (when
its data directory is empty). Joining nodes receive all databases and accounts
through state transfer, so you do not — and must not — set them per node.

## Quick start — single node

Useful for local development or as a smoke test. A single bootstrapped node is a
fully working (one-member) cluster.

```bash
docker run -d --name galera \
  -e MARIADB_ROOT_PASSWORD=rootpass \
  -e MARIADB_GALERA_CLUSTER_NAME=dev \
  -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes \
  -e MARIADB_GALERA_MARIABACKUP_PASSWORD=backuppass \
  -p 3306:3306 \
  ghcr.io/athegreat90/mariadb-galera:11.8

# wait for it to report healthy
docker inspect -f '{{.State.Health.Status}}' galera

# verify the cluster is up (size 1)
docker exec -e MYSQL_PWD=rootpass galera \
  mariadb --protocol=socket -uroot -N -B \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size'"
```

## 3-node cluster with Docker Compose

Save as `docker-compose.yml`:

```yaml
name: galera

x-node: &node
  image: ghcr.io/athegreat90/mariadb-galera:11.8
  restart: unless-stopped
  environment: &node-env
    MARIADB_ROOT_PASSWORD: rootpass
    MARIADB_GALERA_CLUSTER_NAME: prod
    MARIADB_GALERA_CLUSTER_ADDRESS: gcomm://node1,node2,node3
    MARIADB_GALERA_MARIABACKUP_PASSWORD: backuppass

services:
  node1:
    <<: *node
    hostname: node1
    environment:
      <<: *node-env
      MARIADB_GALERA_NODE_NAME: node1
      MARIADB_GALERA_CLUSTER_BOOTSTRAP: "yes"   # only while first creating the cluster
    ports: ["3306:3306"]
    volumes: ["node1-data:/var/lib/mysql"]

  node2:
    <<: *node
    hostname: node2
    environment:
      <<: *node-env
      MARIADB_GALERA_NODE_NAME: node2
    depends_on:
      node1: {condition: service_healthy}
    volumes: ["node2-data:/var/lib/mysql"]

  node3:
    <<: *node
    hostname: node3
    environment:
      <<: *node-env
      MARIADB_GALERA_NODE_NAME: node3
    depends_on:
      node2: {condition: service_healthy}
    volumes: ["node3-data:/var/lib/mysql"]

volumes:
  node1-data:
  node2-data:
  node3-data:
```

```bash
docker compose up -d

# watch the cluster grow to 3
docker exec -e MYSQL_PWD=rootpass galera-node1-1 \
  mariadb --protocol=socket -uroot -N -B \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size'"
```

The `depends_on: service_healthy` chain makes each node wait until the previous one
is synced, so the cluster forms cleanly on first `up`.

**After the cluster exists, remove `MARIADB_GALERA_CLUSTER_BOOTSTRAP` from `node1`.**
Leaving it set means that any future restart of `node1` tries to start a *new*
cluster instead of rejoining the existing one. For routine restarts of individual
nodes, no bootstrap flag is needed anywhere — a restarted node rejoins
automatically. See [Recovering a cluster](#recovering-a-cluster) for a full outage.

## Using secrets instead of plaintext

Every password variable has a `_FILE` counterpart. With Compose:

```yaml
services:
  node1:
    image: ghcr.io/athegreat90/mariadb-galera:11.8
    environment:
      MARIADB_ROOT_PASSWORD_FILE: /run/secrets/root_pw
      MARIADB_GALERA_MARIABACKUP_PASSWORD_FILE: /run/secrets/sst_pw
      MARIADB_GALERA_CLUSTER_NAME: prod
      MARIADB_GALERA_CLUSTER_ADDRESS: gcomm://node1,node2,node3
      MARIADB_GALERA_NODE_NAME: node1
      MARIADB_GALERA_CLUSTER_BOOTSTRAP: "yes"
    secrets: [root_pw, sst_pw]
    # ...

secrets:
  root_pw:
    file: ./secrets/root_pw.txt
  sst_pw:
    file: ./secrets/sst_pw.txt
```

## Health check

The image ships a `HEALTHCHECK` (`galera-healthcheck.sh`). A node is **healthy** when
`wsrep_ready=ON` and its local state is `Synced` (4) or `Donor/Desynced` (2, still
serving reads/writes while it feeds an SST to another node).

The check connects as `root` over the local socket, so the root password must be in
the container environment (`MARIADB_ROOT_PASSWORD`, `_FILE`, or `MYSQL_ROOT_PASSWORD`)
— it already is in normal use. Orchestrators can use this to gate when a joining node
is added to a load balancer.

## Recovering a cluster

### A single node came back

Just start it with its normal configuration (no bootstrap flag). It rejoins the
cluster automatically — via IST if it was only briefly away, or a full SST otherwise.

### The whole cluster is down

Galera must be re-bootstrapped from the node that had the most recent data:

1. On each node's volume, look at `/var/lib/mysql/grastate.dat` and find the one
   with the **highest `seqno`** (a `seqno` of `-1` means that node did not shut down
   cleanly).
2. Start that node with:
   - `MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes`
   - `MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes` *only if* its `grastate.dat` shows
     `safe_to_bootstrap: 0` (i.e. it wasn't shut down last/cleanly and you have
     confirmed it nonetheless holds the newest data).
3. Start the remaining nodes normally. They will SST/IST from the bootstrapped node.
4. Once the cluster is healthy, **remove the two bootstrap variables** from the first
   node so its next restart rejoins instead of forking a new cluster.

## Build it yourself

```bash
docker build -t mariadb-galera:local .

# single-node smoke test (boots a node, waits for healthy, checks cluster size)
./test/smoke-test.sh mariadb-galera:local
```

The `FROM` line in the `Dockerfile` carries a placeholder digest; CI and Dependabot
populate the real one at build time. See [`CLAUDE.md`](CLAUDE.md) for the full build
and release pipeline.
