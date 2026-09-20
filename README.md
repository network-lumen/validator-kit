# Lumen Validator Kit

Tools and documentation for joining and operating the Lumen network. The
included network files currently configure **mainnet** (`chain_id: lumen`).
Testnet and devnet are not configured in this repository yet.

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
scripts/join.sh <moniker> [--rpc http://trusted-rpc:26657]
```

This creates a **non-validator** full node. Use `--public-api` only when you
intend to run the public RPC/API profile. See the [join guide](docs/guides/join-and-sync.md)
for prerequisites and synchronization choices. Promotion to validator is a
separate, explicit step.

## Documentation

- [Join and synchronize a node](docs/guides/join-and-sync.md)
- [Become a validator and stake](docs/guides/become-validator.md)
- [Key separation and hardening](docs/concepts/validator-key-hardening.md)
- [Seeds and peer discovery](docs/concepts/seeds.md)
- [Validator specifications](docs/reference/validator-specs.md)
- [Staking and voting power](docs/reference/staking.md)
- [Full documentation index](docs/README.md)

## Repository layout

| Path | Purpose |
| --- | --- |
| [`scripts/`](scripts/README.md) | Node, network, install, staking, and snapshot helpers |
| [`config/`](config/README.md) | Full node, RPC, and validator configuration templates |
| [`networks/`](networks/README.md) | Network genesis, seeds, and persistent peers |
| [`ops/`](ops/README.md) | Headscale and monitoring deployments |
| `bin/` | Local `lumend` binary downloaded by the installer |
