# Headscale for Lumen validators

This folder provides a minimal, self-contained Headscale setup to create a private
mesh network between your **validator** and one or more **sentry** nodes.

The goal is:
- validator is **never** directly exposed to the Internet
- sentry nodes are public-facing and only talk to the validator via Headscale

## Quick start (local test)

From the repo root, on the machine where your Headscale server will run
and as the Headscale operator account:

```bash
cd deploy/headscale
./run/up.sh                 # starts Headscale via docker-compose
./run/init.sh               # creates auth keys (1 validator, 1 sentry)
```

Optional: to customize ports / URL, copy the example:

```bash
cp .env.example .env
# then edit .env to change HEADSCALE_* values
```

The compose setup will:
- start a `headscale` container
- mount config from `deploy/headscale/config/config.yaml`
- store database and keys in a Docker volume (`headscale-data`)

To stop Headscale:

```bash
cd deploy/headscale
./run/down.sh
```

## Configuration

- General knobs (ports, public URL) live in `.env`
- Detailed Headscale behaviour lives in `config/config.yaml`

For production you will typically:
- point `HEADSCALE_SERVER_URL` (and `server_url` in `config/config.yaml`)
  to a public hostname with HTTPS reverse proxy in front of Headscale
- keep the validator reachable **only** over the Headscale network

## Initialising users and keys

Use `run/init.sh` to create a Headscale user/namespace and pre-auth keys.
Run this as your Headscale administrator account — it will output all auth
keys into a local file, which you should keep private and from which you
then distribute individual keys to validator / sentry operators:

```bash
./run/init.sh --user lumen --sentries 2
```

This will:
- ensure the `lumen` user exists
- generate one auth key for the validator
- generate 2 auth keys for sentry nodes

All keys are written to a timestamped file in `deploy/headscale/`.
