# Audit notes (self-review)

This is the builder's own review against the eth-security checklist and the solidity-security-review
questions. Tests passing do not constitute an audit: funds-holding code needs an independent adversarial
review before release. Tools run: `forge build`, `forge test` (58 tests), `forge fmt --check`, the built-in
`forge lint` warnings (only informational "missing zero check" / unsafe-typecast notes on trusted internal
calls). Slither, Mythril and fuzz campaigns were not run in this job's time budget.

Revision (second round): an independent review reported eight findings; items 2, 7 and 13 to 18 below record
what was reproduced and changed. The reviewers' proof tests for the pre-initialized pool (amount variant and
gas variant) run green.

## Trust and roles

| Role / address            | Power                                                   |
|---------------------------|---------------------------------------------------------|
| owner (`$owner`)          | `openPad()` before the 30-day public window. Nothing else. |
| dev (`DEV`, immutable)    | Receives 25% of each crown "extra". No powers.           |
| king (auction winner)     | Receives collected LP fees until outbid. No powers.      |
| PvPPad / games / liquidity / king contracts | Trust each other through registry checks (`isGame`, `liquidity`, `king`). |
| Uniswap v4 PoolManager    | External dependency, fixed address, reached only via `unlock`. |
| ArbSys (0x64)             | Block number and hashes for timing/randomness.           |

No upgradeability, no proxies except the EIP-1167 clones (whose implementation is immutable), no
`selfdestruct`, no `delegatecall` in any launched runtime (tested by opcode scan).

## Findings and their resolution

1. **Randomness is sequencer-influenceable (accepted risk, documented).** Outcomes hash three future
   Arbitrum block hashes. A sequencer or a builder who can choose block contents has some influence on
   the hash; a player cannot (no player secret, commit is fixed at roll time, resolution is permissionless).
   Stakes per roll are 0.002 ETH, and the only prize is the pot. The brief mandates this scheme. The hash
   window (256 blocks) is enforced: a roll not resolved in time has no readable dice; see item 2 for what it
   counts as. The game can always finalize.
2. **Resolution withholding (reviewer finding, reproduced, fixed).** Anyone can resolve, every action resolves
   8, and an Imp's own roll resolves its previous one; a roll whose predecessor is not yet resolvable (fewer
   than 4 L2 blocks since commit) reverts, so no Imp can stack unresolved rolls. What the first round missed:
   the outcome is public from block c+4, and in a thin game nobody but the roller resolves, so with "expired
   = 0" the roller could poke good dice and let bad dice expire (height monotone non-decreasing). Fixed: an
   expired roll now moves |height| down by `MISSED_PENALTY` (4), never past zero. Any real bad die moves
   |height| down by at most 4 (or crosses zero, where the result is <= 4 - |h|), so expiring is never
   strictly better than resolving: selection has no edge. This deviates from the brief's literal "= 0"
   because that rule is what created the edge; the README states it. Honest players in quiet games should
   resolve (poke) within the window; any frontend or keeper call does it for them.
3. **Push payments.** Every ETH push is gas-capped at 30k and a failure is escrowed in `PvPPad` (claimable).
   A rejecting winner, king, or dev cannot block payouts, refunds, or the game flow (tested).
4. **Reentrancy.** User entry points (`mint`, `roll`, `poke`, `pokeFrom`, `takeCrown`, `distribute`,
   `burnChunk`, `graduate`) are guarded. State is updated before external calls (CEI). The global upkeep
   has its own re-entry flag and skips the calling game. Pushes carry 30k gas, which is not enough to
   re-enter any state-changing function meaningfully.
5. **Conservation.** Each game holds exactly `pot + curveEth` until finalization; rounding dust of the
   triangular split goes to the carry pot; graduation sends `curveEth` and all remaining tokens out, leaving
   the clone empty (tested: game balance is 0 after graduation). `PadLiquidity` holds only `burnBucket`
   between calls; graduation rounding dust in ETH is forwarded to the carry pot rather than into the pool
   price. `PvPPad` holds `carryPot + totalClaimable`.
6. **Bounded gas.** Max 200 Imps; insertion sort over ≤200 in memory; ≤100 winners written; payouts in
   batches of 25; resolutions in batches of 8; `liveGames` scans at most 100 started games; upkeep pokes one
   game per call under a 3M gas cap and the distribute/burn steps under 1.5M/0.7M caps, all in try/catch so
   a failing step cannot block the caller. A 200-Imp finalization may exceed the upkeep cap; it then simply
   waits for a direct `poke()` which has no cap. Unbounded growth: the `active`, `started` and `settling`
   lists grow with launches but are only ever indexed, never iterated beyond the 100-element scan.
7. **Pre-initialized pool / griefing (reviewer finding, critical, reproduced, fixed).** Anyone can initialize
   the v4 pool for a token before graduation (pool keys are public) and park liquidity. Because the token is
   locked until graduation, the only liquidity a third party can park is ETH-only, i.e. a range above the
   current price, which is in the way only when the pool was initialized below the target. The first round
   swapped with exact input = the pad's whole token stock and only a price limit: deep parked ETH absorbed
   every token (`tokens == 0`, liquidity 0, `l - l/1e6 - 1` panicked, graduation reverted forever and the
   genesis gate stayed shut), and shallow parked ETH bought ~90% of the supply while most of the ETH was
   forwarded to the carry pot as "dust". Fixed in `PadLiquidity._swapBudget` / `_graduate`:
   - the swap's exact input is bounded to the part of the stock the full-range position could not use at the
     target anyway, divided by `1 + (target/cur)^2`, which guarantees the position stays fundable with every
     wei of the scarce side even if the whole input is absorbed at the worst price on the path (the maths is
     in the code comment); a 1 wei minimum keeps the free price move through an empty pool;
   - liquidity is added at whatever price was reached; `_fullRangeLiquidity` returns 0 instead of
     underflowing and the position is skipped in that (now unreachable) case; prices at or beyond the
     full-range ticks are handled without reverting;
   - leftovers can no longer be large: ETH is always the limiting side after a bounded sale (tested: the carry
     receives at most the 1e-6 rounding margin), and leftover tokens are burned as before.
   Tested with the reviewer's deep (8e23 liquidity, 5.7 ETH parked) and shallow (0.95 ETH sized to absorb
   90% of the stock) scenarios: graduation completes, the token unlocks, the gate opens, the pad's position
   holds all curve ETH plus what the parked liquidity paid, and less than half of the spare tokens were sold.
   **Gas variant (reviewer finding fa4bd5e1, critical, reproduced, fixed).** The same entry point let a third
   party decide how much gas graduation costs: Uniswap v4 charges one tick crossing per initialized tick on the
   swap's path, a liquidity-1 ETH-only position per tick spacing costs about 8 wei, and 2,000 of them between
   the pre-initialized price and the target made the graduating poke cost 63,094,350 gas (reproduced with the
   reviewer's proof): above Arbitrum Nitro's 32M per-transaction cap, so the game stayed in PHASE_PAYING, the
   curve ETH stayed in the clone, the token never unlocked and, for genesis, launches, the king and burns stayed
   closed. Fixed in `PadLiquidity._graduate`:
   - before the swap, `_initializedTicksBetween` counts the initialized ticks between the pool price and the
     target from the tick bitmap (at most 36 words, counting stops at `MAX_PATH_TICKS + 1 = 33`); the swap is
     attempted only when at most `MAX_PATH_TICKS = 32` are in the way, so it crosses at most 32 ticks and the
     graduation's gas no longer depends on foreign pool state (measured: the proof's 2,000-tick spam graduates
     in 799,109 gas; 40 and 400 parked ticks cost the same within 100k; all under the 3M upkeep poke cap);
   - **a position short of the target is never full-range any more.** Reviewing the fix showed that the accepted
     residual ("the pool may open short of the final curve price") was itself a drain when the shortfall is
     large: a full-range position at a price far below the target holds almost only ETH and offers it to token
     sellers at the parked price, so a roller with a few tokens could take every wei of curve ETH (and parking
     deep liquidity to exhaust the swap budget costs the griefer only the value of the pad's spare tokens at the
     target price, less than the curve ETH of a sold-out launch). Now, whenever the pool price is not the
     target after the (possibly skipped) swap, `_addSplitPositions` places all ETH in a range that starts
     strictly above both the pool tick and the target tick, and all tokens in a range that ends at or below
     both. The pad's ETH is then only ever sold to token sellers at the target price or worse for them, and its
     tokens only at the target price or better for the pad. The pool price itself is left where the third
     party put it; the gap between it and the target holds only their liquidity, which they may withdraw.
   - `positionsOf(token)` records the one or two ranges; `_collect` loops over them, so LP fees from split
     positions reach the king as before (tested); `pathTicks(token, target)` exposes the count.
   Tested: `test_tickSpamCannotMakeGraduationUnaffordable` (600 parked ticks, swap skipped, graduation under
   3M gas, gate opens, a holder selling into the pool receives at most the target price for their tokens and
   the pad's ETH moves only at fair prices), `test_graduationGasIsFlatInParkedTicks`,
   `test_fewParkedTicksAreCrossedToTheTarget` (32 ticks: crossed, price reaches the target, single full-range
   position), `test_splitPositionsStillPayFeesToKing`, and the deep/shallow parked-liquidity tests now assert
   the split layout. Residual: a griefed pool opens with its price at the third party's chosen point and a gap
   up to the target; trading is still possible on both sides at prices no worse for the pad than the target.
   The 10-minute burn buy (`burnChunk`) and the chunk sale in `distribute` are the other swaps the pad makes:
   the sale is bounded by its 1% sqrt-price limit (at most two tick crossings); the burn buy has no price
   limit because the brief fixes its size (up to 0.02 ETH), so after graduation a third party holding tokens
   could park thousands of token-only ticks below the price and make a burn buy unaffordable until they
   withdraw. That stalls burns (the bucket keeps its ETH and upkeep's try/catch ignores the failure) but
   moves no funds; it is left as documented.
8. **Token locking.** `PadToken` refuses transfers whose `msg.sender` is not the game or `PadLiquidity`
   until `unlock()` (only `PadLiquidity`) is called inside the graduation tx. Holders cannot trade before the
   pool exists; approvals do not bypass the lock (the check is on `msg.sender`).
9. **Initializers.** Templates set `initialized = true` in their constructors so the implementations can
   never be initialized; clones are initialized exactly once by the pad in the same transaction they are
   created (tested).
10. **Rounding.** Curve: the new virtual reserve is rounded up, so the buyer never gains dust; at sold-out
    the last buy is capped at the remaining curve supply. Payout: shares round down, dust carried. Fees:
    0.5% capped at 0.005 ETH. Burn: `min(bucket, 0.02 ETH)`.
11. **Time.** Durations use `block.timestamp` (the sequencer clock); `block.number` on Arbitrum is the L1
    number and is never used. Boundaries: alive iff `now <= lastRollAt + 10 min`; the game ends at exactly
    `firstMintAt + 60 min`, or one second after the last possible survival, or at the bell. Tests cover
    each boundary.
12. **Genesis failure.** If PvP never receives a roll, it fails; `pvpDone` still opens launches and the king,
    and burn deposits are redirected to the carry pot since the PvP pool can never exist. This deviates from
    "wait until PvP graduates" only to avoid permanently stuck ETH.
13. **Bell and tie-break order (reviewer finding, reproduced, fixed).** `heightSeq` was stamped at resolution
    time and the bell went to whichever ±50 roll resolved first, while `roll()` resolves the caller's own
    pending roll ahead of the queue. Fixed: `heightSeq` is now the queue position (commit order) of the roll
    that produced the height, and a `roll()` whose own-roll resolution rings the bell reverts `BadPhase`
    (play ended), so a persisted bell is always the earliest-committed roll to reach ±50: the queue resolves
    in order, and the only out-of-order path cannot ring. Tested with two imps landing on 50 in the same round.
14. **Post-bell roll (reviewer finding, low, reproduced, fixed).** Same fix as 13: the end is re-checked after
    the caller's previous roll is resolved; nothing is charged or queued after the bell.
15. **Launch spam versus the king split and upkeep (reviewer finding, reproduced, fixed).** `liveGames` scanned
    the first 64 launches regardless of state and upkeep round-robined over them, so 64 free never-started
    launches hid every live game (50% of each crown extra fell to the carry pot) and wasted upkeep pokes.
    Fixed: games report their first mint (`onGameStarted`) and finalization; `PvPPad` keeps `started`
    (started, not finalized) and `settling` (finalized, not done) lists. `liveGames` scans the first 100
    started games; upkeep round-robins over started + settling only. Never-started launches are invisible to
    both. Residual: an attacker who keeps 100 started-and-unfinalized games alive at once (each needs a mint
    and ends 20 minutes later unless rolled, one poke finalizes it) could still push a later-started game out
    of the scan; the misrouted share then goes to the carry pot, i.e. to the next launched game's pot. Judged
    uneconomic; a paid launch would remove it but the brief makes launching free.
16. **Sold-out crossing roll (reviewer finding, low, reproduced, fixed).** The roll that sells the curve out
    paid its whole 90% into `curveEth` for a partial fill, lowering the graduation price. `_buy` now returns the
    exact cost of the tokens left (the ETH that moves the reserve to the curve's end) and the rest goes to the
    pot; the curve ends at exactly 4 ETH.
17. **Fee sale sandwich (reviewer finding, low, judged real, mitigated).** `distribute` is permissionless and
    sold up to 1M fee tokens at any price. Now each sale is also capped at 0.5% of the pool's token depth and
    at a 1% sqrt-price move; the remainder waits. A sandwich pays the 1% pool fee twice on the volume needed to
    move the price, which exceeds what it can extract from a chunk that small; those fees go to the king anyway.
18. **`liveGames(0)` (reviewer finding, info, fixed).** Returns an empty array.

## Residual risks / recommendations before public launch

- Independent audit of `PadLiquidity`'s v4 integration against the exact PoolManager deployed on Robinhood
  Chain (the tests use v4-core at commit 46c6834; a different deployed version could differ in `Currency`
  settlement details).
- Fuzz the curve and payout accounting (conservation invariants) and the sort/tie-breaking with random
  heights.
- Confirm the chain's gas limit and block time: the design assumes L2 blocks every few seconds so the 60 s
  cooldown always spans more than 4 blocks (otherwise `roll` reverts with `Unresolved` until it does).
- Legal review of the game-of-chance, token sale and auction mechanics for the intended jurisdictions.
