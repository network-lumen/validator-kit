# Lumen deployment toolbox

# ⚠️ CRITICAL VALIDATOR WARNING – READ FIRST ⚠️

## 🚨 KEY BACKUP REQUIREMENT (ED25519 + PQC)

**Validators MUST backup BOTH cryptographic keys:**
- ✅ **ed25519 key** (classic Cosmos key)
- ✅ **PQC key (Dilithium)**

👉 **If you lose ONE of them, you LOSE ACCESS TO YOUR FUNDS.**

---

## ❌ DO NOT DO THIS
- ❌ Do NOT delete your node without backing up **BOTH** keys  
- ❌ Do NOT reinstall / redeploy / wipe `.lumen` blindly  
- ❌ Do NOT assume PQC keys can be regenerated  
- ❌ Do NOT assume there is an override, reset, or admin recovery  

**THERE IS NO PQC KEY OVERRIDE.  
THERE IS NO ADMIN RESET.  
THERE IS NO FUND RECOVERY.**

---

## ⚠️ WHAT HAPPENS IF YOU LOSE YOUR PQC KEY?

If your wallet address is linked to a **lost PQC key**:
- ❌ you CANNOT send tokens
- ❌ you CANNOT restake
- ❌ you CANNOT migrate
- ❌ you CANNOT recover funds
- ❌ funds are **PERMANENTLY LOCKED**
- ❌ funds are **NOT redistributed**
- ❌ funds are **NOT recoverable by governance**

👉 This is **by design**.

This directory contains everything needed to spin up:

- a hardened **validator** node
- one or more **sentry** (full) nodes
- a private network between them using **Headscale**
- an optional **monitoring stack** (Prometheus + Grafana) on a sentry

The goal is: the validator is never directly exposed to the public Internet,
and operators have a small set of simple, repeatable commands.

> All commands in this README assume you are inside the `validator-kit/` directory:

## Node lifecycle overview (important)

Lumen nodes follow a simple, Cosmos‑canonical lifecycle built around two high-level entrypoints:

- `scripts/init_chain.sh <moniker> [--home DIR]` – create a *new* network and its initial validator at block 0.
  - Wraps `scripts/network/bootstrap.sh` and uses `config/validator/*.toml` + `config/genesis.json`.
  - Creates a local bootstrap backup at `<home>/first-node.bak` (mnemonic, consensus key, PQC keys, genesis, metadata).
  - Refuses to run if the resolved home already exists, so you cannot accidentally clobber an existing validator home.
  - Never configures state sync and never uses `peers.txt`; this node is the *origin* of the chain.
  - This script is intended for network maintainers and should be used exactly once per network.
- `scripts/init_node.sh <moniker> [--home DIR] [--rpc http://trusted:26657] [--public-api]` – join an *existing* network as a fullnode / sentry / RPC node.
  - Wraps `scripts/network/join.sh` (and optionally `scripts/network/state_sync.sh`) using `config/fullnode` or `config/rpc`.
  - Creates a local backup at `<home>/join-node.bak`, enables state sync against a trusted RPC endpoint, and only then installs and starts a `lumend` systemd service.
  - Enforces the order **join → state sync → first start** so the node does not start before state sync is configured.
  - Automatically configures state sync by default; advanced operators can adjust or skip state sync using the lower-level helpers.

For both entrypoints:

- By default the node home is a `.lumen` directory under the operator’s home directory. You can override it either with `LUMEN_HOME=/custom/path` or the `--home DIR` flag (the flag wins if both are set).
- The internal helper scripts (`bootstrap.sh`, `join.sh`, `state_sync.sh`, `lumend_service.sh`) are still used as‑is; the orchestration layer only adds ordering, safety checks, and clear logs.

> ⚠️ A validator cannot be bootstrapped locally and then “plugged into” an unrelated existing network. Validators are part of consensus state and must either:
> - exist in genesis (created via `scripts/init_chain.sh` + the initial `genesis.json`), or
> - be declared on‑chain *after* syncing an existing network (for example, a node started with `scripts/init_node.sh` later runs `tx staking create-validator`).

The general mental model is:

- **init_chain** – one‑time network creation on a maintainer machine.
- **init_node** – the canonical entrypoint for everyone else; nodes started this way are not validators by default but may later become validators via on‑chain transactions.

There is intentionally **no** script to “init a validator” on an already‑running network. New validators are created by running a regular node with `scripts/init_node.sh`, syncing it, and then submitting an on‑chain `tx staking create-validator` transaction.

## Layout

- `bin/` – `lumend` binary used by the helper scripts (ignored by Git; see below for how to download it)
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
  - `config/rpc/` – templates for a non-validator RPC/API node (public fullnode)

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
 - `scripts/network/lockdown_sentry_firewall.sh` applies a strict
   iptables/ip6tables firewall profile on a sentry/fullnode host. It sets
   default DROP policies and only allows:
   - SSH over the Tailscale interface
   - P2P (26656) from the public Internet
   - Prometheus (26660) and Grafana (3000) over the Tailscale interface
   Note: because this script flushes existing iptables rules, on hosts
   where Docker is already running you should restart Docker and then any
   docker-compose stacks (monitoring/headscale, etc.) afterward so that
   Docker can recreate its own iptables chains and published ports.
 - `scripts/network/lockdown_rpc_firewall.sh` applies a strict
   iptables/ip6tables firewall profile on a dedicated RPC/API fullnode host:
   only SSH over Tailscale, P2P (26656), RPC (26657), REST API (1317) and
   gRPC (9090) from the public Internet are allowed in by default; lumend
   metrics (26660) and node_exporter (9100) are only reachable over
   Tailscale and from a local Docker bridge (for Prometheus); everything
   else is dropped.
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


## Getting the `lumend` binary

All scripts under `validator-kit/scripts/` assume that a `lumend` binary is either:

- available on `PATH`, or
- present as `validator-kit/bin/lumend` (preferred for validator-kit setups).

The `bin/lumend` file is **not** committed to Git. To fetch the canonical
binary for the current mainnet release, run from the repo root:

```bash
cd validator-kit
./scripts/install/download_lumend.sh
```

By default this downloads the `linux-amd64` tarball for `v1.3.0` from:

- `https://github.com/network-lumen/blockchain/releases/tag/v1.3.0`

and extracts `lumend` into `validator-kit/bin/lumend`.

You can override the source or target via env vars:

- `LUMEN_RELEASE_TAG` – release tag to use (default: `v1.3.0`)
- `LUMEN_RELEASE_URL` – full URL to a tarball (takes precedence over the tag)
- `LUMEN_TARGET` – output path for the binary (default: `validator-kit/bin/lumend`)

Example:

```bash
LUMEN_RELEASE_TAG=v1.3.0 \
LUMEN_TARGET=/usr/local/bin/lumend \
./scripts/install/download_lumend.sh
```

Once the binary is in place, you can run the normal bootstrap/join scripts
and systemd installers without having to manage the `lumend` path manually.


## Configure your topology

Before bootstrapping anything, you can tune the templates in `config/`:

- `config/validator/*.toml` – ports, logging, pruning and Prometheus for the validator
- `config/fullnode/*.toml` – same for sentries / fullnodes
- `config/rpc/*.toml` – RPC/API node (full node exposing 26657/1317/9090)
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
