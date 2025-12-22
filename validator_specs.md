This document provide clear, minimal expectations for validators and sentry operators joining the Lumen network.
No over-engineering required — stability and correctness first.

────────────────────────────

**:white_check_mark: Validator node (recommended baseline)**
- CPU: 4–8 cores (modern x86_64)
- RAM: 16–32 GB
- Storage: NVMe SSD ≥ 1 TB
- OS: Linux (Ubuntu 22.04 LTS or equivalent)

**Network:**
- Stable connection
- Public exposure only via sentries
- Uptime target: ≥ 99%

**Security**
- **Validator must not be publicly reachable**
- **Only sentry IPs allowed (firewall enforced)**
- **Private keys never leave the validator**
- **Regular system updates**

────────────────────────────

**:shield: Sentry node (per validator)**
- CPU: 2–4 cores
- RAM: 8–16 GB
- Storage: SSD ≥ 500 GB

**Network:**
- Public IP
- Open Tendermint P2P port (26656)

**Role:**
- Accept inbound peers
- Forward traffic to the validator

**Notes**
*2 sentries per validator recommended (geo-separated if possible)*
*Validators may operate their own sentries or outsource them*

────────────────────────────

**:closed_lock_with_key: Networking rules (mandatory)**

**Validator:**
- :x: No public P2P
- :white_check_mark: Accept traffic only from own sentries

**Sentries:**
- :x: Never expose validator RPC
- :white_check_mark: P2P only

Optional: Private overlay (WireGuard / Tailscale) allowed

────────────────────────────

**:package: Backups & ops (expected)**

- Validator keys backed up offline
- Snapshot strategy recommended (local or remote)
- Monitoring
