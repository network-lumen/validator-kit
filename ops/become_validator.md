This document gives the practical, single, supported path to promote a synced
full node into a Lumen validator using the validator kit.

It assumes:
- you are running a full node created via `./join.sh`, and
- the node is fully synced and stable.

For the full context and safety notes, see the validator kit root `README.md`.

────────────────────────────

**:one: Join and sync as a full node**

From the repo root:

```bash
./join.sh <moniker> [--public-api]
```

Then:
- wait for the node to sync fully, or
- optionally configure state sync via `ops/scripts/network/state_sync.sh` as documented in the root README.

At this stage the node is **not** a validator and does not hold PQC validator keys.

────────────────────────────

**:two: Create / import the validator wallet**

On the node host, create or import the `validator` key:

```bash
lumend keys add validator --home ~/.lumen --keyring-backend test
# OR, to import an existing mnemonic:
lumend keys add validator --home ~/.lumen --keyring-backend test --recover
```

Write the mnemonic down and store it offline before continuing.

Fund this address with LMN:

```bash
lumend keys show validator -a --home ~/.lumen --keyring-backend test
```

────────────────────────────

**:three: Promote the node to validator**

From the repo root:

```bash
HOME_DIR=~/.lumen FROM=validator \
  ops/scripts/blockchain/become_validator.sh --moniker "<public-validator-name>"
```

This helper will:
- ensure a PQC key `validator-pqc` exists locally (and generate it if needed),
- link the PQC account on-chain,
- derive the consensus pubkey from `lumend tendermint show-validator`,
- broadcast `tx staking create-validator` with a minimal self-delegation,
- optionally create a structured backup under `~/.lumen/validator-node.bak`
  (including metadata, PQC keystore, keyring and optional mnemonic file).

After this step, the node is a validator and will start signing blocks
according to the network’s rules.

────────────────────────────

**:four: Stake additional tokens (optional, separate step)**

To increase your validator voting power, use the staking helper:

```bash
HOME_DIR=~/.lumen FROM=validator \
  ops/scripts/blockchain/stake_tokens.sh --amount <NUMulmn>
```

This script will:
- refuse to run if the address is not already a validator on-chain, or
- if the PQC account is not linked on-chain.

It then broadcasts a `staking delegate` transaction from your validator account
to your own validator.

────────────────────────────

**:five: Operational expectations**

Validators are expected to:
- maintain stable infrastructure and monitoring,
- keep sentry and validator separation as documented in `validator_specs.md`,
- keep backups of both Ed25519 and PQC keys **off-host**.

For staking economics, slashing and bootstrap phases, see `ops/stake_bootstrap.md`.
