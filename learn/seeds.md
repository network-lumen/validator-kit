# Seeds on Lumen

This document explains **what a seed node is supposed to do on Lumen**, and just as importantly, **what it is NOT supposed to do**.

This is not a copy-paste tutorial.
It is meant to clarify the expected behavior of a seed in order to support real network decentralization.

---

## What a seed is (and is not)

### A seed **is**
- A **P2P bootstrap helper**
- A node that helps **new peers discover each other**
- A relay for **addrbook (PEX gossip)**

### A seed **is NOT**
- A validator
- A sentry
- A full node
- A reliable peer to stay connected to
- A block producer or state authority

A seed **does not participate in consensus** and **does not need to follow the chain**.

---

## Mental model

Think of a seed as a **temporary meeting point**.

- Node A connects to the seed
- Node B connects to the seed
- The seed notices both
- The seed shares their addresses
- Connections are closed
- Nodes talk directly to each other

That’s it.

The seed should **disappear from the picture** once peer discovery is done.

---

## Expected behavior

### Network
- Listens on **TCP 26656**
- Accepts short-lived inbound connections
- Closes connections quickly after address exchange

### Logs you should expect
These logs are **normal** for a seed:

```
Starting PEX service
Starting AddrBook service
Saving AddrBook size=0
Inbound Peer rejected err="auth failure: handshake failed: EOF"
```

They usually mean:
- a peer connected
- handshake ended early
- address gossip still happened

This is **not an error**.

---

## Configuration expectations

### `config.toml`

A correctly configured seed should have:

```
seed_mode = true
persistent_peers = ""
seeds = ""
pex = true
indexer = "null"
```

RPC must not be exposed:

```
[rpc]
laddr = ""
Local RPC bound to 127.0.0.1 is acceptable but unnecessary.
```

All application-level APIs should be disabled:

```
[api]
enable = false

[grpc]
enable = false

[grpc-web]
enable = false
```

## Ports
A seed should expose only one port:

- ✅ 26656/tcp (P2P)
- ❌ 26657 (RPC)
- ❌ 1317 (API)
- ❌ 9090 (gRPC)

Check with:

```
ss -lntp | grep lumend
```

## Common misconceptions

*“My seed is syncing, that means it works”*

**A seed syncing the chain is:**

- harmless
- unnecessary
- not its purpose
- seed_mode = true does not mean “minimal node”.

It only changes PEX behavior.

*“A seed should be a stable peer”*

**No.**
- A seed should not be relied upon as a persistent connection.
- If nodes depend on a seed to stay connected, something is wrong.

*“Seed + validator on the same machine is fine”*

**No.**

Running a seed on the same host as:

- a validator
- a sentry
- or a full node

creates:

- identity confusion
- addrbook pollution
- potential feedback loops

**A seed should be isolated.**

## How to test a seed (recommended)

- Start the seed with an empty addrbook
- Join a new node using only this seed
- Watch the seed logs

You should observe:

- inbound connection
- handshake
- connection close
- addrbook size increasing

Example:

```
Saving AddrBook size=1
Saving AddrBook size=2
```

If this happens, the seed is doing its job.

## Why this matters for decentralization

Without properly understood seeds:

- network bootstrap depends on a few well-known nodes
- new operators struggle to join
- the network silently centralizes at the P2P layer

**Seeds are not about performance.**
They are about independent entry into the network.

## Lumen position

On Lumen:

- seeds are intentionally simple
- seeds are disposable
- understanding their role matters more than over-optimizing them

If something feels confusing about seeds, it usually means the concept itself was not clearly explained upstream.

This document exists to fix that.