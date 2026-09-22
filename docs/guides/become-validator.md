# Become a Lumen validator

This guide starts with a healthy, synchronized node created by the
[join workflow](join-and-sync.md). Run commands from the repository root on
the node host. The join step alone does not create a validator.

## 1. Create or import an account

Use the encrypted `file` keyring on a headless validator host. It prompts for
a keyring password when keys are created or used. A configured `os` keyring is
also suitable where the host provides a secure OS credential store. Never use
the unencrypted `test` backend for mainnet funds or validator operations.

```bash
lumend keys add validator --home ~/.lumen --keyring-backend file
# To recover an existing account instead:
lumend keys add validator --home ~/.lumen --keyring-backend file --recover
```

Store the mnemonic securely outside the validator host. The helper will ask you
to confirm that it is stored offline, but will not ask you to paste it or write
it into a local backup file. Fund the address returned by:

```bash
lumend keys show validator -a --home ~/.lumen --keyring-backend file
```

## 2. Promote the node

```bash
KEYRING=file HOME_DIR=~/.lumen FROM=validator \
  ./scripts/blockchain/become_validator.sh --moniker "<public-validator-name>"
```

The helper ensures a `validator-pqc` key exists, links the PQC account on
chain, obtains the node's consensus public key, and broadcasts a validator
creation transaction with minimal self-delegation. It can optionally create
`~/.lumen/validator-node.bak`, containing account/PQC keys, consensus and node
keys, and configuration metadata. The directory is restricted to the owner;
export it off-host and store it securely. It does not contain the mnemonic or
validator signing state.

The consensus key is highly sensitive and must remain on exactly one active
validator. `priv_validator_state.json` is safety-critical signing state, not an
ordinary backup file; do not restore stale state without an operator-reviewed
recovery plan.

Keep `~/.lumen/config/priv_validator_key.json` on exactly one running
validator. See [key separation](../concepts/validator-key-hardening.md) and
[validator topology](../reference/validator-specs.md) before hardening the host.

## 3. Delegate additional stake

After confirming the validator exists on chain and its PQC account is linked:

```bash
KEYRING=file HOME_DIR=~/.lumen FROM=validator \
  ./scripts/blockchain/stake_tokens.sh --amount <NUMulmn>
```

The helper delegates from the validator account to its own validator. See
[staking and voting power](../reference/staking.md) for background.
