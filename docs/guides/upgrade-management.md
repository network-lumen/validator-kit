# Upgrade management

Validator-kit supports two explicit service modes:

```text
direct      systemd -> lumend
cosmovisor  systemd -> cosmovisor -> lumend
```

Direct mode remains the default. Existing direct services are never silently
converted. Render a unit for review with `--print-unit`; install Cosmovisor
mode only with explicit intent:

```bash
./scripts/install/lumend_service.sh --print-unit \
  --mode cosmovisor --cosmovisor-bin /usr/local/bin/cosmovisor \
  "$HOME/.lumen" "$USER"
sudo ./scripts/install/lumend_service.sh --mode cosmovisor \
  --cosmovisor-bin /usr/local/bin/cosmovisor --force \
  "$HOME/.lumen" "$USER"
```

Cosmovisor expects the standard layout:

```text
$LUMEN_HOME/cosmovisor/genesis/bin/lumend
$LUMEN_HOME/cosmovisor/upgrades/<upgrade-name>/bin/lumend
```

Validator-kit does not install Cosmovisor. Install and pin the Cosmovisor
binary separately, verify its source and version, and pass its path explicitly
or make it available on PATH.

Prepare a binary before the governance upgrade height:

```bash
./scripts/upgrade/prepare_upgrade.sh \
  --home "$HOME/.lumen" --name upgrade-name --version v1.6.0
```

Preparation reuses the verified downloader, validates architecture, checksum,
and version, and publishes only a complete target directory. It does not stop
the node, restart services, watch heights, alter data, or touch validator
signing state. Cosmovisor performs the transition at the upgrade height.

Inspect readiness with:

```bash
./scripts/upgrade/status_upgrade.sh --home "$HOME/.lumen"
./scripts/doctor.sh --home "$HOME/.lumen"
```

Pre-upgrade cancellation is limited to explicit removal or replacement of
staged material that has not executed. A failed transition requires inspecting
Cosmovisor and service logs; validator-kit does not substitute an older binary
automatically. After a chain migration, using the previous binary is not a
generic rollback and requires chain-specific recovery. No blockchain state or
validator signing-state rollback is implemented.

Fresh deployment integration remains deferred: review genesis binary layout,
service setup, and Doctor behavior before making Cosmovisor the default. This
belongs to the later deployment review, not this phase.
