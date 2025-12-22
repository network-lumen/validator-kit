This thread describes the high-level process.
Technical setup details are covered in the validator kit README.

────────────────────────────

**:one: Review requirements**
Before applying, make sure you meet the baseline infrastructure expectations:
- validator & sentry specs
- security model
- uptime & monitoring

────────────────────────────

**:two: Set up a full node**
- Install and run a Lumen full node
- Sync and keep it healthy
- No delegation at this stage

This step is about familiarity and reliability.

────────────────────────────

**:three: Join as a validator candidate**
- Upgrade your node to validator mode
- Configure sentries correctly
- Share your validator details when requested (moniker, contact, infra summary)

────────────────────────────

**:four: Observation period**
- Node is observed over time
- Focus on:
  - uptime & signing
  - correct sentry isolation
  - responsiveness
- No guarantees, no fixed duration

────────────────────────────

**:five: Voting power & eligibility**

Voting power grows organically based on network participation.
No active delegation program is guaranteed.

Validators are expected to:
- maintain correct behavior
- follow network rules
- remain eligible participants

────────────────────────────

**Notes:**
- Running a validator is a long-term commitment
- Stability and operational discipline matter more than hardware
- Technical guides: see [the validator kit README](https://github.com/network-lumen/validator-kit/blob/master/README.md)