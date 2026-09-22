# Testnet

The Lumen testnet chain ID is `lumen-testnet`.

This directory is the intended location for the testnet `genesis.json`,
`seeds.txt`, and `peers.txt`. Those inputs are not included in the current
checkout, and the join scripts explicitly use `networks/mainnet/` until the
testnet files and network selection support are added. Never use mainnet
genesis or peer data to join testnet.
