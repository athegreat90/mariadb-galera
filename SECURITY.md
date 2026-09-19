# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/athegreat90/mariadb-galera/security/advisories/new)
(Security tab → "Report a vulnerability") rather than a public issue. Include the image
tag, what you observed, and how to reproduce it.

## Supported versions

Images are built for the two MariaDB LTS series listed in
[`.github/base-images.json`](.github/base-images.json) (currently `12.3` and `11.8`) and are
rebuilt when the upstream base image changes. Only the latest build of each series is supported;
use the newest `<version>-<timestamp>` tag.

## What this image does and does not protect

- The container runs as the unprivileged `mysql` user. Base images are pinned by digest, and the
  CI scans every build for fixable CRITICAL vulnerabilities, secrets and lint problems
  (`.github/workflows/security.yml`).
- **Galera has no authentication or encryption of its own.** Without TLS, anyone who can reach
  ports 4567, 4568 or 4444 and knows the cluster name can join the cluster and copy the whole
  database, and cluster traffic is readable on the wire. Only expose those ports on a network you
  trust (a VPN such as Tailscale, or a private network), for example by publishing them on that
  network's address only (`100.x.y.z:4567:4567`). Do not publish them on `0.0.0.0` on a LAN or the
  internet.
- SQL access (3306) uses ordinary MariaDB accounts. Restrict remote `root` and require TLS
  (`require_secure_transport`) if it is reachable beyond a trusted network.
- Provide passwords through `*_FILE` secrets rather than plain environment variables where you can.
