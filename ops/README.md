# Lumen ops toolbox

This directory hosts operator-focused material (advanced flows, validator
bootstrap, monitoring, private networking).

Most day-to-day operators only need the root-level `README.md` and `join.sh`.

## Binary & config

- `scripts/install/download_lumend.sh` – downloads the `lumend` binary into `../bin/lumend`.  
  Typical usage (from repo root):  
  `ops/scripts/install/download_lumend.sh`

All scripts assume the repo layout:

- `bin/lumend` – binary used by services and helpers.  
- `config/` – templates and params copied into each node home.

## Network bootstrap (new chain)

- `scripts/init_chain.sh <moniker> [--home DIR]` – one-time chain creation (genesis + initial validator).  
  - Wraps `scripts/network/bootstrap.sh` and uses `config/validator/*.toml` + `config/genesis.json`.  
  - Creates a bootstrap backup under `<home>/first-node.bak`.  
  - Intended for network maintainers only.

## Node join (advanced)

Most operators should use `./join.sh` at the repo root. For finer control:

- `scripts/init_node.sh <moniker> [--home DIR] [--rpc URL] [--public-api]`  
  - Orchestrates: join → optional state sync → systemd service install.  
  - Same semantics as `./join.sh`, but callable directly from `ops/scripts`.

- `scripts/network/join.sh <moniker> [--seed|--public-api] [--force]`  
  - Low-level helper that initializes a non-validator node home (config + genesis) from `config/` and `genesis.json`.  
  - Does not touch systemd; you run `lumend start` or install a service yourself.  
  - Promotion to validator + staking is handled by the blockchain helpers under `scripts/blockchain/`.

## Backups & snapshots

- `scripts/network/export_backup.sh` – exports validator backups and latest snapshot into `$HOME/exports`.  
- `scripts/install/lumen-snapshot_service.sh` – installs a systemd service to create/rotate snapshots periodically.  
- `scripts/snapshot/restore_snapshot.sh` – restores a snapshot into an existing home and restarts the service.  
- `scripts/snapshot/snapshots_status.sh` – quick status view of available snapshots.

## Peer & firewall helpers

- `scripts/network/add_peer.sh` / `remove_peer.sh` / `reload_peers.sh` – manage `config/peers.txt` and `persistent_peers` for non-seed nodes.  
- `scripts/network/state_sync.sh` – manually configure `[statesync]` in a node’s `config.toml`.  
- `scripts/network/lockdown_*_firewall.sh` – apply hardened iptables profiles for sentry / RPC / validator hosts.  
- `scripts/network/scrub_validator_keys.sh` – scrub local account keyrings and PQC keystore from a validator host.

## Headscale & monitoring

- `headscale/` – self-contained Headscale control plane. See `headscale/README.md` for setup.  
- `monitoring/` – Prometheus + Grafana stack. See `monitoring/README.md` for usage.

## Validator & staking docs

- `become_validator.md` – step-by-step guide to promote a synced node to validator.  
- `stake_bootstrap.md` – notes for staking / delegation workflows.  
- `validator_specs.md` – recommended hardware, topology and sentry layout.
