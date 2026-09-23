# Snapshot recovery

Snapshot restore is **blockchain data recovery**, not validator migration or
consensus-key recovery. Run it against a stopped node or let the helper stop
and verify the configured service:

```bash
./scripts/snapshot/restore_snapshot.sh \
  --home "$HOME/.lumen" \
  --snapshot "$HOME/snapshots/block_123_1.tar.gz"
```

Remote HTTPS snapshots are supported. The helper downloads to temporary
storage, validates the archive structure and `snapshot.json` SHA256, stages the
archive, rejects traversal and special-file entries, and only then changes the
node. Without a trusted provider checksum, integrity is limited to the
published in-archive hash and structural validation.

The restore replaces `data/` blockchain state. It preserves `config/`,
`node_key.json`, `priv_validator_key.json`, role metadata, keyrings, and PQC
material. Existing `data/priv_validator_state.json` is copied byte-for-byte
back into restored data; snapshot-provided signing state is never used.
Validator roles and nodes containing a consensus key must already have local
signing state, otherwise the operation fails safely.

An active `lumend` service is stopped and verified inactive before replacement,
then restarted only if it was active before restore. Failures leave the
service stopped and report the safety-backup location. Backups are created
under the snapshot directory as `recovery-safety-*`, with mode `0700` for
directories and `0600` for files. These are rollback-safety backups, not a
complete off-host validator disaster-recovery backup.

After a successful restore, run:

```bash
./scripts/doctor.sh --home "$HOME/.lumen"
```

Moving a validator to another machine is separate. The old validator must stop
signing before its consensus identity is activated elsewhere. This phase does
not automate migration or reconstruct signing state.
