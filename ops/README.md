# Operations deployments

This directory contains deployment stacks that complement a Lumen node:

- [Headscale](headscale/README.md) connects validators and sentries over a
  private network. Its Compose files and run scripts are under `headscale/`.
- [Monitoring](monitoring/README.md) provides Prometheus, Grafana, and an Nginx
  proxy. Its Compose files, dashboards, and configuration are under `monitoring/`.

Node setup, staking, peer management, and snapshots are under
[`scripts/`](../scripts/README.md). Operator guides and background information
are under [`docs/`](../docs/README.md). The network's genesis and peer lists
are under [`networks/`](../networks/README.md).
