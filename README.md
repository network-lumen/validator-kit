# Lumen deployment toolbox

# ⚠️ CRITICAL VALIDATOR WARNING – READ FIRST ⚠️

## 🚨 KEY BACKUP REQUIREMENT (ED25519 + PQC)

**Validators MUST backup BOTH cryptographic keys:**
- ✅ **ed25519 key** (classic Cosmos key)
- ✅ **PQC key (Dilithium)**

👉 **If you lose ONE of them, you LOSE ACCESS TO YOUR FUNDS.**

---

## ❌ DO NOT DO THIS
- ❌ Do NOT delete your node without backing up **BOTH** keys  
- ❌ Do NOT reinstall / redeploy / wipe `.lumen` blindly  
- ❌ Do NOT assume PQC keys can be regenerated  
- ❌ Do NOT assume there is an override, reset, or admin recovery  

**THERE IS NO PQC KEY OVERRIDE.  
THERE IS NO ADMIN RESET.  
THERE IS NO FUND RECOVERY.**

**Store all backups OFF the server. Losing them = losing funds.**

---

## Join the network (root workflow)

For most operators, the flow is:

```bash
git clone https://github.com/network-lumen/validator-kit.git
cd validator-kit
./join.sh <moniker> [--rpc http://trusted:26657] [--public-api]
```

- `./join.sh` uses the toolkit to:
  - initialize a `.lumen` home (or the one specified via `--home` / `LUMEN_HOME`),
  - copy templates from `config/`,
  - install and start a `lumend` systemd service.

### Bootstrap modes

- With `--rpc http://trusted:26657` – state sync is configured against this RPC before the first start.
- Without `--rpc` – no state sync is configured; the node syncs via `config/seeds.txt` + PEX (classic blocksync).

### Becoming a validator

There is deliberately **no** “init validator” script on an already-running network.

1. First join and sync via `./join.sh`.  
2. Then follow the procedure in `ops/become_validator.md` (tx `staking create-validator`, etc.).

### Important files

- `bin/` – `lumend` binary used by the scripts (see `ops/README.md` for how to download it).
- `config/` – configuration templates:
  - `validator/` – validator,
  - `fullnode/` – fullnode / sentry,
  - `genesis.json`, `seeds.txt`, `peers.txt`.
- `ops/` – operator toolbox (scripts, Headscale, monitoring, advanced docs).

For network bootstrap (`init_chain`), snapshots, Headscale, monitoring, or advanced tuning, see `ops/README.md`.
