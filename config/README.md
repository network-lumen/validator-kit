# Node configuration templates

These TOML files are copied into each node's `~/.lumen/config/` during setup:

- `fullnode/`: standard full node and sentry profile.
- `rpc/`: public RPC/API profile, selected with `--public-api`.
- `validator/`: initial validator profile used for chain creation.

The `genesis_file = "config/genesis.json"` setting in each template is a path
**inside the node home**. The repository source for that file lives at
[`networks/mainnet/genesis.json`](../networks/mainnet/genesis.json).
Network peers and seeds are stored alongside it under `networks/mainnet/`.
