# PvP Pad

A token launchpad on Robinhood Chain (Arbitrum Orbit, chain id 4663) where every launch is a fast
"Spireth" dice game. All payments are in ETH. This job delivers contracts, tests and documentation only;
no website or URL is published (a later job builds the site).

**Legal review is required before any public launch.** The pad sells tokens on a bonding curve, runs a
paid game of chance with ETH prizes, and runs a crown auction. Whether this is lawful, and for whom, depends
on jurisdiction. Nothing here has been reviewed by counsel.

## Contracts (deploy order, one transaction)

| # | Contract       | Role                                                                      |
|---|----------------|---------------------------------------------------------------------------|
| 1 | `PadToken`     | EIP-1167 template of every launch token (1e9 supply, 18 decimals, locked until graduation) |
| 2 | `PadGame`      | EIP-1167 template: bonding curve + game of one launch                     |
| 3 | `PvPPad`       | Registry, clone factory, carry pot, failed-send escrow, open switch, global upkeep |
| 4 | `PadLiquidity` | Uniswap v4 graduation, locked LP positions, fee collection for the king, PvP burns |
| 5 | `KingOfThePad` | Crown auction; its constructor binds everything and creates the genesis launch |
| - | `LaunchToken`  | The IMD launch token "Pepe Values Pepe" (PVP), see below                  |

Constructor arguments: `PvPPad(owner, PadToken, PadGame)`, `PadLiquidity(PvPPad, PoolManager)`,
`KingOfThePad(PvPPad, PadLiquidity)`. `owner` is `$owner` = `0x5b95a971b4583a5f011e9da082acdd679b870d06`,
which is also the immutable `DEV` constant. The PoolManager is `0x8366a39cc670b4001a1121b8f6a443a643e40951`.
Constructors are nonpayable, never call ArbSys or the PoolManager, and only call earlier contracts of the
manifest (`setLiquidity`, `setKing`, `startGenesis`), each a one-shot binding. Each runtime is under 24,576
bytes; the full deployment including the genesis launch measures about 9.7M gas in tests (see docs/TEST-REPORT.md).

### Owner powers

The only owner power is `PvPPad.openPad()`. Until it is called every user action (`mint`, `roll`, `launch`,
`takeCrown`) reverts. The owner may call it at any time; anyone may call it 30 days after deployment. It can
never be undone and grants nothing else. There is no pause, upgrade, fee switch, sweep or parameter setter.

## How a launch works

1. **Launch**: `PvPPad.launch(name <= 32 bytes, ticker <= 10, imageURL <= 200)` by anyone, once the genesis
   launch (PvP) has graduated. It clones a token (1e9 supply minted to the game) and a game. The carry pot,
   if any, moves into the new game's pot.
2. **Signup**: the first `mint()` starts a 10 minute signup. Minting is free, one Imp per wallet, 200 max.
   Imps are records, not NFTs.
3. **Play**: from signup end until the bell, all Imps dead, or 60 minutes after the first mint.
   `roll()` costs exactly 0.002 ETH with a 60 s cooldown: 90% buys the curve for the roller, 8% goes to the
   pot, 2% to the burn bucket (the genesis game keeps its 2% in its pot). An Imp dies after 10 minutes
   without a roll (counted from play start if it never rolled).
4. **Curve**: virtual constant product with 1 ETH and 1e9 tokens virtual; 800M tokens are on the curve and
   sell out at exactly 4 ETH; 200M are reserved for the pool. Only rolls buy; there are no sells. When sold
   out, the roll's 90% goes to the pot.
5. **Dice**: `rand % 8` maps to -4..-1 and +1..+4. Height clamps at ±50; reaching it rings the bell and
   ends the game.
6. **RNG**: a roll stores its ArbSys commit block. The outcome is
   `keccak256(game, imp, nonce, arbBlockHash(c+1), arbBlockHash(c+2), arbBlockHash(c+3))`. Anyone resolves;
   every mint, roll and poke resolves up to 8 oldest pending rolls, and an Imp's roll resolves its previous
   one. A roll unresolved past the 256-block hash window resolves to 0.
7. **End**: living Imps are ranked by |height| descending, earlier `heightReachedAt` wins ties. The top
   `ceil(living/2)` split 80% of the pot with triangular weights (`paid - rank`), the bell ringer gets 20%
   (no bell: all to ranks; none living: carry pot). The sort is done once in memory (<= 200), payouts go out
   25 per call. The finalizer gets 0.5% of the pot, at most 0.005 ETH.
8. **Graduation** (permissionless, via `poke`): curve ETH plus the remaining tokens go into a Uniswap v4
   pool (native ETH / token, fee 10000, tickSpacing 200, no hooks) at the final curve price, full range,
   owned forever by `PadLiquidity`. Excess tokens go to `0x…dEaD`, the token unlocks inside the same
   transaction. If the pool was pre-initialized by someone else, a price-limited swap with the pad's own
   funds moves it to the target first. No ETH raised: all tokens are burned and the launch is marked failed.

**Genesis**: launch #1 "Pepes Value Pepes" (PvP) is created by `KingOfThePad`'s constructor and waits for
its first mint. Other launches revert until PvP has graduated (or failed).

**Burn**: burn-bucket ETH waits in `PadLiquidity` until PvP graduates; then anyone (or upkeep) buys PvP and
sends it to dEaD, at most 0.02 ETH per buy, one buy per 10 minutes. If the genesis launch failed (no pool
can exist), burn deposits are redirected to the carry pot instead of being stuck.

**King** (`KingOfThePad`, open after PvP graduates): `takeCrown()` payable, first bid >= 0.01 ETH, then
>= 110% of the current bid and only after the king held for 1 hour. The old king is refunded in full at once
(gas-capped push; a failed push is held in `PvPPad` and claimable). The extra (new - old; the whole first bid)
goes 50% equally to the pots of live games (max 10, soonest ending; none: carry pot), 25% to the burn bucket,
25% to dev. `distribute(n)` collects LP fees from the next n graduated pools round-robin, sells the token side
for ETH (1M tokens per pool per call) and sends everything to the current king. `takeCrown` distributes a
batch of 2 first. Fees reach the king at collection, not per swap.

**Upkeep**: every state-changing call runs bounded upkeep: resolve rolls, poke one active game round-robin
(finalize, pay a batch, graduate), distribute 2 pools, burn a chunk. Each step is gas-capped and best-effort
(a failing step never blocks the user's action). `PadGame.poke()` and `PvPPad.upkeep()` are public. No
off-chain keeper is required, but one may call `poke` / `upkeep` to speed things along.

## Safety design

- ETH pushes are gas-capped (30k); failures are escrowed in `PvPPad.claimable` and pulled with `claim()`.
- Reentrancy guards on every user entry point; checks-effects-interactions; all loops bounded
  (8 resolutions, 25 payments, 64 scanned games, 10 funded pots, n pools per distribute).
- Internal accounting (`pot`, `curveEth`, `burnBucket`, `carryPot`, `claimable`); no `transferFrom`.
- Uniswap v4 is only reached through `PoolManager.unlock` with the pad's own funds; `unlockCallback` only
  accepts the PoolManager.
- Timing in seconds uses `block.timestamp` (the sequencer clock); block ordering and randomness use ArbSys
  `arbBlockNumber` / `arbBlockHash` only. `block.number`, `blockhash` and `prevrandao` are never used.

## Assumptions and open items

- **Randomness** is derived from Arbitrum L2 block hashes. The sequencer (and a block builder) can influence
  them; this is a known limitation, documented in docs/AUDIT.md, acceptable only for the small stakes here.
- The genesis gate and burns assume PvP graduates. If nobody rolls in it within 60 minutes of its first mint,
  it fails, the gate opens anyway, and burns are redirected to the carry pot.
- The v4 pool is created with fee 10000 / tickSpacing 200 as the brief specifies; this is separate from the
  IMD launch pool of `LaunchToken` (see below).
- Finalizing a 200-Imp game sorts in memory and stores up to 100 winners; it is the heaviest call
  (~3M gas worst case) and fits the 3M upkeep cap only when poked directly, which anyone can do.

## The launch token

The IMD project launch deploys `src/LaunchToken.sol` as `LaunchToken`: "Pepe Values Pepe" (PVP), a plain
fixed-supply ERC-20 with 18 decimals and 1,000,000,000 tokens minted to the deployer (the factory), no owner,
mint, pause, blocklist, fee or upgrade. The factory splits that supply and seeds its own IMD-paired pool at the
policy fee; nothing in this repository is allocated any of it. The brief's genesis token "Pepes Value Pepes"
(ticker PvP) is a separate `PadToken` clone minted to the genesis game and sold through its curve. The two are
not the same token; the pad does not touch `LaunchToken`.

## After launch

- The owner calls `PvPPad.openPad()` when ready (anyone can after 30 days). Nothing else needs configuring.
- Verification steps: docs/VERIFY.md. Audit notes: docs/AUDIT.md. Test report: docs/TEST-REPORT.md.

## Development

```
forge build
forge test
forge fmt --check
```

Dependencies are vendored as plain files: `lib/forge-std` (1.17.0), `lib/v4-core/src` (Uniswap v4 core,
commit 46c6834, used both by `PadLiquidity` for internal libraries and by the tests for the real PoolManager),
and `lib/solmate/src/auth/Owned.sol` (required by v4-core). All library functions used are internal, so the
built bytecode has no link placeholders.
