# Node configuration templates

These TOML files are copied into each node's `~/.lumen/config/` during setup:

- `fullnode/`: general full node profile; also the baseline for sentry nodes.
- `rpc/`: public RPC/API profile.
- `validator/`: standalone validator profile; registration remains separate.
- `sentry/`: public-P2P, restricted-service profile for a sentry node.
- `seed/`: P2P discovery profile with CometBFT `seed_mode = true`.

Select a role through `./scripts/join.sh` or `./scripts/init_node.sh`:
`--role fullnode|rpc|validator|sentry|seed`. The default is `fullnode`.
Role selection changes configuration only; all roles use the common
`lumend.service` lifecycle. State sync remains an independent option.

The `genesis_file = "config/genesis.json"` setting in each template is a path
**inside the node home**. The repository source for that file lives at
[`networks/mainnet/genesis.json`](../networks/mainnet/genesis.json).
Network peers and seeds are stored alongside it under `networks/mainnet/`.
