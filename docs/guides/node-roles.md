# Node roles

Choose a role when joining an existing network:

```bash
./scripts/join.sh <moniker> --role fullnode
./scripts/join.sh <moniker> --role rpc
./scripts/join.sh <moniker> --role validator
./scripts/join.sh <moniker> --role sentry
./scripts/join.sh <moniker> --role seed
```

The default role is `fullnode`. `--public-api` remains an alias for `--role
rpc`, and `--seed` remains an alias for `--role seed`. The selected role is
stored as non-secret `validator-kit-role` metadata in the node home. Existing
homes are not silently converted; `join.sh --force` is an explicit destructive
replacement operation.

| Role | P2P | RPC | API | gRPC | Seed mode |
| --- | --- | --- | --- | --- | --- |
| fullnode | public | localhost | disabled | localhost | no |
| rpc | public | public | enabled/public | enabled/public | no |
| validator | public | localhost | disabled | localhost | no |
| sentry | public | localhost | disabled | localhost | no |
| seed | public | disabled | disabled | disabled | yes |

`validator` provides validator-suitable configuration but does not create,
register, or stake a validator. A standalone validator remains supported;
sentry private-peer topology and firewall rules are separate future work.

State sync is independent of role. Pass `--rpc URL` to the deployment flow
when state sync is desired; use `--non-interactive` for unattended operation.
Public RPC deployments should be protected externally with firewalling,
rate-limiting, and TLS/reverse-proxy controls appropriate to the environment.
