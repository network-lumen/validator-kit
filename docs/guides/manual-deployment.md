# Manual Deployment

This procedure provisions a Linux node from source without using validator-kit
deployment automation. It uses the current mainnet data in this repository;
replace `networks/mainnet` only after verifying the matching testnet or devnet
files.

## 1. Prepare the host

Use a dedicated unprivileged node user and persistent storage. The build host
needs Git, Go, Make, a C compiler, `curl`, `jq`, `tar`, `awk`, `sed`, `find`,
and `sha256sum`; `systemd` is needed for service management. The upstream
source currently recommends Go 1.25.3 or newer. Do not expose RPC, API, gRPC,
or Prometheus ports until firewall and access controls are in place.

```bash
export NODE_USER="${NODE_USER:-$USER}"
export LUMEN_HOME="${LUMEN_HOME:-$HOME/.lumen}"
export CHAIN_ID="lumen"
```

## 2. Build `lumend` from source

The source repository and `make build-native` target are documented at
[network-lumen/blockchain](https://github.com/network-lumen/blockchain):

```bash
export SOURCE_DIR="${SOURCE_DIR:-$HOME/src/lumen-blockchain}"
git clone https://github.com/network-lumen/blockchain "$SOURCE_DIR"
cd "$SOURCE_DIR"
git fetch --tags
git tag --list 'v*' --sort=-version:refname | head
git checkout <VERIFIED_UPSTREAM_TAG_OR_COMMIT>
make build-native
export LUMEND="$SOURCE_DIR/build/lumend"
"$LUMEND" version
```

The placeholder is intentional. Validator-kit defaults to binary release
`v1.4.3`, but this repository does not record the source commit that produced
that artifact. Verify the matching upstream revision with release maintainers
before treating a source build as equivalent. Do not use an unverified binary
or source revision.

## 3. Initialize and configure the home

Keep validator-kit available as read-only reference data. Use the matching
network directory for genesis, seeds, peers, and the role profile; do not
invent network values.

```bash
export KIT_DIR="$HOME/src/validator-kit"
export NETWORK="mainnet"
"$LUMEND" init "${MONIKER:-lumen-validator}" --chain-id "$CHAIN_ID" --home "$LUMEN_HOME"
cp "$KIT_DIR/config/validator/"{app.toml,client.toml,config.toml} "$LUMEN_HOME/config/"
cp "$KIT_DIR/networks/$NETWORK/genesis.json" "$LUMEN_HOME/config/genesis.json"
SEEDS="$(awk 'NF { gsub(/[[:space:]]+/,""); printf "%s%s", sep, $0; sep="," }' "$KIT_DIR/networks/$NETWORK/seeds.txt")"
PEERS="$(awk 'NF { gsub(/[[:space:]]+/,""); printf "%s%s", sep, $0; sep="," }' "$KIT_DIR/networks/$NETWORK/peers.txt")"
sed -i "s|^seeds *=.*|seeds = \"$SEEDS\"|; s|^persistent_peers *=.*|persistent_peers = \"$PEERS\"|" \
  "$LUMEN_HOME/config/config.toml"
```

The validator profile keeps API disabled, binds gRPC to localhost, disables
PEX, and uses `minimum-gas-prices = "0ulmn"`. Review the profile and firewall
before changing those controls.

## 4. Configure state sync manually

Choose a trusted RPC. Verify its chain ID and sync status, then obtain a
recent height and commit hash. Confirm the values with a second trusted source.

```bash
export RPC_URL="https://trusted-rpc.example:26657"
STATUS="$(curl -fsS "$RPC_URL/status")"
[[ "$(jq -r '.result.node_info.network' <<< "$STATUS")" == "$CHAIN_ID" ]]
[[ "$(jq -r '.result.sync_info.catching_up' <<< "$STATUS")" == "false" ]]
LATEST_HEIGHT="$(jq -r '.result.sync_info.latest_block_height' <<< "$STATUS")"
TRUST_HEIGHT=$((LATEST_HEIGHT - 100))
TRUST_HASH="$(curl -fsS "$RPC_URL/block?height=$TRUST_HEIGHT" | jq -r '.result.block_id.hash')"
sed -i \
  -e 's|^enable *=.*|enable = true|' \
  -e "s|^rpc_servers *=.*|rpc_servers = \"$RPC_URL,$RPC_URL\"|" \
  -e "s|^trust_height *=.*|trust_height = $TRUST_HEIGHT|" \
  -e "s|^trust_hash *=.*|trust_hash = \"$TRUST_HASH\"|" \
  "$LUMEN_HOME/config/config.toml"
```

Do not start with state sync enabled if the home already contains chain data.
Stop the node and clear only verified disposable data before retrying.

## 5. Install Cosmovisor and create the service

Install the pinned tool version without using `@latest`, then copy the source
build into the genesis directory:

```bash
COSMOVISOR_VERSION="v1.7.3"
GOBIN="$(go env GOBIN)"; [[ -n "$GOBIN" ]] || GOBIN="$(go env GOPATH)/bin"
GOBIN="$GOBIN" go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@"$COSMOVISOR_VERSION"
export COSMOVISOR="$GOBIN/cosmovisor"
mkdir -p "$LUMEN_HOME/cosmovisor/genesis/bin" "$LUMEN_HOME/cosmovisor/upgrades"
cp "$LUMEND" "$LUMEN_HOME/cosmovisor/genesis/bin/lumend"
```

Create a systemd unit running as `NODE_USER`, with `HOME`, `DAEMON_HOME`,
`DAEMON_NAME=lumend`, `DAEMON_ALLOW_DOWNLOAD_BINARIES=false`, and
`DAEMON_RESTART_AFTER_UPGRADE=true`. For example, write and review this unit
as `/etc/systemd/system/lumend.service` (adjust absolute paths):

```ini
[Unit]
Description=Lumen node
After=network-online.target
Wants=network-online.target

[Service]
User=<node-user>
Environment=HOME=<node-user-home>
Environment=DAEMON_NAME=lumend
Environment=DAEMON_HOME=<lumen-home>
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
ExecStart=<cosmovisor-path> run start --home <lumen-home>
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Then run `sudo systemctl daemon-reload`, `sudo systemctl enable --now lumend`,
and inspect `systemctl status lumend` and `journalctl -u lumend -f`.

## 6. Create keys and register the validator

Use the `file` keyring backend for an encrypted local keyring. Keep its
password and mnemonic offline; never use the `test` backend on production
hosts.

```bash
"$LUMEND" keys add validator --home "$LUMEN_HOME" --keyring-backend file
ACCOUNT="$($LUMEND keys show validator -a --home "$LUMEN_HOME" --keyring-backend file)"
"$LUMEND" keys pqc-generate --name validator-pqc --home "$LUMEN_HOME" --keyring-backend file
PUB_HEX="$("$LUMEND" keys pqc-show validator-pqc --home "$LUMEN_HOME" --keyring-backend file | sed -n 's/.*PubKey (hex): *//p')"
```

Query `pqc account "$ACCOUNT"`. If it is not linked, submit and wait for:

```bash
"$LUMEND" tx pqc link-account --from validator --pubkey "$PUB_HEX" \
  --scheme dilithium3 --chain-id "$CHAIN_ID" --home "$LUMEN_HOME" \
  --keyring-backend file --node http://127.0.0.1:26657 \
  --yes --fees 0ulmn --broadcast-mode sync -o json
```

Create a temporary validator definition with the consensus public key and
chosen values, then submit it with the PQC signer:

```bash
REAL_PUBKEY="$("$LUMEND" tendermint show-validator --home "$LUMEN_HOME")"
cat > /tmp/validator.json <<EOF
{
  "pubkey": $REAL_PUBKEY,
  "amount": "<SELF_DELEGATION>ulmn",
  "moniker": "${MONIKER:-lumen-validator}",
  "commission-rate": "0.1",
  "commission-max-rate": "0.2",
  "commission-max-change-rate": "0.01",
  "min-self-delegation": "1"
}
EOF
"$LUMEND" tx staking create-validator /tmp/validator.json \
  --from validator --chain-id "$CHAIN_ID" --home "$LUMEN_HOME" \
  --keyring-backend file --node http://127.0.0.1:26657 \
  --pqc-from "$ACCOUNT" --pqc-key validator-pqc --gas auto \
  --gas-adjustment 1.5 --yes --fees 0ulmn --broadcast-mode sync -o json
```

Query the transaction and validator record before delegating additional stake
with `tx staking delegate <VALOPER> <AMOUNT>ulmn`, `--pqc-from "$ACCOUNT"`,
and `--pqc-key validator-pqc`.

## 7. Recovery and toolkit mapping

Keep account/PQC keys and validator configuration in an encrypted offline
backup. `validator-node.bak` and `first-node.bak` do not include signing
state; stop the node and preserve `priv_validator_state.json` before recovery.
The legacy `join-node.bak` directory is scrubbed if present but is not an
export source.

Automated equivalents are `./scripts/lumen-node deploy`,
`./scripts/lumen-node state-sync`, `./scripts/lumen-node upgrade`,
`./scripts/lumen-node backup export`, and `./scripts/lumen-node doctor`.
See the [Lumen validator documentation](https://lumen-browser.com/docs/validators/)
for upstream context.
