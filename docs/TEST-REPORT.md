# Test report

Toolchain: forge 1.8.3, solc 0.8.26 (pinned), evm cancun, optimizer 200 runs. Command: `forge test`.
Result: 62 tests, 62 passed, 0 failed, 0 skipped. `forge build` and `forge fmt --check` pass. The reviewers'
proof tests for the pre-initialized pool (`Proof_80d7c387603e.t.sol`, amount variant) and for its gas variant
(`Proof_fa4bd5e14850.t.sol`: 2,000 parked ticks, the graduating poke now costs 799,109 gas), run from
`test/scratch/`, pass as well.

The Uniswap v4 PoolManager used in tests is the real `v4-core` PoolManager (vendored under `lib/v4-core`,
commit 46c6834). ArbSys is a local mock etched at 0x64 (`test/Harness.sol: MockArbSys`) whose
`arbBlockHash` enforces the 256-block window like the precompile; production randomness comes from the
precompile and is only as unpredictable as the sequencer's block hashes (see docs/AUDIT.md).

## Deployment floor (test/Deploy.t.sol, 9 tests)

- test_deployGasUnderTarget: five contracts + genesis launch deployed from raw creation code with CREATE:
  10,807,783 gas measured in the test EVM. Under the 13M target and the 16,777,216 hard limit.
- test_runtimeSizesAndOpcodes: every runtime < 24,576 bytes (PadToken 2,714; PadGame 12,991; PvPPad 9,665;
  PadLiquidity 15,634; KingOfThePad 3,366) and no DELEGATECALL/CALLCODE/SELFDESTRUCT outside PUSH data.
- test_bindingsAndGenesis, test_bindingsAreOneShot, test_templatesCannotBeInitialized: constructors bind
  once, genesis launch "Pepes Value Pepes"/PvP exists and waits for its first mint, templates are dead.
- test_openSwitch, test_ownerOpensEarly: mint/roll/launch/takeCrown revert until openPad(); only the owner
  before 30 days, anyone after; cannot be undone.
- test_escrowClaim: failed-send escrow is only fundable by system contracts and claimable by the recipient.
- test_launchToken: LaunchToken supply, decimals, name/symbol, transfer, transferFrom, over-balance revert.

## Game rules (test/Game.t.sol, 26 tests)

- Signup: first mint starts the 10-minute window; one Imp per wallet; 200 max; late mint reverts.
- Rolls: exact 0.002 ETH; only during play; only Imps; 90/8/2 split with genesis burn share into the pot;
  tokens delivered to the roller at once and locked until graduation; 60 s cooldown; death after 10 minutes
  without a roll (including never rolling); all dead ends the game.
- Curve: virtual reserves 1 ETH / 1e9 tokens, 1 ETH buys half the supply, 4 ETH sells exactly the 800M,
  invariant holds; sold-out roll's 90% goes to the pot; the roll that crosses the sell-out pays only for the
  tokens left and the curve ends at exactly 4 ETH (test_soldOutCrossingRollPaysOnlyForWhatIsLeft).
- RNG: commit block recorded; unresolvable until commit+4; outcome equals keccak(game, imp, nonce, three
  hashes) % 8 mapped to -4..-1/+1..+4; 8 oldest resolved per poke; an Imp's roll resolves its previous one
  out of order; a roll with an unresolvable predecessor reverts.
- Expiry: a roll past the 256-block window from height 0 stays 0; from ±h it moves 4 toward zero and never
  past it (test_missedPenaltyPullsTowardZeroFromBothSidesAndNeverPastIt); the reviewer's withholding sequence
  (+4, -4 expired, +3, -3 expired, +2, -4 expired) ends at 0, never above the honest |−2|
  (test_withholdingBadRollsNeverHelps).
- Bell: +50 and -50 clamp and end the game; later rolls revert; finalizer fee 0.5% capped; ringer 20%.
  Two imps landing on 50 in the same round: the earlier commit rings whoever resolves, the later imp's
  queue-jumping roll() is refused, and the tie-break follows commit order
  (test_bellAndTieBreakFollowCommitOrder, test_tieBreakIgnoresResolutionOrder); a roll whose own-roll
  resolution would ring the bell is refused with nothing charged or queued (test_rollAfterOwnBellIsRefused).
- Ranking: |height| desc with earlier heightReachedAt winning ties; top ceil(living/2); triangular weights
  (2/3, 1/3 for two winners); no bell gives 100% to ranks; dust to carry pot; curve ETH untouched.
- All dead: pot (minus fee) to the carry pot, then graduation still happens.
- Failed sends: a rejecting winner's payout is held in the pad and claimable.
- Batches: 120 Imps, 60 winners paid 25 per call, then graduation.
- Access: fundPot only pad/king; pokeFrom only pad.

## Liquidity (test/Liquidity.t.sol, 17 tests)

- Graduation creates the ETH/token pool (fee 10000, spacing 200, no hooks) at the final curve price, full
  range position owned by PadLiquidity, all curve ETH in, excess tokens to dEaD, token unlocked in the tx.
- Pre-initialized empty pool (above and below target): price moved to target by a limit swap for free, then
  liquidity added.
- Pre-initialized pool with ETH-only liquidity parked below the target, deep (5.7 ETH, would absorb every
  token) and shallow (0.95 ETH, sized to absorb 90% of the stock): graduation completes, the token unlocks,
  the gate opens, PadLiquidity keeps only the burn bucket, its positions hold all curve ETH, the carry pot
  receives at most the 1e-6 rounding margin, token conservation holds, and less than half of the spare tokens
  were sold (test_deepParkedEthLiquidityCannotBlockGraduation, test_shallowParkedEthLiquidityDoesNotDrainTheStock).
  Short of the target the pad holds an ETH-only position strictly above the target and a token-only position
  at or below the pool price (asserted in both).
- Tick spam (reviewer finding fa4bd5e1): 600 liquidity-1 ETH-only positions, one per spacing below the
  target, for a few thousand wei. The swap is skipped (pathTicks > MAX_PATH_TICKS), the graduating poke costs
  under 3M gas, the pool price stays where the griefer put it, the gate opens, and a holder selling their whole
  balance receives at most its value at the target price while the pad's ETH moves only at fair prices
  (test_tickSpamCannotMakeGraduationUnaffordable). 40 vs 400 parked ticks graduate at the same cost within
  100k gas (test_graduationGasIsFlatInParkedTicks). 32 parked ticks are crossed, the price reaches the target
  and one full-range position is created (test_fewParkedTicksAreCrossedToTheTarget). LP fees of split
  positions are collected and reach the king (test_splitPositionsStillPayFeesToKing).
- No ETH raised: all tokens burned, launch marked failed, pad gate opens, burn deposits redirect to carry pot.
- Genesis gating: launch reverts until PvP is done; input length limits; carry pot moves into the new game;
  non-genesis 2% goes to the burn bucket.
- Burn chunks: max 0.02 ETH per buy, one per 10 minutes, tokens to dEaD, waits for PvP graduation.
- Upkeep: a launch triggers a burn chunk; pad.upkeep finalizes a due game.
- Fee distribution: fees from a swap reach the king at collection (about 1% of the swap), round-robin cursor;
  after a dump the sale is capped at 0.5% of the pool's token depth with the 1% price limit held and the
  remainder sold at later collections (test_distributeSaleIsBoundedByPoolDepth).
- unlockCallback rejects callers other than the PoolManager.

## King and pad lists (test/King.t.sol, 10 tests)

- Closed until PvP graduates; first bid >= 0.01 ETH; next >= 110% and only after 1 hour.
- Old king refunded in full at once (plus any collected fees); refund to a rejecting king is held and
  claimable (the escrow's own claim reverts for a receiver that rejects ETH).
- Extra split: 50% to live game pots (equal shares, soonest-ending first, max 10) or carry pot when none;
  25% burn bucket; 25% dev.
- liveGames returns at most 10, soonest ending first; liveGames(0) returns an empty array; ended games leave
  the scan when finalized.
- 64 free never-started launches do not hide a live game from the split and do not receive upkeep pokes; the
  started/settling lists move the game through finalize, pay and graduate by strangers' upkeep calls
  (test_launchSpamDoesNotHideLiveGamesOrStarveUpkeep).

## Not covered by tests

- Real ArbSys hashes and sequencer behaviour (mocked).
- Gas of a 200-Imp finalization at the exact chain gas price (the 120-Imp test runs within the pad's 3M
  upkeep gas cap only when poked directly; see AUDIT for the bound).
- Fuzzing and invariant runs; a long fuzz campaign over the curve, the swap budget and payout accounting is
  recommended before public launch.
