# mariadb-galera

A container image for running a **MariaDB + Galera 4** multi-primary cluster —
synchronous replication, read/write on every node, automatic node provisioning via
state transfer. Two MariaDB LTS lines are published in parallel: **12.3** (current
LTS, the default `:latest` / `:lts`) and **11.8** (previous LTS, maintained until
upstream end of life).

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
| `latest`, `lts` | Latest build of the **current LTS series** (12.3). Moves — and moves to the next LTS when one is adopted. |
| `12.3`, `11.8` | Latest build of that series (moves) |
| `12.3.x`, `11.8.y` | Latest build of that exact MariaDB version (moves with base-image rebuilds) |
| `<version>-YYYYMMDD-HHmmss` (e.g. `12.3.3-20260910-041700`) | Immutable, timestamped build — **use this in production** |
| `sha-<git-sha>-<series>` (e.g. `sha-<git-sha>-12.3`) | Build of a specific commit for one series |

**Upgrading between series is not automatic-safe.** `:latest` / `:lts` follow the
newest LTS, so a container that pulls them can jump a major version. For a running
cluster pin an immutable `<version>-<timestamp>` tag (or a series tag) and disable
auto-updaters such as Watchtower for the database. Moving a datadir from 11.8 to 12.3
is a MariaDB upgrade (roll one node at a time, then run `mariadb-upgrade` **once**, after
every node is on the new version, so its system-table changes never replicate into a
node still on the old one) and downgrading is not supported.

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
| `MARIADB_GALERA_IST_RECV_BIND` | — | Address the IST receiver binds to (sets `ist.recv_bind`). Use `0.0.0.0` in a bridge-networked or rootless container that cannot bind its advertised `NODE_ADDRESS` — see [Bridge networking](#bridge-networking-and-rootless-docker). |
| `MARIADB_GALERA_PROVIDER_OPTIONS` | — | Extra Galera provider options, e.g. `evs.suspect_timeout=PT10S; evs.inactive_timeout=PT30S`. Combined with `IST_RECV_BIND` into the single `wsrep_provider_options` setting. |
| `MARIADB_GALERA_EXTRA_FLAGS` | — | Extra space-separated flags appended to `mariadbd`. A `--wsrep-provider-options=…` here **replaces** the two variables above (the option is one string; settings do not merge). |

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
  ghcr.io/athegreat90/mariadb-galera:lts

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
  image: ghcr.io/athegreat90/mariadb-galera:lts   # or :11.8 (previous LTS); pin a <version>-<timestamp> tag in production
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

## Bridge networking and rootless Docker

When a node runs on a bridge network (or under rootless Docker) with published ports,
its advertised `MARIADB_GALERA_NODE_ADDRESS` (e.g. a Tailscale IP) is not an address
inside the container. The Galera IST receiver defaults to binding that address and fails
with `Cannot assign requested address`. Bind it to the wildcard while still advertising
the real address, and loosen the failure-detection timeouts if the link has latency
spikes (a VPN, for example):

```yaml
services:
  mariadb-galera:
    image: ghcr.io/athegreat90/mariadb-galera:lts
    environment:
      MARIADB_GALERA_NODE_ADDRESS: x.x.x.x        # address the other nodes use
      MARIADB_GALERA_IST_RECV_BIND: 0.0.0.0
      MARIADB_GALERA_PROVIDER_OPTIONS: "evs.suspect_timeout=PT10S; evs.inactive_timeout=PT30S; evs.install_timeout=PT15S"
    ports:
      - "3306:3306"
      - "4567:4567/tcp"
      - "4567:4567/udp"
      - "4568:4568/tcp"
      - "4444:4444/tcp"
```

## Restarting nodes safely

- **Never restart all nodes at once.** Galera needs the others up while one restarts.
  Update one node at a time and wait for `wsrep_local_state_comment=Synced` before the
  next. Do not point a generic auto-updater (e.g. Watchtower) at every node on the same
  schedule; that is how a whole cluster goes down together.
- **Give MariaDB time to stop cleanly.** Docker kills a container after 10 s by default.
  A node killed mid-shutdown leaves `seqno: -1` in `grastate.dat`, and if every node is
  killed that way none of them can bootstrap on its own. Set
  `stop_grace_period: 60s` (Compose) or `--stop-timeout 60` (`docker run`).
- **Container environment is frozen when the container is created.** After changing any
  `MARIADB_GALERA_*` variable, recreate the container (`docker compose up -d
  --force-recreate`). A stale `MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes` left in a running
  container makes every restart try to start a new cluster.

## Using secrets instead of plaintext

Every password variable has a `_FILE` counterpart. With Compose:

```yaml
services:
  node1:
    image: ghcr.io/athegreat90/mariadb-galera:lts
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

Galera must be re-bootstrapped from the node that had the most recent data. After an
unclean shutdown every node shows `seqno: -1` and `safe_to_bootstrap: 0` in
`grastate.dat`, so the file cannot tell you which node that is — the image ships a helper
that can.

1. Stop every node's container. On each node, run the helper against that node's data
   directory (the node must not be running):

   ```bash
   docker run --rm --entrypoint galera-recover.sh \
     -v /path/to/node-data:/var/lib/mysql \
     ghcr.io/athegreat90/mariadb-galera:lts
   # uuid=<cluster-uuid> seqno=956 safe_to_bootstrap=0
   ```

   It runs InnoDB crash recovery and prints the position that node can recover to.
   Compare the `seqno` across nodes (same `uuid`); the **highest** is the one to
   bootstrap. If they tie, any of the tied nodes will do.
2. Start that node with both:
   - `MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes`
   - `MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes`

   Without the second, the image refuses to bootstrap a node whose `grastate.dat` has
   `safe_to_bootstrap: 0` and tells you why; setting it is your confirmation that this
   node holds the newest data.
3. Start the remaining nodes normally. They will SST/IST from the bootstrapped node.
4. Once the cluster is healthy, **remove the two bootstrap variables** and recreate that
   node's container so its next restart rejoins instead of forking a new cluster.

If a node crash-loops with `safe_to_bootstrap` in its log even though you never meant
to bootstrap, `MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes` is still set on the running
container: remove it and recreate the container.

## Build it yourself

```bash
# builds on the current LTS by default; pick a series with --build-arg
docker build -t mariadb-galera:local .
docker build -t mariadb-galera:local-11.8 \
  --build-arg BASE_IMAGE=docker.io/library/mariadb:11.8 .

# single-node smoke test (boots a node, waits for healthy, checks cluster size)
./test/smoke-test.sh mariadb-galera:local

# forced 2-node state transfer test (joiner receives data via mariabackup SST)
./test/sst-test.sh mariadb-galera:local

# outage test: kills both nodes, checks the bootstrap guard and galera-recover.sh
./test/resilience-test.sh mariadb-galera:local
```

The `Dockerfile` takes its base from the `BASE_IMAGE` build argument. CI passes the
digest-pinned image for each series from [`.github/base-images.json`](.github/base-images.json),
and a daily workflow (`base-image-watch`) refreshes those digests and rebuilds the
series that moved. See [`CLAUDE.md`](CLAUDE.md) for the full build and release
pipeline, and for how a series is added or retired.
