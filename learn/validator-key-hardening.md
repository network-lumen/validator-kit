# Validator key separation & hardening on Lumen

This document explains **how validator keys are actually used**, **which ones matter for consensus**, and **why a production validator host should never hold account or application keys**.

This is not a generic Cosmos tutorial.

---

## Key types on a Lumen validator

A Lumen validator involves **multiple keys**, with **very different roles**.

Understanding this separation is critical for security.

### 1. Consensus key (critical)

- File: `config/priv_validator_key.json`
- Used by: **CometBFT**
- Purpose: **sign blocks and votes**
- Loaded: **at process start, kept in memory**
- Importance: **absolute**

This is the **only key that participates in consensus**.

---

### 2. Node identity key (P2P)

- File: `config/node_key.json`
- Purpose: identify the node on the P2P network
- Used for:
  - peer connections
  - node ID
- **Does not sign blocks**
- **Does not sign transactions**

Losing this key only changes the node’s network identity.

---

### 3. Account / application keys (non-consensus)

These include:

- `keyring-*` (Cosmos account keys)
- `pqc_keys` (Lumen PQC keystore)

They are used to:
- send transactions
- vote on governance
- submit messages
- perform administrative actions

**They are NOT used by the consensus engine.**

---

## What happens if a key is removed

This table summarizes **actual observed behavior**:

| Key removed | Immediate effect | Consensus impact |
|------------|------------------|------------------|
| `priv_validator_key.json` | signing failure / missed blocks | ❌ broken |
| `node_key.json` | new node ID | ✅ unaffected |
| `keyring-*` | none | ✅ unaffected |
| `pqc_keys` | none | ✅ unaffected |

If a consensus key is removed or corrupted, **the validator fails immediately**, even **without restarting the process**.

There is no delayed failure mode.

---

## Why scrubbing account keys is a best practice

A production validator host should:

- sign blocks
- relay consensus messages
- **nothing else**

Keeping account or application keys on a validator host:

- increases attack surface
- enables fund theft if the host is compromised
- allows malicious governance actions
- provides no operational benefit

**A hardened validator host should not be able to create transactions.**

---

## Recommended hardening model

On Lumen:

- consensus keys stay on the validator host
- account / PQC keys are:
  - stored offline
  - or on a separate operator machine
- validator hosts are:
  - non-custodial
  - consensus-only

This significantly reduces the blast radius of a compromise.

---

## Scrubbing keys safely

When decommissioning or hardening a validator host, it is safe to remove:

- `keyring-*`
- `pqc_keys`

As long as:
- `priv_validator_key.json` is untouched
- `node_key.json` is untouched

The validator will:
- keep producing blocks
- remain part of the active set
- be unable to send transactions

---

## Common misconceptions

---

***“All validator keys are the same”***

No.

Only **one** key signs blocks.

The others are convenience keys that do not belong on a hardened host.

---

***“Validators need account keys to operate”***

No.

Validators need:
- a consensus key
- a network connection
- stable infrastructure

Everything else is optional and often harmful.

---

## Lumen position

On Lumen:

- validator security is prioritized over convenience
- operators are encouraged to harden hosts early
- clear separation of responsibilities is expected
