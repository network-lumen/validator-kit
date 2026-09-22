# Manual node setup

This is the transparent equivalent of `./scripts/join.sh` for operators who
need to inspect each step or recover a node. The commands below configure the
current mainnet. The automated join workflow remains the recommended path for
new installations.

## Prerequisites

Use a supported Linux host with `curl`, `jq`, `tar`, `sha256sum`, and `sudo`.
The installer supports Linux `x86_64` (`amd64`) and `aarch64` (`arm64`) and
verifies the release archive against the published `SHA256SUMS` manifest before
installation. From the repository root, run:

```bash
./scripts/install/download_lumend.sh
```

The default release is `v1.4.3`; set `LUMEN_RELEASE_TAG` to select another
published release. `LUMEN_RELEASE_URL` is an exact archive URL override and
must be paired with `LUMEN_CHECKSUM_URL`. Do not install an unverified binary
on a validator host.

From the repository root, set the node home and confirm the binary:

```bash
export LUMEN_HOME="$HOME/.lumen"
export LUMEND=/usr/local/bin/lumend
"$LUMEND" version
```

## Initialize and configure

Initialize a new, non-validator node. Stop if `LUMEN_HOME` already contains a
node; do not overwrite an existing validator home.

```bash
"$LUMEND" init "<moniker>" --chain-id lumen --home "$LUMEN_HOME"
cp config/fullnode/{app.toml,client.toml,config.toml} "$LUMEN_HOME/config/"
cp networks/mainnet/genesis.json "$LUMEN_HOME/config/genesis.json"
sed -i 's|^minimum-gas-prices *=.*|minimum-gas-prices = "0ulmn"|' "$LUMEN_HOME/config/app.toml"
```

Convert the repository lists to the comma-separated format expected by
`config.toml`, then apply them:

```bash
SEEDS="$(awk 'NF { gsub(/[[:space:]]+/, ""); printf "%s%s", sep, $0; sep="," }' networks/mainnet/seeds.txt)"
PEERS="$(awk 'NF { gsub(/[[:space:]]+/, ""); printf "%s%s", sep, $0; sep="," }' networks/mainnet/peers.txt)"
sed -i "s|^seeds *=.*|seeds = \"$SEEDS\"|" "$LUMEN_HOME/config/config.toml"
sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" "$LUMEN_HOME/config/config.toml"
sed -i 's|^chain-id *=.*|chain-id = "lumen"|' "$LUMEN_HOME/config/client.toml"
```

Review `config.toml`, especially `rpc.laddr`, `p2p.laddr`, `seeds`, and
`persistent_peers`. Do not expose RPC, API, or gRPC listeners publicly without
firewall rules and an operator-reviewed security configuration.

## Start and verify

For an initial foreground run, use:

```bash
"$LUMEND" start --home "$LUMEN_HOME"
```

For a persistent service, the repository service installer can create the
systemd unit after you have reviewed the generated configuration:

```bash
sudo LUMEND_BIN="$LUMEND" ./scripts/install/lumend_service.sh "$LUMEN_HOME" "$USER"
sudo systemctl status lumend
journalctl -u lumend -f
```

Confirm that the node is catching up through the local RPC endpoint before
continuing:

```bash
curl -fsS http://127.0.0.1:26657/status | jq '.result.sync_info'
```

State sync is optional, but must be configured before the first
start; use the [join and synchronize guide](join-and-sync.md) for the trusted
RPC workflow.

This procedure creates a full node only. To create a validator, follow the
[validator guide](become-validator.md). Back up account and PQC keys off-host,
and never run the same consensus key on more than one active node.
