# Lumen monitoring stack (sentry)

This folder contains a minimal Prometheus + Grafana stack intended to run
on a sentry node. The goal is to monitor a **validator** over the private
Headscale/Tailscale network, while exposing Grafana securely.

## Quick start

On a sentry host that already runs a fullnode:

```bash
cd deploy/monitoring
cp .env.example .env              # optional: adjust ports / admin user
vim prometheus.yml                # set VALIDATOR Headscale IP
docker compose up -d
```

This will:
- start Prometheus (scraping the validator's `/metrics` endpoint)
- start Grafana, with login from `.env`
- expose Grafana via an Nginx reverse proxy:
  - HTTP on `GRAFANA_HTTP_PORT` (default 3000)
  - IP whitelisting configured in `nginx.conf`

## Alerting

- This stack does not ship any preconfigured alert rules or external alerting targets.
- Configure alerts yourself in Prometheus/Grafana (for example via the UI) based on your own needs and metrics.

## Security notes

- Authentication:
  - Grafana uses its own login (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`)
  - change these defaults before exposing anything to the Internet
- IP whitelist:
  - edit `nginx.conf` and replace the `allow` lines with your own IPs/CIDRs
  - everything not explicitly allowed is denied
- Validator exposure:
  - the validator should only expose its metrics port over the private
    Headscale network (e.g. bind to `0.0.0.0:26660` on a host that is
    **not** reachable from the public Internet, or with firewall rules).
