# Lumen Validator Kit

Validator-kit is the operator toolkit for joining and operating Lumen nodes.
It provides role-aware deployment, verified binaries, Cosmovisor-first
services, health checks, state-sync validation, validator/PQC workflows,
backups, snapshot recovery, and upgrade preparation. The included network
files currently configure **mainnet** (`chain_id: lumen`).
The available testnet uses `chain_id: lumen-testnet`; its network inputs are
not yet included in this checkout, so the current join scripts remain
mainnet-only.

## Validator safety

- Back up both your account key and PQC key **off the server** before operating a
  validator. Losing either may mean losing access to your funds.
- Run a consensus key on only one active validator. Do not copy
  `~/.lumen/config/priv_validator_key.json` to a sentry or start a second node
  with the same key; double signing can result in slashing.
- Do not wipe or restore a validator home without an operator-reviewed recovery
  plan, including its signing state.

## Start here

From the repository root on a Linux host:

```bash
./scripts/lumen-node deploy <moniker> --role fullnode [--rpc http://trusted-rpc:26657]
```

Available roles are `fullnode`, `rpc`, `validator`, `sentry`, and `seed`; the
default is `fullnode`. Fresh deployment uses Cosmovisor; direct mode is an
explicit compatibility option. See the [validator quickstart](docs/getting-started/validator-quickstart.md)
for the complete operator journey, or the [node roles guide](docs/guides/node-roles.md)
and [join guide](docs/guides/join-and-sync.md) for listener behavior and
state-sync choices.

## Documentation

- [Join and synchronize a node](docs/guides/join-and-sync.md)
- [Node roles](docs/guides/node-roles.md)
- [Manual deployment](docs/guides/manual-deployment.md)
- [Become a validator and stake](docs/guides/become-validator.md)
- [Lumen keys and PQC identity](docs/concepts/lumen-keys-and-pqc.md)
- [Key separation and hardening](docs/concepts/validator-key-hardening.md)
- [Upgrade management](docs/guides/upgrade-management.md)
- [Operator CLI](docs/guides/operator-cli.md)
- [Seeds and peer discovery](docs/concepts/seeds.md)
- [Validator specifications](docs/reference/validator-specs.md)
- [Staking and voting power](docs/reference/staking.md)
- [Full documentation index](docs/README.md)

Validator-kit does not automatically create accounts, custody mnemonics,
choose funding sources, or perform validator transactions through the unified
CLI. Snapshot creation is also not currently exposed as a first-class
`snapshot create` command; snapshot status and safe restore are implemented.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`scripts/`](scripts/README.md) | Node, network, install, staking, and snapshot helpers |
| [`config/`](config/README.md) | Role-specific node configuration templates |
| [`networks/`](networks/README.md) | Network genesis, seeds, and persistent peers |
| [`ops/`](ops/README.md) | Headscale and monitoring deployments |
| `bin/` | Local `lumend` binary downloaded by the installer |
