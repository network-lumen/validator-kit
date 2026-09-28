# Operator scripts

Run these commands from the repository root unless a script says otherwise.
Node setup scripts call `init_node.sh` through the `./scripts/join.sh` entrypoint.
The current node setup scripts use the files in `networks/mainnet/`.

Run `./scripts/doctor.sh` for read-only post-install diagnostics. It checks the
binary, node home, service, local RPC, chain ID, sync state, peers, listeners,
disk space, and sensitive-file warnings without starting, stopping, or repairing
the node.

Use `./scripts/lumen-node deploy <moniker> --role ROLE` for `fullnode`, `rpc`,
`validator`, `sentry`, or `seed`. The default is `fullnode`; `join.sh` and
`init_node.sh` remain advanced compatibility interfaces.

| Area | Commands |
| --- | --- |
| Operator CLI | `./scripts/lumen-node` |
| Node setup | `./scripts/lumen-node deploy`, `./scripts/join.sh` (compatibility) |
| Chain creation | `./scripts/init_chain.sh` (network maintainers only) |
| Validator | `./scripts/blockchain/become_validator.sh`, `./scripts/blockchain/stake_tokens.sh` |
| Peers and security | `./scripts/network/` |
| Installation | `./scripts/install/` |
| Snapshots | `./scripts/snapshot/` (`restore_snapshot.sh` preserves validator signing state) |
| Upgrades | `./scripts/upgrade/` (prepare verified Cosmovisor binaries and inspect status) |

Use the [join guide](../docs/guides/join-and-sync.md) and
[validator guide](../docs/guides/become-validator.md) for supported workflows.
Low-level helpers can overwrite node state or change host firewall rules;
read their usage text before invoking them.

The unified operator entrypoint is `./scripts/lumen-node`. It dispatches the
documented deployment, diagnostics, state-sync, snapshot, upgrade, and backup
workflows to the existing implementation scripts.
