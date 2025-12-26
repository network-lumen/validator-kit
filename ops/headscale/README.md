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

## TLS certificates and trusting a self-signed CA

For production you should use a proper certificate (e.g. via Let's Encrypt),
but for private setups it is often enough to use a self-signed certificate and
trust it explicitly on your nodes.

On the Headscale host (your control-plane machine), from the repo root:

```bash
cd deploy/headscale
mkdir -p proxy/certs
openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
  -subj "/CN=headscale.example.com" \
  -keyout proxy/certs/privkey.pem \
  -out proxy/certs/fullchain.pem
```

This is what the tooling in this repo expects by default (`nginx.conf` points
to `/etc/nginx/certs/fullchain.pem` and `/etc/nginx/certs/privkey.pem`, which
are bind-mounted from `proxy/certs/` by docker-compose).

On each validator / sentry node you then need to trust this CA certificate so
that `tailscale up --login-server https://headscale.example.com` does not fail with
`certificate signed by unknown authority`. On Debian/Ubuntu-like systems:

```bash
scp deploy/headscale/proxy/certs/fullchain.pem user@node:/tmp/headscale-ca.pem
ssh user@node
sudo cp /tmp/headscale-ca.pem /usr/local/share/ca-certificates/headscale.crt
sudo update-ca-certificates
sudo systemctl restart tailscaled
```

After this, `curl https://headscale.example.com/health` from the node should succeed
*without* using `-k`, and `tailscale up` should connect cleanly to Headscale.

## Backing up and restoring Headscale state

Headscale stores all its state (users, nodes, keys, DERP/private keys, etc.)
in the Docker volume `headscale-data`. You should back this up after you have
finished configuring your network, and whenever you make important changes
(adding/removing nodes, changing ACLs).

From `deploy/headscale` you can take a snapshot into a directory of your choice
(ideally an offline USB key or an encrypted folder):

```bash
cd deploy/headscale
./run/backup.sh                    # saves into ./backups/
./run/backup.sh /media/usb/lumen   # custom target folder
```

This stops Headscale for a few seconds, tars the volume into a file like:

- `headscale_state_YYYYMMDD_HHMMSS.tar.gz`

To restore on the same machine or a new one:

```bash
cd deploy/headscale
./run/restore.sh /media/usb/lumen/headscale_state_YYYYMMDD_HHMMSS.tar.gz
```

This will:
- stop the `headscale` service
- wipe the `headscale-data` volume and restore the archive contents
- start `headscale` again with the restored state

As long as you keep the same `server_url` in `config/config.yaml` and point
DNS for that hostname to the new machine, your existing nodes will reconnect
using the restored control-plane.


```bash
./run/init.sh --user lumen --sentries 2
```

This will:
- ensure the `lumen` user exists
- generate one auth key for the validator
- generate 2 auth keys for sentry nodes

All keys are written to a timestamped file in `deploy/headscale/`.
