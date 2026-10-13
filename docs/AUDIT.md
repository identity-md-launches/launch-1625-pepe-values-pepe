# Audit notes (self-review)

This is the builder's own review against the eth-security checklist and the solidity-security-review
questions. Tests passing do not constitute an audit: funds-holding code needs an independent adversarial
review before release. Tools run: `forge build`, `forge test` (46 tests), `forge fmt --check`, the built-in
`forge lint` warnings (only informational "missing zero check" / unsafe-typecast notes on trusted internal
calls). Slither, Mythril and fuzz campaigns were not run in this job's time budget.

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
   window (256 blocks) is enforced: a roll not resolved in time resolves to 0 (no height move), so a stuck
   queue cannot be exploited for a chosen outcome and the game can always finalize.
2. **Resolution withholding.** Anyone can resolve, every action resolves 8, and an Imp's own roll resolves
   its previous one; a roll whose predecessor is not yet resolvable (fewer than 4 L2 blocks since commit)
   reverts, so no Imp can stack unresolved rolls. Finalization waits for the queue to drain, and the queue
   always drains because resolution needs no cooperation.
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
   batches of 25; resolutions in batches of 8; `liveGames` scans at most 64 active games; upkeep pokes one
   game per call under a 3M gas cap and the distribute/burn steps under 1.5M/0.7M caps, all in try/catch so
   a failing step cannot block the caller. A 200-Imp finalization may exceed the upkeep cap; it then simply
   waits for a direct `poke()` which has no cap. Unbounded growth: the `active` list grows with launches but
   is only ever indexed, never iterated beyond the 64-element scan.
7. **Pre-initialized pool / griefing.** Anyone can initialize the v4 pool for a token before graduation
   (pool keys are public) and even add liquidity at a wrong price. Graduation handles it: initialize in a
   try/catch, read slot0, swap with a price limit using only the pad's own funds, then add full-range
   liquidity at the resulting price. The pad never sells at a loss beyond what the griefer's liquidity
   absorbs at prices between the wrong and target price; that liquidity is the griefer's cost. Tested above
   and below target.
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

## Residual risks / recommendations before public launch

- Independent audit of `PadLiquidity`'s v4 integration against the exact PoolManager deployed on Robinhood
  Chain (the tests use v4-core at commit 46c6834; a different deployed version could differ in `Currency`
  settlement details).
- Fuzz the curve and payout accounting (conservation invariants) and the sort/tie-breaking with random
  heights.
- Confirm the chain's gas limit and block time: the design assumes L2 blocks every few seconds so the 60 s
  cooldown always spans more than 4 blocks (otherwise `roll` reverts with `Unresolved` until it does).
- Legal review of the game-of-chance, token sale and auction mechanics for the intended jurisdictions.
