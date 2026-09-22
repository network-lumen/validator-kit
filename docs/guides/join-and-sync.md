# Join and synchronize a Lumen node

Run commands from the repository root on the Linux host that will operate the
node. The default node home is `~/.lumen`; use `--home DIR` or `LUMEN_HOME` to
choose another location. The join flow installs and starts a `lumend` systemd
service and creates a **non-validator** node.

## Standard join

```bash
./scripts/join.sh <moniker>
```

Without an RPC endpoint, the node synchronizes using seeds, peer exchange, and
block replay. The helper downloads and SHA256-verifies `bin/lumend` when
needed, installs the
`config/fullnode/` profile, copies the mainnet genesis from
`networks/mainnet/` into the node home, and writes seeds and peers into its
`config.toml`.

Use `--public-api` only for a public RPC/API node. Use `./scripts/init_seed.sh`
for a P2P seed node; these roles have different configuration profiles.

## Fast sync before first start

If you have a trusted RPC endpoint and the network serves state snapshots,
configure state sync during the initial join:

```bash
./scripts/join.sh <moniker> --rpc http://trusted-rpc:26657
```

The helper validates `/status` before using the endpoint: it must report the
chain ID from the node's `genesis.json`, a numeric latest height, and
`catching_up = false`. It then retrieves and validates the commit hash at a
trust height 100 blocks behind the latest height by default. State sync is not
attempted on a node with existing local state.

One RPC endpoint is supported. CometBFT requires two entries, so a single
endpoint is written as `rpc_servers = "RPC1,RPC1"`; this is compatibility
formatting and does not provide RPC redundancy. Two comma-separated endpoints
may be supplied to `state_sync.sh`; both must report the expected chain and
the same trust hash:

```bash
./scripts/network/state_sync.sh --home "$HOME/.lumen" \
  --rpc https://rpc-a.example.org,https://rpc-b.example.org
```

Validation completes before `config.toml` is replaced. Existing non-empty
state-sync values are shown and require confirmation before replacement. Stop
the node before changing state-sync settings; the helper does not stop or
restart `lumend` automatically.

For unattended deployment, pass the RPC explicitly with
`--non-interactive`. The default trust offset is used without prompting:

```bash
./scripts/network/state_sync.sh --home "$HOME/.lumen" \
  --rpc https://rpc.example.org --non-interactive
```

If state sync is already configured, unattended replacement fails unless
`--force` is also supplied. `--force` permits replacement but does not weaken
RPC, chain-ID, height, catching-up, or trust-hash validation.

To inspect the service and logs:

```bash
sudo systemctl status lumend
journalctl -u lumend -f
```

Do not delete a validator's data directory or reset its signing state to retry
sync. Recovery of an active validator requires a separate safety procedure.
Once the node is synced, continue with the [validator guide](become-validator.md).
