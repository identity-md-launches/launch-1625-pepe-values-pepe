# Test report

Toolchain: forge 1.8.3, solc 0.8.26 (pinned), evm cancun, optimizer 200 runs. Command: `forge test`.
Result: 46 tests, 46 passed, 0 failed, 0 skipped. `forge build` and `forge fmt --check` pass.

The Uniswap v4 PoolManager used in tests is the real `v4-core` PoolManager (vendored under `lib/v4-core`,
commit 46c6834). ArbSys is a local mock etched at 0x64 (`test/Harness.sol: MockArbSys`) whose
`arbBlockHash` enforces the 256-block window like the precompile; production randomness comes from the
precompile and is only as unpredictable as the sequencer's block hashes (see docs/AUDIT.md).

## Deployment floor (test/Deploy.t.sol)

- test_deployGasUnderTarget: five contracts + genesis launch deployed from raw creation code with CREATE:
  9,695,804 gas measured in the test EVM (trace of the individual creations sums to 8,549,763 + 21k base).
  Both under the 13M target and the 16,777,216 hard limit.
- test_runtimeSizesAndOpcodes: every runtime < 24,576 bytes (PadToken 2,714; PadGame 12,667; PvPPad 8,968;
  PadLiquidity 11,546; KingOfThePad 3,366) and no DELEGATECALL/CALLCODE/SELFDESTRUCT outside PUSH data.
- test_bindingsAndGenesis, test_bindingsAreOneShot, test_templatesCannotBeInitialized: constructors bind
  once, genesis launch "Pepes Value Pepes"/PvP exists and waits for its first mint, templates are dead.
- test_openSwitch, test_ownerOpensEarly: mint/roll/launch/takeCrown revert until openPad(); only the owner
  before 30 days, anyone after; cannot be undone.
- test_escrowClaim: failed-send escrow is only fundable by system contracts and claimable by the recipient.
- test_launchToken: LaunchToken supply, decimals, name/symbol, transfer, transferFrom, over-balance revert.

## Game rules (test/Game.t.sol)

- Signup: first mint starts the 10-minute window; one Imp per wallet; 200 max; late mint reverts.
- Rolls: exact 0.002 ETH; only during play; only Imps; 90/8/2 split with genesis burn share into the pot;
  tokens delivered to the roller at once and locked until graduation; 60 s cooldown; death after 10 minutes
  without a roll (including never rolling); all dead ends the game.
- Curve: virtual reserves 1 ETH / 1e9 tokens, 1 ETH buys half the supply, 4 ETH sells exactly the 800M,
  invariant holds; sold-out roll's 90% goes to the pot (curve state written with stdstore to reach the branch).
- RNG: commit block recorded; unresolvable until commit+4; outcome equals keccak(game, imp, nonce, three
  hashes) % 8 mapped to -4..-1/+1..+4; window missed (>256 blocks) resolves to 0; 8 oldest resolved per
  poke; an Imp's roll resolves its previous one out of order; a roll with an unresolvable predecessor reverts.
- Bell: +50 and -50 clamp and end the game; later rolls revert; finalizer fee 0.5% capped; ringer 20%.
- Ranking: |height| desc with earlier heightReachedAt winning ties; top ceil(living/2); triangular weights
  (2/3, 1/3 for two winners); no bell gives 100% to ranks; dust to carry pot; curve ETH untouched.
- All dead: pot (minus fee) to the carry pot, then graduation still happens.
- Failed sends: a rejecting winner's payout is held in the pad and claimable.
- Batches: 120 Imps, 60 winners paid 25 per call, then graduation.
- Access: fundPot only pad/king; pokeFrom only pad.

## Liquidity (test/Liquidity.t.sol)

- Graduation creates the ETH/token pool (fee 10000, spacing 200, no hooks) at the final curve price, full
  range position owned by PadLiquidity, all curve ETH in, excess tokens to dEaD, token unlocked in the tx.
- Pre-initialized pool (above and below target): price moved to target by a limit swap, then liquidity added.
- No ETH raised: all tokens burned, launch marked failed, pad gate opens, burn deposits redirect to carry pot.
- Genesis gating: launch reverts until PvP is done; input length limits; carry pot moves into the new game;
  non-genesis 2% goes to the burn bucket.
- Burn chunks: max 0.02 ETH per buy, one per 10 minutes, tokens to dEaD, waits for PvP graduation.
- Upkeep: a launch triggers a burn chunk; pad.upkeep finalizes a due game.
- Fee distribution: fees from a swap reach the king at collection (about 1% of the swap), round-robin cursor.
- unlockCallback rejects callers other than the PoolManager.

## King (test/King.t.sol)

- Closed until PvP graduates; first bid >= 0.01 ETH; next >= 110% and only after 1 hour.
- Old king refunded in full at once (plus any collected fees); refund to a rejecting king is held and
  claimable (the escrow's own claim reverts for a receiver that rejects ETH).
- Extra split: 50% to live game pots (equal shares, soonest-ending first, max 10) or carry pot when none;
  25% burn bucket; 25% dev.
- liveGames returns at most 10, soonest ending first.

## Not covered by tests

- Real ArbSys hashes and sequencer behaviour (mocked).
- Gas of a 200-Imp finalization at the exact chain gas price (the 120-Imp test runs within the pad's 3M
  upkeep gas cap only when poked directly; see AUDIT for the bound).
- Fuzzing and invariant runs; a long fuzz campaign over the curve and payout accounting is recommended before
  public launch.
