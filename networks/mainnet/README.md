# Mainnet

`genesis.json` defines the Lumen chain with `chain_id: lumen`. `seeds.txt`
contains discovery nodes and `peers.txt` contains persistent peers for
non-seed nodes. Node setup reads these files and copies `genesis.json` into
the node home; it does not run directly against the repository file.

Changes to genesis or peer lists affect new joins and peer reloads. Review
them as operational network changes.
