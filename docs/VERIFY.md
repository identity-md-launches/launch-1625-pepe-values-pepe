# Verifying the deployed contracts on robin.etherscan.io

The launch deploys the five contracts below from the bytecode built by this repository, in this order,
in a single transaction. Nothing is called after deployment; the open switch is the only post-launch action.

| # | Solidity name  | File                   | Constructor args (in order)                      |
|---|----------------|------------------------|--------------------------------------------------|
| 1 | PadToken       | src/PadToken.sol       | none                                             |
| 2 | PadGame        | src/PadGame.sol        | none                                             |
| 3 | PvPPad         | src/PvPPad.sol         | owner, PadToken address, PadGame address         |
| 4 | PadLiquidity   | src/PadLiquidity.sol   | PvPPad address, PoolManager address              |
| 5 | KingOfThePad   | src/KingOfThePad.sol   | PvPPad address, PadLiquidity address             |

Fixed values on Robinhood Chain (chain id 4663):

- owner: `0x5b95a971b4583a5f011e9da082acdd679b870d06` (also the immutable `DEV` constant)
- Uniswap v4 PoolManager: `0x8366a39cc670b4001a1121b8f6a443a643e40951`
- ArbSys precompile: `0x0000000000000000000000000000000000000064` (constant in PadGame)

## Compiler settings (must match exactly)

From `foundry.toml`:

```
solc = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = false
bytecode_hash = "none"
cbor_metadata = false
```

## Steps

1. Build locally: `forge build`. The runtime bytecode in `out/<File>.sol/<Name>.json` (`deployedBytecode`)
   must equal the code at the deployed address (`cast code <addr> --rpc-url <robinhood rpc>`), byte for byte,
   because no metadata hash is appended.
2. On https://robin.etherscan.io open each address, choose "Verify and Publish", "Solidity (Standard JSON
   Input)", compiler v0.8.26, licence MIT.
3. Produce the standard JSON with `forge verify-contract --show-standard-json-input <addr> <File>:<Name>` and
   upload it; or run the verification directly:

```
forge verify-contract --chain-id 4663 --verifier etherscan \
  --verifier-url https://api.robin.etherscan.io/api \
  --compiler-version v0.8.26 --num-of-optimizations 200 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" <owner> <PadToken> <PadGame>) \
  <PvPPad address> src/PvPPad.sol:PvPPad
```

   Repeat per contract with its own constructor signature (PadToken and PadGame take none; PadLiquidity is
   `constructor(address,address)`; KingOfThePad is `constructor(address,address)`).
4. The genesis launch's token and game are EIP-1167 minimal proxies created by KingOfThePad's constructor. On
   the explorer, mark them as proxies of PadToken / PadGame ("More options" > "Is this a proxy?"), so their
   ABI resolves. Their addresses are read from `PvPPad.genesisToken()` and `PvPPad.genesisGame()`.
5. Sanity reads after verification: `PvPPad.owner()`, `PvPPad.DEV()`, `PvPPad.liquidity()`, `PvPPad.king()`,
   `PvPPad.launchCount()` (1), `PadLiquidity.manager()`, `PadLiquidity.kingContract()`.

This job never deploys, broadcasts, or calls an RPC; the commands above are for the launch operator.
