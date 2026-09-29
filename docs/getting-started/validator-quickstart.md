# Validator Quickstart

This is the shortest path from a prepared Linux host to a Lumen validator. It
assumes the operator controls the host, has a trusted funding path, and will
keep account and recovery material outside the validator host where practical.
For prerequisites and the manual equivalent, see [manual deployment](../guides/manual-deployment.md).

## 1. Deploy

```bash
git clone <validator-kit-url>
cd validator-kit
export LUMEN_HOME="${LUMEN_HOME:-$HOME/.lumen}"
./scripts/lumen-node deploy hamster-validator --role validator --home "$LUMEN_HOME"
```

Fresh deployment uses Cosmovisor by default, installs the verified `lumend`
binary, applies the validator profile, copies mainnet genesis/peer data, and
installs a systemd unit running as the node user. Add `--rpc URL` only when a
trusted RPC endpoint is available for validated state sync.

## 2. Check the node

```bash
./scripts/lumen-node doctor --home "$LUMEN_HOME"
curl -fsS http://127.0.0.1:26657/status | jq '.result.sync_info'
```

Wait until `catching_up` is `false`. Do not create a validator while the node
is still synchronizing.

## 3. Create and fund the account

```bash
export LUMEND="${LUMEND:-$PWD/bin/lumend}"
"$LUMEND" keys add validator --home "$LUMEN_HOME" --keyring-backend file
"$LUMEND" keys show validator -a --home "$LUMEN_HOME" --keyring-backend file
```

Store the mnemonic offline, then fund the displayed address. The `file`
keyring is password-protected; never use the `test` backend for mainnet funds.

## 4. Register and verify

```bash
KEYRING=file HOME_DIR="$LUMEN_HOME" BIN="$LUMEND" FROM=validator \
  ./scripts/blockchain/become_validator.sh --moniker hamster-validator
```

The helper generates or checks the `validator-pqc` key, links its Dilithium3
public identity to the account, and submits `create-validator` with minimal
self-delegation. Confirm the resulting validator and PQC association:

```bash
ACCOUNT="$($LUMEND keys show validator -a --home "$LUMEN_HOME" --keyring-backend file)"
VALOPER="$($LUMEND keys show validator --bech val -a --home "$LUMEN_HOME" --keyring-backend file)"
"$LUMEND" q pqc account "$ACCOUNT" --node http://127.0.0.1:26657
"$LUMEND" q staking validator "$VALOPER" --node http://127.0.0.1:26657
```

Additional delegation is optional:

```bash
KEYRING=file HOME_DIR="$LUMEN_HOME" BIN="$LUMEND" FROM=validator \
  ./scripts/blockchain/stake_tokens.sh --amount <NUMulmn>
```

## 5. Recover safely

Create and export the validator recovery backup:

```bash
./scripts/lumen-node backup export "$LUMEN_HOME" "$HOME/snapshots" "$HOME/exports"
```

Back up the account mnemonic/keyring, PQC private material, consensus key, and
signing state according to [Lumen keys and PQC](../concepts/lumen-keys-and-pqc.md).
Never run the same consensus key on two active validators. Snapshots contain
blockchain data, not a complete validator recovery identity.

For ongoing operations, use [upgrade management](../guides/upgrade-management.md)
and [snapshot recovery](../guides/snapshot-recovery.md). Snapshot creation is
not currently exposed as `lumen-node snapshot create`.
