# Operator scripts

Run these commands from the repository root unless a script says otherwise.
Node setup scripts call `init_node.sh` through the `scripts/join.sh` entrypoint.
The current node setup scripts use the files in `networks/mainnet/`.

| Area | Commands |
| --- | --- |
| Node setup | `scripts/join.sh`, `scripts/init_seed.sh` |
| Chain creation | `scripts/init_chain.sh` (network maintainers only) |
| Validator | `scripts/blockchain/become_validator.sh`, `stake_tokens.sh` |
| Peers and security | `scripts/network/` |
| Installation | `scripts/install/` |
| Snapshots | `scripts/snapshot/` |

Use the [join guide](../docs/guides/join-and-sync.md) and
[validator guide](../docs/guides/become-validator.md) for supported workflows.
Low-level helpers can overwrite node state or change host firewall rules;
read their usage text before invoking them.
