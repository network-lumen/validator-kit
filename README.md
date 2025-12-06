# Lumen deployment toolbox

This directory contains everything needed to spin up:

- a hardened **validator** node
- one or more **sentry** (full) nodes
- a private network between them using **Headscale**
- an optional **monitoring stack** (Prometheus + Grafana) on a sentry

The goal is: the validator is never directly exposed to the public Internet,
and operators have a small set of simple, repeatable commands.

> All commands in this README assume you are inside the `validator-kit/` directory:

## Layout

- `bin/` – `lumend` binary used by the helper scripts
- `config/`
  - `validator/` – template configs for a validator
  - `fullnode/` – template configs for a fullnode / sentry
  - `genesis.json`, `seeds.txt`, `peers.txt`, `sentries.txt`
- `scripts/`
  - `scripts/network/bootstrap.sh` – bootstrap a new single-validator chain
    (validator + initial genesis) from the repo config
  - `scripts/network/join.sh` – join the network as a fullnode/sentry
  - other helper scripts (staking, services, snapshots)
- `headscale/` – local Headscale control-plane (see its README)
- `monitoring/` – Prometheus + Grafana stack (see its README)

## Keys, backups and snapshots (overview)

- Single-validator chain bootstrap (`scripts/network/bootstrap.sh`) automatically creates:
  - a backup folder in `~/.lumen/first-node.bak` with:
    - mnemonic, keyring, PQC keys, configs, metadata, initial genesis
- Fullnode/sentry join (`scripts/network/join.sh`) creates:
  - a backup folder in `~/.lumen/join-node.bak`
- Continuous snapshots:
  - `scripts/install/lumen-snapshot_service.sh` installs a systemd service
    to create and rotate state snapshots under `${HOME}/snapshots` by default
    for the operator that owns the node home (you can choose a different
    directory at install time, and override at runtime with the `SNAP_DIR`
    environment variable). This script must be run with sudo.
  - `scripts/snapshot/restore_snapshot.sh` restores a snapshot into an
    existing home and restarts the service
- Export for off-site backup:
  - `scripts/network/export_backup.sh` bundles:
    - `first-node.bak`
    - the latest snapshot
    into a single archive in `$HOME/exports` by default (or another directory
    if you pass it explicitly)
 - `scripts/network/add_peer.sh` appends a persistent peer
   (`node_id@host:port`) to `config/peers.txt`, updates the local
   `config.toml` if a node home exists, and can optionally restart the
   `lumend` systemd service.
 - `scripts/network/remove_peer.sh` removes a persistent peer from
   `config/peers.txt`, keeps the local `config.toml` in sync, and can
   optionally restart the `lumend` service.
 - `scripts/network/reload_peers.sh` reloads `persistent_peers` in a local
   `config.toml` from the current `config/peers.txt` contents and can
   optionally restart the `lumend` service.
 - `scripts/network/state_sync.sh` configures the `[statesync]` section of
   a node's `config.toml` by querying a trusted RPC server for the latest
   height and computing an appropriate trust height/hash, so new sentries
   can bootstrap quickly without replaying all historical blocks.
 - `scripts/network/lockdown_validator_firewall.sh` applies a strict
   iptables/ip6tables firewall profile on the validator host: only SSH,
   P2P (26656), Prometheus (26660) and (optionally) node_exporter (9100)
   over the Tailscale interface are allowed in, everything else is dropped
   by default.
 - `scripts/network/scrub_validator_keys.sh` removes local Cosmos account
   keyrings and PQC keystores (and optionally local backups and shell
   history) from a validator host so it can run without holding any
   funds-signing keys; it does not touch the consensus key.
 - `scripts/install/node_exporter_service.sh` installs Prometheus
   `node_exporter` as a systemd service on the host to expose system-level
   metrics (CPU, RAM, disk, etc.) on `127.0.0.1:9100` by default. Run it
   as root on validator / sentry machines if you want the full hardware
   section of the Grafana dashboard.


## Configure your topology

Before bootstrapping anything, you can tune the templates in `config/`:

- `config/validator/*.toml` – ports, logging, pruning and Prometheus for the validator
- `config/fullnode/*.toml` – same for sentries / fullnodes
- `config/seeds.txt` – optional seed nodes (one `node_id@host:port` per line)
- `config/peers.txt` – persistent peers you trust (validator ↔ sentries, etc.)

These files are copied as-is into each node home by the scripts, so they become
the “source of truth” you keep under Git.


## Typical flow: 1 validator + N sentries

High level steps:

1. Start Headscale and generate auth keys
2. Join validator + sentries to the Headscale network
3. Bootstrap the validator
4. Join 1..N sentries as fullnodes
5. (Optional) run monitoring on a sentry

### 1. Headscale control plane

On the machine that will host Headscale, and as the Headscale operator account:

```bash
cd headscale
./run/up.sh                      # start Headscale
./run/init.sh --user lumen --sentries 2
```

This creates one auth key for the validator and two for sentries. Keys are
written to a file like, owned by this operator account (keep it private and
distribute individual keys to the corresponding validator / sentry hosts):

- `headscale/headscale_keys_lumen_<timestamp>.txt`

### 2. Validator host

On the validator machine:

1. Clone this repo 

```bash
git clone https://github.com/network-lumen/validator-kit.git
cd validator-kit/
```

2. Install the Tailscale client (configured to use your Headscale URL). On a
   Debian/Ubuntu host you can use the helper:

```bash
sudo scripts/install/tailscale.sh \
  --login-server https://headscale.example.com \
  --authkey <validator-key> \
  --hostname validator-1
```

3. Optionally adjust validator templates and peers in `config/validator/*.toml`
   and `config/{seeds,peers,sentries}.txt`.

4. Bootstrap the validator from this repo:

```bash
scripts/network/bootstrap.sh <moniker> --force
```

This will:
- create a fresh `$HOME/.lumen` home
- inject the configs from `config/validator`
- generate validator + PQC keys
- create and collect the gentx

5. (Recommended) run the validator as a systemd service:

```bash
sudo scripts/install/lumend_service.sh [HOME_DIR] [USER]
```

- the installer must be run with `sudo` and will:
  - default `HOME_DIR` / `USER` to the account that ran sudo
  - ask you which `lumend` binary to use (auto-detects a `lumend` in `$PATH`
    or the repo `bin/lumend` if present)
  - create / update `lumend.service` accordingly

6. (Optional) install automatic snapshots on the validator:

```bash
sudo scripts/install/lumen-snapshot_service.sh
```

This walks you through HOME, snapshot directory, and interval/retention.

7. (Optional) install system metrics exporter:

```bash
sudo scripts/install/node_exporter_service.sh
```

This provides the `node_*` metrics used by the “Hardware health” panels.

8. When you add or rotate sentries, you can append the validator’s
   persistent peers string from this repo and keep the local node
   home in sync using:

```bash
scripts/network/add_peer.sh --peer "<node_id>@100.64.0.2:26656"
```


### 3. Sentry hosts

On each sentry machine:

1. Clone this repo

```bash
git clone https://github.com/network-lumen/validator-kit.git
cd validator-kit/
```

2. Install the Tailscale client. On Debian/Ubuntu you can use:

```bash
sudo scripts/install/tailscale.sh \
  --login-server https://headscale.example.com \
  --authkey <sentry-key> \
  --hostname sentry-a
```

4. Optionally adjust fullnode templates and peers in `config/fullnode/*.toml`
   and `config/{seeds,peers,sentries}.txt`.

5. Join the network as a fullnode:

```bash
scripts/network/join.sh <moniker> --force
```

You can adjust `config/seeds.txt`, `peers.txt` and `sentries.txt` to
reflect your topology and the peers you trust (including private Headscale IPs).

6. (Recommended) install a systemd service for each sentry:

```bash
sudo scripts/install/lumend_service.sh [HOME_DIR] [USER]
```

Use a different `HOME_DIR` / `USER` pair per sentry host as appropriate.

7. (Optional) install the snapshot service and node_exporter just like on the
   validator if you also want on-host snapshots and hardware metrics.

### 4. Monitoring on a sentry (optional)

On one of the sentry machines you can run the monitoring stack:

```bash
cd monitoring
cp .env.example .env
vim prometheus.yml    # set validator Headscale IP / metrics port
vim nginx.conf        # set allowed admin IPs
docker compose up -d
```

This exposes Grafana with:

- login protection (Grafana admin user/password)
- IP whitelisting at the Nginx proxy layer
