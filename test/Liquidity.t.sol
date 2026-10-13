// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Swapper, Rejecter, Griefer, TickSpammer} from "./Harness.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";

contract LiquidityTest is Harness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_graduationCreatesLockedFullRangePool() public {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 3; r++) {
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
            vm.warp(block.timestamp + 61);
        }
        uint256 curve = genesis.curveEth();
        uint160 target = genesis.graduationSqrtPrice();
        uint256 remaining = pvp.balanceOf(address(genesis));
        assertEq(remaining, 1e9 ether - genesis.tokensSold());
        vm.warp(genesis.endsBy());
        _settle(genesis);
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
        assertEq(genesis.curveEth(), 0);
        assertEq(address(genesis).balance, 0);
        assertTrue(pvp.unlocked());
        assertTrue(liq.graduated(address(pvp)));
        assertEq(liq.poolCount(), 1);
        assertTrue(pad.pvpDone());
        assertFalse(pad.pvpFailed());
        assertEq(pad.activeCount(), 0);

        PoolKey memory key = liq.poolKey(address(pvp));
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtP, target);
        uint128 L = IPoolManager(address(manager)).getLiquidity(key.toId());
        assertGt(L, 0);
        (uint128 posL,,) =
            IPoolManager(address(manager)).getPositionInfo(key.toId(), address(liq), -887_200, 887_200, bytes32(0));
        assertEq(posL, L);
        // all curve ETH went to the pool (dust at most 1e-6 of it), excess tokens burned, nothing left behind
        assertApproxEqRel(address(manager).balance, curve, 1e-5 ether);
        assertEq(pvp.balanceOf(address(liq)), 0);
        assertGt(pvp.balanceOf(DEAD), 0);
        assertEq(pvp.balanceOf(address(manager)) + pvp.balanceOf(DEAD) + genesis.tokensSold(), 1e9 ether);
        // holders can now transfer
        vm.prank(_imp(0));
        pvp.transfer(address(1), 1);
        // the position cannot be removed by anyone: PadLiquidity exposes no such function
        vm.expectRevert(PadLiquidity.NotGame.selector);
        liq.graduate(address(pvp), target);
    }

    function test_preInitializedPoolIsMovedToTargetThenFunded() public {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 3; r++) {
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
            vm.warp(block.timestamp + 61);
        }
        uint160 target = genesis.graduationSqrtPrice();
        // a griefer initializes the pool first, at a wrong price (both directions are exercised)
        PoolKey memory key = liq.poolKey(address(pvp));
        Swapper s = new Swapper(manager);
        s.initializeAt(key, target * 3);
        vm.warp(genesis.endsBy());
        _settle(genesis);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtP, target);
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertTrue(pvp.unlocked());
    }

    function test_preInitializedBelowTarget() public {
        _graduateGenesisWithPreInit(false);
    }

    function _graduateGenesisWithPreInit(bool above) internal {
        _open();
        _mintN(genesis, 1);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        arb.advance(5);
        uint160 target = genesis.graduationSqrtPrice();
        PoolKey memory key = liq.poolKey(address(pvp));
        new Swapper(manager).initializeAt(key, above ? target * 2 : target / 2);
        vm.warp(genesis.endsBy());
        _settle(genesis);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtP, target);
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
    }

    /// @dev Plays genesis to just before its end and returns the pool key; the griefer parks ETH-only liquidity
    ///      in [upper - 4000, upper) ticks right below the target with `liq` liquidity.
    function _playThenPark(int256 liqAmount) internal returns (Griefer g, uint256 parked, uint160 target) {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 3; r++) {
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
            vm.warp(block.timestamp + 61);
        }
        target = genesis.graduationSqrtPrice();
        int24 upper = (TickMath.getTickAtSqrtPrice(target) / 200) * 200 - 200; // strictly below the target
        int24 lower = upper - 4_000;
        g = new Griefer(IPoolManager(address(manager)));
        vm.deal(address(g), 50 ether);
        uint256 before = address(g).balance;
        g.park(liq.poolKey(address(pvp)), lower, upper, liqAmount);
        parked = before - address(g).balance;
        assertGt(parked, 0);
    }

    /// @dev ETH and tokens held by the pad's positions in the pool, from the pool's price and each range.
    function _padHoldings() internal view returns (uint256 padEth, uint256 padTokens) {
        PoolKey memory key = liq.poolKey(address(pvp));
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        PadLiquidity.Range[] memory rs = liq.positionsOf(address(pvp));
        for (uint256 i; i < rs.length; i++) {
            (uint128 L,,) = IPoolManager(address(manager))
                .getPositionInfo(key.toId(), address(liq), rs[i].lower, rs[i].upper, bytes32(0));
            assertGt(L, 0, "recorded position has liquidity");
            uint160 lo = TickMath.getSqrtPriceAtTick(rs[i].lower);
            uint160 hi = TickMath.getSqrtPriceAtTick(rs[i].upper);
            uint160 a = sqrtP < lo ? lo : (sqrtP > hi ? hi : sqrtP);
            padEth += FullMath.mulDiv(uint256(L) << 96, hi - a, FullMath.mulDiv(a, hi, 1 << 96));
            padTokens += FullMath.mulDiv(L, a - lo, 1 << 96);
        }
    }

    /// @dev Graduation completed with every asset accounted for; returns the tokens the parked liquidity absorbed.
    ///      Short of the target the pad holds two single-sided positions: its ETH strictly above the target, its
    ///      tokens at or below the pool price, so neither side is ever traded at a price worse than the target.
    function _assertGraduatedWithEverything(
        uint160 target,
        uint256 curve,
        uint256 remaining,
        uint256 carryAfterFinalize
    ) internal view returns (uint256 sold) {
        PoolKey memory key = liq.poolKey(address(pvp));
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
        assertTrue(pad.pvpDone(), "genesis graduated");
        assertTrue(pvp.unlocked(), "token unlocked");
        assertEq(address(genesis).balance, 0);
        // PadLiquidity keeps nothing but the burn bucket; its positions hold every wei of ETH it had (the curve
        // ETH plus whatever the parked liquidity paid for the tokens it absorbed) up to the 1e-6 rounding margin
        assertEq(address(liq).balance, liq.burnBucket());
        assertEq(pvp.balanceOf(address(liq)), 0);
        (uint160 sqrtP, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        PadLiquidity.Range[] memory rs = liq.positionsOf(address(pvp));
        if (sqrtP == target) {
            assertEq(rs.length, 1, "one full-range position");
            assertEq(rs[0].lower, -887_200);
            assertEq(rs[0].upper, 887_200);
        } else {
            assertLt(sqrtP, target, "short of the target");
            assertEq(rs.length, 2, "ETH-only and token-only positions");
            assertGt(rs[0].lower, TickMath.getTickAtSqrtPrice(target), "pad ETH sits strictly above the target");
            assertGt(rs[0].lower, tick);
            assertEq(rs[0].upper, 887_200);
            assertEq(rs[1].lower, -887_200);
            assertLe(rs[1].upper, tick, "pad tokens sit at or below the pool price");
        }
        (uint256 padEth, uint256 padTokens) = _padHoldings();
        assertGe(padEth, curve * 999_999 / 1_000_000, "all curve ETH is in the pad's positions");
        // the only ETH that left PadLiquidity for the carry pot is the 1e-6 rounding margin of what it pooled
        assertLe(pad.carryPot() - carryAfterFinalize, padEth / 100_000 + 1, "ETH leftover is rounding dust only");
        // token conservation: in the manager (pad positions + parked position) + burned + sold on the curve
        uint256 inManager = pvp.balanceOf(address(manager));
        assertEq(inManager + pvp.balanceOf(DEAD) + genesis.tokensSold(), 1e9 ether);
        sold = remaining - padTokens - pvp.balanceOf(DEAD);
        // the swap only ever spends part of the token excess the position could not use anyway
        assertLt(sold, remaining / 2, "at most the spare half of the excess was sold");
    }

    /// @dev Plays genesis with two imps (3 rolls each) and returns the pool key and target.
    function _playGenesis() internal returns (PoolKey memory key, uint160 target) {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 3; r++) {
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
            vm.warp(block.timestamp + 61);
        }
        key = liq.poolKey(address(pvp));
        target = genesis.graduationSqrtPrice();
    }

    /// @dev Reviewer finding fa4bd5e1: thousands of 1-wei ETH-only positions between a pre-initialized price and
    ///      the target made the graduation swap cross every tick (63M gas for 2,000). Now the swap is skipped
    ///      when more than MAX_PATH_TICKS are in the way, graduation costs the same whatever is parked, and the
    ///      pad's funds go into positions around the target so nobody can drain its ETH at the parked price.
    struct Spam {
        PoolKey key;
        uint160 target;
        uint160 parkedPrice;
        uint256 curve;
        uint256 remaining;
        uint256 carryAfterFinalize;
        uint256 gasUsed;
    }

    /// @dev Plays genesis, parks `count` liquidity-1 ETH-only ticks below the target, finalizes and graduates.
    function _spamThenGraduate(uint256 count) internal returns (Spam memory s) {
        (s.key, s.target) = _playGenesis();
        s.curve = genesis.curveEth();
        s.remaining = pvp.balanceOf(address(genesis));
        int24 tTarget = (TickMath.getTickAtSqrtPrice(s.target) / 200) * 200;
        int24 from = tTarget - int24(int256(count)) * 200;
        TickSpammer sp = new TickSpammer(IPoolManager(address(manager)));
        vm.deal(address(sp), 1 ether);
        sp.initAt(s.key, from - 200);
        sp.spam(s.key, from, count);
        assertLt(1 ether - address(sp).balance, count * 10, "a few wei per parked tick");
        (s.parkedPrice,,,) = IPoolManager(address(manager)).getSlot0(s.key.toId());
        vm.warp(genesis.endsBy());
        genesis.poke(); // finalize
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        s.carryAfterFinalize = pad.carryPot();
        uint256 g0 = gasleft();
        genesis.poke(); // graduate
        s.gasUsed = g0 - gasleft();
    }

    function test_tickSpamCannotMakeGraduationUnaffordable() public {
        Spam memory s = _spamThenGraduate(600);
        assertGt(liq.pathTicks(address(pvp), s.target), liq.MAX_PATH_TICKS());
        assertLt(s.gasUsed, 3_000_000, "graduation fits the 3M upkeep poke, let alone one transaction");
        uint256 sold = _assertGraduatedWithEverything(s.target, s.curve, s.remaining, s.carryAfterFinalize);
        assertLe(sold, 1, "the swap was skipped: nothing traded with the parked ticks (1 wei rounding)");
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(s.key.toId());
        assertEq(sqrtP, s.parkedPrice, "the pool price was left where the griefer put it");
        assertTrue(pad.pvpDone());
        pad.launch("Next", "NXT", "");

        // the drain is closed: a holder selling tokens never gets more than their value at the target price
        // (plus the few wei the griefer's own positions pay), because the pad's ETH sits above the target
        address holder = _imp(0);
        uint256 bal = pvp.balanceOf(holder);
        Swapper sw = new Swapper(manager);
        vm.prank(holder);
        pvp.transfer(address(sw), bal);
        sw.sell(s.key, bal);
        uint256 got = address(sw).balance;
        uint256 fair = FullMath.mulDiv(bal, 1 << 96, FullMath.mulDiv(s.target, s.target, 1 << 96));
        assertLe(got, fair + 10_000, "no ETH is sold below the target price");
        assertGt(got, 0, "the holder can still sell");
        (uint256 padEthAfter,) = _padHoldings();
        assertGe(padEthAfter + got, s.curve * 999_999 / 1_000_000 - 10_000, "the pad's ETH moved at fair prices");
    }

    /// @dev Graduation gas does not depend on how many ticks are parked once the swap is skipped.
    function test_graduationGasIsFlatInParkedTicks() public {
        Spam memory a = _spamThenGraduate(40);
        setUp();
        Spam memory b = _spamThenGraduate(400);
        assertLt(a.gasUsed, 3_000_000);
        assertLt(b.gasUsed, 3_000_000);
        assertApproxEqAbs(b.gasUsed, a.gasUsed, 100_000, "ten times the ticks, same graduation cost");
    }

    /// @dev A few parked ticks (at most MAX_PATH_TICKS) are crossed as before: the price reaches the target and
    ///      the pad owns a single full-range position, paid for with a bounded part of its spare tokens.
    function test_fewParkedTicksAreCrossedToTheTarget() public {
        (PoolKey memory key, uint160 target) = _playGenesis();
        uint256 curve = genesis.curveEth();
        uint256 remaining = pvp.balanceOf(address(genesis));
        int24 tTarget = (TickMath.getTickAtSqrtPrice(target) / 200) * 200;
        uint256 count = liq.MAX_PATH_TICKS() - 1; // count + 1 ticks are initialized
        int24 from = tTarget - int24(int256(count)) * 200;
        TickSpammer s = new TickSpammer(IPoolManager(address(manager)));
        vm.deal(address(s), 1 ether);
        s.initAt(key, from - 200);
        s.spam(key, from, count);
        assertLe(liq.pathTicks(address(pvp), target), liq.MAX_PATH_TICKS());
        vm.warp(genesis.endsBy());
        genesis.poke();
        uint256 carryAfterFinalize = pad.carryPot();
        _settle(genesis);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtP, target, "price moved to the target through the parked ticks");
        uint256 sold = _assertGraduatedWithEverything(target, curve, remaining, carryAfterFinalize);
        assertGt(sold, 0);
        assertEq(liq.positionsOf(address(pvp)).length, 1);
    }

    /// @dev Fees from both split positions are collected and reach the king.
    function test_splitPositionsStillPayFeesToKing() public {
        Spam memory s = _spamThenGraduate(50);
        assertEq(liq.positionsOf(address(pvp)).length, 2, "split positions");
        address alice = address(0xA11CE);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.01 ether}();
        // sell into the pad's ETH side (fees on the token side), then buy back from it (fees in ETH)
        Swapper sw = new Swapper(manager);
        vm.deal(address(sw), 2 ether);
        uint256 bal = pvp.balanceOf(_imp(0));
        vm.prank(_imp(0));
        pvp.transfer(address(sw), bal);
        sw.sell(s.key, bal);
        sw.buy(s.key, 0.002 ether);
        uint256 before = alice.balance;
        liq.distribute(1);
        assertGt(alice.balance, before, "king paid from the split positions' fees");
        assertEq(liq.distributeCursor(), 2);
    }

    /// @dev Deep ETH-only liquidity parked below the target used to absorb every token and brick graduation.
    function test_deepParkedEthLiquidityCannotBlockGraduation() public {
        (, uint256 parked, uint160 target) = _playThenPark(8e23);
        assertGt(parked, 5 ether);
        uint256 curve = genesis.curveEth();
        uint256 remaining = pvp.balanceOf(address(genesis));
        vm.warp(genesis.endsBy());
        genesis.poke(); // finalize (all dead: the pot is carried); graduation is the next poke
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        uint256 carryAfterFinalize = pad.carryPot();
        _settle(genesis);
        uint256 sold = _assertGraduatedWithEverything(target, curve, remaining, carryAfterFinalize);
        assertGt(sold, 0, "the bounded swap did trade with the parked liquidity");
        // what was sold was sold above the graduation price, so the pool is deeper than the curve ETH alone
        assertGt(address(manager).balance, curve + parked / 10);
        // launches, the king and burns are open
        pad.launch("Next", "NXT", "");
        assertTrue(liq.burnDue() || liq.burnBucket() == 0);
    }

    /// @dev Shallow parked liquidity, sized to absorb most of the stock: graduation must not dump the stock
    ///      into it and must not route large ETH leftovers to the carry pot.
    function test_shallowParkedEthLiquidityDoesNotDrainTheStock() public {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 3; r++) {
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
            vm.warp(block.timestamp + 61);
        }
        uint160 target = genesis.graduationSqrtPrice();
        uint256 remaining = pvp.balanceOf(address(genesis));
        int24 upper = (TickMath.getTickAtSqrtPrice(target) / 200) * 200 - 200;
        int24 lower = upper - 4_000;
        // liquidity that would absorb ~90% of the remaining tokens between lower and the target
        uint256 L = (remaining << 96) / (target - TickMath.getSqrtPriceAtTick(lower)) * 9 / 10;
        Griefer g = new Griefer(IPoolManager(address(manager)));
        vm.deal(address(g), 50 ether);
        g.park(liq.poolKey(address(pvp)), lower, upper, int256(L));
        assertLt(50 ether - address(g).balance, 1.2 ether, "shallow: about 0.95 ETH parked");
        uint256 curve = genesis.curveEth();
        vm.warp(genesis.endsBy());
        genesis.poke(); // finalize
        uint256 carryAfterFinalize = pad.carryPot();
        _settle(genesis);
        uint256 sold = _assertGraduatedWithEverything(target, curve, remaining, carryAfterFinalize);
        // the parked liquidity could have absorbed 90% of the stock; the pad sold it far less than that
        assertLt(sold, remaining * 9 / 10 / 2);
    }

    function test_distributeSaleIsBoundedByPoolDepth() public {
        _graduateGenesis();
        address alice = address(0xA11CE);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.01 ether}();
        PoolKey memory key = liq.poolKey(address(pvp));
        Swapper s = new Swapper(manager);
        vm.deal(address(s), 1 ether);
        s.buy(key, 0.05 ether);
        uint256 bought = pvp.balanceOf(address(s));
        s.sell(key, bought); // dumps the price and leaves ~1% of `bought` as token fees
        uint128 L = IPoolManager(address(manager)).getLiquidity(key.toId());
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint256 cap = (uint256(L) * sqrtP >> 96) / liq.DEPTH_DIVISOR();
        assertGt(bought / 100, cap, "fee tokens exceed one chunk");
        uint256 before = alice.balance;
        liq.distribute(1);
        assertGt(alice.balance, before, "king paid");
        uint256 heldAfter = pvp.balanceOf(address(liq));
        assertGt(heldAfter, 0, "unsold fee tokens wait for the next collection");
        assertGe(heldAfter, bought / 100 - cap - 1);
        (uint160 sqrtAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertLe(sqrtAfter, sqrtP + sqrtP / 100, "price limit held");
        // later collections keep selling the remainder
        liq.distribute(1);
        assertLt(pvp.balanceOf(address(liq)), heldAfter);
    }

    function test_noEthRaisedBurnsAllAndFails() public {
        _open();
        _mintN(genesis, 1);
        vm.warp(genesis.endsBy());
        _settle(genesis);
        assertEq(genesis.phase(), genesis.PHASE_FAILED());
        assertEq(pvp.balanceOf(DEAD), 1e9 ether);
        assertTrue(liq.failed(address(pvp)));
        assertEq(liq.poolCount(), 0);
        assertTrue(pad.pvpDone());
        assertTrue(pad.pvpFailed());
        // launches open even so; burn deposits now feed the carry pot since PvP can never be bought
        pad.launch("Next", "NXT", "ipfs://x");
        vm.deal(address(this), 1 ether);
        liq.depositBurn{value: 0.5 ether}();
        assertEq(liq.burnBucket(), 0);
        assertEq(pad.carryPot(), 0.5 ether);
        assertFalse(liq.burnDue());
    }

    function test_genesisGatingAndCarryPot() public {
        _open();
        vm.expectRevert(PvPPad.GenesisPending.selector);
        pad.launch("Next", "NXT", "");
        _graduateGenesisAfterOpen();
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch("123456789012345678901234567890123", "NXT", "");
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch("ok", "12345678901", "");
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch("", "NXT", "");
        vm.deal(address(this), 1 ether);
        pad.addCarry{value: 0.3 ether}();
        uint256 carry = pad.carryPot(); // 0.3 plus what the all-dead genesis game carried
        assertGt(carry, 0.3 ether);
        (address t, address g) = pad.launch("Next", "NXT", "ipfs://img");
        assertEq(pad.launchCount(), 2);
        assertEq(PadToken(t).symbol(), "NXT");
        assertEq(PadToken(t).imageURL(), "ipfs://img");
        assertEq(PadGame(g).pot(), carry); // carry pot moved into the new game
        assertEq(pad.carryPot(), 0);
        assertFalse(PadGame(g).isGenesis());
        // second launch: 2% of a roll goes to the burn bucket, not the pot
        PadGame ng = PadGame(g);
        vm.prank(_imp(7));
        ng.mint();
        _toPlay(ng);
        _roll(ng, _imp(7));
        assertEq(liq.burnBucket() + liq.totalBurnedEth(), 0.00004 ether); // upkeep may burn it at once
        assertEq(ng.pot(), carry + 0.00016 ether);
    }

    function _graduateGenesisAfterOpen() internal {
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 3; r++) {
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
            vm.warp(block.timestamp + 61);
        }
        vm.warp(genesis.endsBy());
        _settle(genesis);
        assertTrue(pad.pvpDone());
    }

    function test_burnChunks() public {
        _graduateGenesis();
        vm.deal(address(this), 1 ether);
        liq.depositBurn{value: 0.05 ether}();
        assertEq(liq.burnBucket(), 0.05 ether);
        assertTrue(liq.burnDue());
        uint256 deadBefore = pvp.balanceOf(DEAD);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0.03 ether); // max 0.02 per buy
        assertGt(pvp.balanceOf(DEAD), deadBefore);
        assertEq(liq.totalBurnedEth(), 0.02 ether);
        vm.expectRevert(PadLiquidity.NotDue.selector); // one buy per 10 minutes
        liq.burnChunk();
        vm.warp(block.timestamp + 10 minutes);
        liq.burnChunk();
        vm.warp(block.timestamp + 10 minutes);
        liq.burnChunk(); // the last 0.01
        assertEq(liq.burnBucket(), 0);
        assertEq(liq.totalBurnedEth(), 0.05 ether);
        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(PadLiquidity.NotDue.selector);
        liq.burnChunk();
    }

    function test_burnWaitsForGenesisGraduation() public {
        _open();
        vm.deal(address(this), 1 ether);
        liq.depositBurn{value: 0.05 ether}();
        assertFalse(liq.burnDue());
        vm.expectRevert(PadLiquidity.NotDue.selector);
        liq.burnChunk();
    }

    function test_upkeepBurnsAndPokes() public {
        _graduateGenesis();
        vm.deal(address(this), 1 ether);
        liq.depositBurn{value: 0.05 ether}();
        // any state-changing call does upkeep: a launch triggers a burn chunk
        pad.launch("Next", "NXT", "");
        assertEq(liq.burnBucket(), 0.03 ether);
        // upkeep pokes due games: a game whose end passed is finalized by someone else's action
        PadGame g = PadGame(pad.getLaunch(1).game);
        vm.prank(_imp(3));
        g.mint();
        _toPlay(g);
        _roll(g, _imp(3));
        arb.advance(5);
        vm.warp(g.endsBy());
        pad.upkeep(address(this)); // pokes g (round robin over the single active game)
        assertEq(g.phase(), g.PHASE_PAYING());
    }

    function test_distributeFeesToKing() public {
        _graduateGenesis();
        vm.deal(address(this), 10 ether);
        vm.expectRevert(PadLiquidity.NoKing.selector);
        liq.distribute(1);
        address alice = address(0xA11CE);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.01 ether}();
        // generate fees: buy PvP through the pool
        Swapper s = new Swapper(manager);
        vm.deal(address(s), 1 ether);
        s.buy(liq.poolKey(address(pvp)), 0.5 ether);
        uint256 before = alice.balance;
        liq.distribute(1);
        uint256 got = alice.balance - before;
        // 1% fee on 0.5 ETH in, minus the protocol's rounding: roughly 0.005 ETH reaches the king at collection
        assertApproxEqRel(got, 0.005 ether, 0.05e18);
        assertEq(liq.distributeCursor(), 2); // the upkeep inside takeCrown collected once first
        // nothing more to collect right now
        before = alice.balance;
        liq.distribute(3);
        assertEq(alice.balance, before);
    }

    function test_unlockCallbackOnlyManager() public {
        vm.expectRevert(PadLiquidity.NotManager.selector);
        liq.unlockCallback("");
    }

    receive() external payable {}
}
