# Manual Deployment

This is the transparent equivalent of a fresh `lumen-node deploy` for the
current mainnet. It is intentionally explicit; the automated workflow remains
safer for repeatable provisioning.

## Prerequisites and user context

Use a supported Linux host with `curl`, `jq`, `tar`, `sha256sum`, `awk`,
`sed`, `mktemp`, and `realpath`. `systemd` is required only if the node will
run as a service. Normal node data and the `lumend` process should run as the
ordinary node user, for example:

```bash
export LUMEN_HOME="${LUMEN_HOME:-$HOME/.lumen}"
export NODE_USER="${USER}"
```

The username `lumen` and `/home/lumen` are examples, not requirements. Use
`sudo` only for system-wide Cosmovisor installation or systemd unit management.

## Install and verify `lumend`

The repository currently defaults to release `v1.4.3`, selecting `amd64` or
`arm64` from the Linux host. The installer downloads the matching GitHub
release archive, verifies its entry in `SHA256SUMS`, extracts the expected
binary, and checks `lumend version` before writing `bin/lumend`:

```bash
./scripts/install/download_lumend.sh
export LUMEND="$PWD/bin/lumend"
"$LUMEND" version
```

Do not bypass checksum verification or replace the release with an unverified
binary. Set `LUMEN_RELEASE_TAG` only to a release that has a matching checksum
manifest.

## Initialize the node

Verify the repository chain ID and initialize a fresh home:

```bash
CHAIN_ID="$(jq -r '.chain_id' networks/mainnet/genesis.json)"
"$LUMEND" init "${MONIKER:-hamster-node}" --chain-id "$CHAIN_ID" --home "$LUMEN_HOME"
cp config/validator/{app.toml,client.toml,config.toml} "$LUMEN_HOME/config/"
cp networks/mainnet/genesis.json "$LUMEN_HOME/config/genesis.json"
```

Choose `config/fullnode`, `config/rpc`, `config/validator`, `config/sentry`,
or `config/seed` according to the intended role. The profiles are the
canonical automated configuration. In particular, validator profiles keep
RPC/API/gRPC private, disable PEX, and use `minimum-gas-prices = "0ulmn"`;
the RPC profile intentionally exposes its public interfaces and requires
external firewalling, rate limiting, and TLS controls.

Populate connectivity from repository data rather than inventing peers:

```bash
SEEDS="$(awk 'NF { gsub(/[[:space:]]+/,""); printf "%s%s", sep, $0; sep="," }' networks/mainnet/seeds.txt)"
PEERS="$(awk 'NF { gsub(/[[:space:]]+/,""); printf "%s%s", sep, $0; sep="," }' networks/mainnet/peers.txt)"
sed -i "s|^seeds *=.*|seeds = \"$SEEDS\"|" "$LUMEN_HOME/config/config.toml"
sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" "$LUMEN_HOME/config/config.toml"
```

## State sync

The manual process is: select a trusted RPC, verify its chain ID and
`catching_up` status, choose a recent trust height, obtain the commit hash at
that height, then set `statesync.rpc_servers`, `trust_height`, and `trust_hash`
before the first start. Validator-kit’s state-sync helper performs those
checks, including optional agreement between two RPC endpoints:

```bash
./scripts/network/state_sync.sh --home "$LUMEN_HOME" \
  --rpc https://rpc.example:26657 --non-interactive
```

## Cosmovisor and systemd

Fresh toolkit deployment uses pinned Cosmovisor `v1.7.3`. Reuse an existing
executable or install the pinned version; do not use `@latest`. Resolve an
operator-provided executable before crossing `sudo`; if it is absent, forward
the current user PATH only for the installation path:

```bash
COSMOVISOR="${COSMOVISOR_BIN:-$(command -v cosmovisor 2>/dev/null || true)}"
if [[ -z "$COSMOVISOR" ]]; then
  sudo env "PATH=$PATH" ./scripts/install/install_cosmovisor.sh
  COSMOVISOR=/usr/local/bin/cosmovisor
fi
mkdir -p "$LUMEN_HOME/cosmovisor/genesis/bin" "$LUMEN_HOME/cosmovisor/upgrades"
cp "$LUMEND" "$LUMEN_HOME/cosmovisor/genesis/bin/lumend"
```

The service must run as the node user, not automatically as root. Its
important settings are equivalent to:

```ini
User=<node-user>
Environment=HOME=<node-user-home>
Environment=DAEMON_NAME=lumend
Environment=DAEMON_HOME=<LUMEN_HOME>
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
ExecStart=<cosmovisor> run start --home <LUMEN_HOME>
```

Generate the real unit through the installer, then start it:

```bash
sudo ./scripts/install/lumend_service.sh --mode cosmovisor \
  --cosmovisor-bin "$COSMOVISOR" "$LUMEN_HOME" "$NODE_USER"
sudo systemctl daemon-reload
sudo systemctl enable --now lumend
systemctl status lumend
```

## Toolkit mapping

| Manual operation | Validator-kit equivalent |
| --- | --- |
| Download and verify `lumend` | `scripts/install/download_lumend.sh` |
| Initialize and configure the home | `./scripts/lumen-node deploy` |
| Apply a role profile | `deploy --role ROLE` |
| Validate state sync inputs | `./scripts/lumen-node state-sync` |
| Install Cosmovisor and its layout | Fresh `deploy` workflow |
| Generate and start the unit | `scripts/install/lumend_service.sh` |
| Diagnose service and node health | `./scripts/lumen-node doctor` |

Manual deployment does not create an account, link a PQC identity, or register
a validator. Continue with [become validator](become-validator.md).
