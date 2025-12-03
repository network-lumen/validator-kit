# Lumen deployment toolbox

This directory contains everything needed to spin up:

- a hardened **validator** node
- one or more **sentry** (full) nodes
- a private network between them using **Headscale**
- an optional **monitoring stack** (Prometheus + Grafana) on a sentry

The goal is: the validator is never directly exposed to the public Internet,
and operators have a small set of simple, repeatable commands.

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

## Keys, backups and snapshots

- Single-validator chain bootstrap (`scripts/network/bootstrap.sh`) automatically creates:
  - a backup folder in `~/.lumen/first-node.bak` with:
    - mnemonic, keyring, PQC keys, configs, metadata, initial genesis
- Fullnode/sentry join (`scripts/network/join.sh`) creates:
  - a backup folder in `~/.lumen/join-node.bak`
- Continuous snapshots:
  - `scripts/install/lumen-snapshot_service.sh` installs a systemd service
    to create and rotate state snapshots under `/root/snapshots` by default
    (you can choose a different directory at install time, and override at
    runtime with the `SNAP_DIR` environment variable)
  - `scripts/snapshot/restore_snapshot.sh` restores a snapshot into an
    existing home and restarts the service
- Export for off-site backup:
  - `scripts/network/export_backup.sh` bundles:
    - `first-node.bak`
    - the latest snapshot
    into a single archive in `$HOME/exports` by default (or another directory
    if you pass it explicitly)
 - `scripts/install/node_exporter_service.sh` installs Prometheus
   `node_exporter` as a systemd service on the host to expose system-level
   metrics (CPU, RAM, disk, etc.) on `127.0.0.1:9100` by default. Run it
   as root on validator / sentry machines if you want the full hardware
   section of the Grafana dashboard.


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

1. Install the Tailscale client (configured to use your Headscale URL).
2. Use the validator auth key:

```bash
sudo tailscale up --login-server http://<HEADSCALE_HOST>:8080 --authkey <validator-key>
```

3. Bootstrap the validator from this repo:

```bash
cd /path/to/repo
scripts/network/bootstrap.sh <moniker> --force
```

This will:
- create a fresh `$HOME/.lumen` home
- inject the configs from `config/validator`
- generate validator + PQC keys
- create and collect the gentx

### 3. Sentry hosts

On each sentry machine:

1. Install the Tailscale client.
2. Use one of the sentry auth keys:

```bash
sudo tailscale up --login-server http://<HEADSCALE_HOST>:8080 --authkey <sentry-key>
```

3. Join the network as a fullnode:

```bash
cd /path/to/repo
scripts/network/join.sh <moniker> --force
```

You can adjust `config/seeds.txt`, `peers.txt` and `sentries.txt` to
reflect your topology and the peers you trust (including private Headscale IPs).

### 4. Monitoring on a sentry (optional)

On one of the sentry machines you can run the monitoring stack:

```bash
cd /path/to/repo/monitoring
cp .env.example .env
vim prometheus.yml    # set validator Headscale IP / metrics port
vim nginx.conf        # set allowed admin IPs
docker compose up -d
```

This exposes Grafana with:

- login protection (Grafana admin user/password)
- IP whitelisting at the Nginx proxy layer

### 5. Experimental sentry rotation

For advanced setups, there is an experimental helper:

- `scripts/network/sentry_rotation.sh`

It expects two sentry services (e.g. `lumen-sentry-a` and `lumen-sentry-b`)
reachable via systemd from the same host, plus their RPC URLs. It monitors the
active sentry's peer count and, when it crosses a threshold, wakes the sleeping
one, waits for it to catch up, then stops the overloaded one and swaps roles.

By default it runs in dry-run mode and only prints what it would do. Pass
`--apply` to actually start/stop services.
