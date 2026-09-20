# Manual node setup

This is the transparent equivalent of `scripts/join.sh` for operators who
need to inspect each step or recover a node. The commands below configure the
current mainnet. The automated join workflow remains the recommended path for
new installations.

## Prerequisites

Use a supported Linux host with `curl`, `jq`, `tar`, and `sudo`. Obtain a
verified `lumend` release from the project's release process and make it
executable, for example at `/usr/local/bin/lumend`. Do not install an
unverified binary on a validator host.

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
"$LUMEND" start --home "$LUMEN_HOME" --minimum-gas-prices 0ulmn
```

For a persistent service, the repository service installer can create the
systemd unit after you have reviewed the generated configuration:

```bash
sudo LUMEND_BIN="$LUMEND" scripts/install/lumend_service.sh "$LUMEN_HOME" "$USER"
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
