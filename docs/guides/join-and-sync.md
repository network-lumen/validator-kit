# Join and synchronize a Lumen node

Run commands from the repository root on the Linux host that will operate the
node. The default node home is `~/.lumen`; use `--home DIR` or `LUMEN_HOME` to
choose another location. The join flow installs and starts a `lumend` systemd
service and creates a **non-validator** node.

## Standard join

```bash
scripts/join.sh <moniker>
```

Without an RPC endpoint, the node synchronizes using seeds, peer exchange, and
block replay. The helper downloads `bin/lumend` when needed, installs the
`config/fullnode/` profile, copies the mainnet genesis from
`networks/mainnet/` into the node home, and writes seeds and peers into its
`config.toml`.

Use `--public-api` only for a public RPC/API node. Use `scripts/init_seed.sh`
for a P2P seed node; these roles have different configuration profiles.

## Fast sync before first start

If you have a trusted RPC endpoint and the network serves state snapshots,
configure state sync during the initial join:

```bash
scripts/join.sh <moniker> --rpc http://trusted-rpc:26657
```

The helper writes the trusted height and hash before installing the service.
It prompts for the trust window, defaulting to 100 blocks. Verify that the
trusted endpoint belongs to the intended chain before using it. State sync is
not attempted on a node with existing local state.

To inspect the service and logs:

```bash
sudo systemctl status lumend
journalctl -u lumend -f
```

Do not delete a validator's data directory or reset its signing state to retry
sync. Recovery of an active validator requires a separate safety procedure.
Once the node is synced, continue with the [validator guide](become-validator.md).
