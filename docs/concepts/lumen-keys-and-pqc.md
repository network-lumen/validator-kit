# Lumen Keys and PQC Identity

Lumen validator operation uses several separate identities. They are not
interchangeable, and a blockchain snapshot is not a complete validator backup.

## Identity Map

| Material | Purpose | Location | Backup | Sensitivity and recovery |
| --- | --- | --- | --- | --- |
| Account key / keyring | Funds and account transactions | `$LUMEN_HOME/keyring-*` | Yes, encrypted/off-host | Controls funds and transaction authority; protect the mnemonic and keyring password. |
| PQC private key | Lumen Dilithium3 transaction/validator identity | `$LUMEN_HOME/pqc_keys` | Yes, encrypted/off-host | Required for Lumen PQC operations; treat as account-sensitive material. |
| Consensus private key | CometBFT block and vote signing | `$LUMEN_HOME/config/priv_validator_key.json` | Yes, with a reviewed recovery plan | Keep on exactly one active validator. Reuse can cause double signing and slashing. |
| Signing state | Last signed height/round/step | `$LUMEN_HOME/data/priv_validator_state.json` | Yes, carefully | Safety-critical state. Do not casually reset, restore stale copies, or combine with another active validator. |
| Node key | P2P node identity | `$LUMEN_HOME/config/node_key.json` | Recommended | Losing it changes the node identity but does not sign consensus messages. |

`config/priv_validator_key.json` is the consensus identity. Account and PQC
keys are application/transaction identities. `node_key.json` identifies the
P2P node. The separation is why a hardened validator can remove account keys
after securely backing them up while retaining consensus operation; see
[validator key hardening](validator-key-hardening.md).

## PQC Lifecycle

The account must exist and be funded before validator registration. The
current `become_validator.sh` workflow is:

1. Use the configured `file` or `os` keyring; never use `test` for mainnet.
2. Check for the `validator-pqc` key and prompt to generate it if absent.
3. Read its public key with `keys pqc-show`.
4. Query the account’s existing PQC association.
5. If needed, broadcast `lumend tx pqc link-account` with `--scheme dilithium3`.
6. Read the consensus public key with `tendermint show-validator`.
7. Broadcast `staking create-validator` using `--pqc-from` and `--pqc-key`.

Run the supported workflow from the repository root:

```bash
KEYRING=file HOME_DIR="$LUMEN_HOME" BIN="$LUMEND" FROM=validator \
  ./scripts/blockchain/become_validator.sh --moniker hamster-validator
```

Ordinary account creation does not automatically create or link the PQC key;
that is a separate Lumen-specific lifecycle step. The helper asks whether to
create an on-host `validator-node.bak`; export it off-host and store it
securely. It does not write the mnemonic or signing state into that backup.

## Recovery Rules

Back up account and PQC material separately from consensus recovery material.
Do not copy a consensus key to a sentry, restore a validator snapshot over a
live home, or start two validators with the same consensus identity. Snapshot
restore preserves local signing state when present and refuses routine
validator recovery when it is missing, but it is still not a replacement for
an operator-reviewed validator recovery plan.
