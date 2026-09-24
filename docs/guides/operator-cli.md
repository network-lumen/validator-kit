# Operator CLI

`./scripts/lumen-node` is a thin dispatcher for supported operator workflows.
It locates implementation scripts relative to the repository checkout and
forwards command arguments without changing their interactive behavior or
exit codes.

## Commands

| Command | Implementation | Purpose |
| --- | --- | --- |
| `deploy` | `scripts/init_node.sh` | Initialize a node with a selected role |
| `doctor` | `scripts/doctor.sh` | Run read-only diagnostics |
| `state-sync` | `scripts/network/state_sync.sh` | Configure validated state sync |
| `snapshot status` | `scripts/snapshot/snapshots_status.sh` | Inspect snapshots |
| `snapshot restore` | `scripts/snapshot/restore_snapshot.sh` | Restore state safely |
| `upgrade prepare` | `scripts/upgrade/prepare_upgrade.sh` | Stage a verified Cosmovisor binary |
| `upgrade status` | `scripts/upgrade/status_upgrade.sh` | Inspect service and upgrade state |
| `backup export` | `scripts/network/export_backup.sh` | Export validator backup material |

Examples:

```bash
./scripts/lumen-node deploy node-1 --role validator
./scripts/lumen-node doctor --progress
./scripts/lumen-node state-sync --home "$HOME/.lumen" --rpc https://rpc.example:26657
./scripts/lumen-node snapshot status "$HOME/snapshots"
./scripts/lumen-node upgrade status --home "$HOME/.lumen"
```

The CLI does not wrap every repository script. Firewall changes, peer
mutation, key scrubbing, service installation, chain creation, staking, and
other low-level or destructive operations remain explicit direct script
invocations. Use `./scripts/lumen-node --help` or command-specific help for
the supported interface; detailed procedures remain in the documentation.
