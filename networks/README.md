# Network data

Each network directory is intended to hold its genesis, seed list, and
persistent peer list. These files are operational inputs, not documentation.

- [`mainnet/`](mainnet/README.md) is configured and used by the current scripts.
- [`testnet/`](testnet/README.md) is reserved; no genesis or peers are supplied.
- [`devnet/`](devnet/README.md) is reserved; no genesis or peers are supplied.

The current scripts explicitly use `networks/mainnet/`. Adding assets to a
reserved directory does not automatically enable that network; network
selection and validation need to be implemented before either can be joined.
