// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Rejecter} from "./Harness.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";

/// @dev A king whose receive() re-enters the king contract while being refunded or paid fees.
contract ReenteringKing {
    KingOfThePad immutable k;
    uint256 public entered;

    constructor(KingOfThePad k_) {
        k = k_;
    }

    function bid() external payable {
        k.takeCrown{value: msg.value}();
    }

    receive() external payable {
        entered++;
        k.distribute(1); // reverts: Reentrant (or out of the 30k push gas); either way the push fails
    }
}

/// @dev A winner whose receive() re-enters the game's poke() while being paid.
contract ReenteringWinner {
    PadGame immutable g;
    uint256 public entered;

    constructor(PadGame g_) {
        g = g_;
    }

    function mint() external {
        g.mint();
    }

    function roll() external payable {
        g.roll{value: msg.value}();
    }

    receive() external payable {
        entered++;
        g.poke();
    }
}

/// @notice Remaining failure paths, boundaries and events not covered by the other suites.
contract RulesTest is Harness {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    // ---------------------------------------------------------------- events
    function test_openPadEmitsOpened() public {
        vm.expectEmit(true, false, false, true, address(pad));
        emit PvPPad.Opened(OWNER, uint64(block.timestamp));
        _open();
        assertEq(pad.openedAt(), uint64(block.timestamp));
    }

    function test_takeCrownEmitsCrownedAndExtraSplit() public {
        _graduateGenesis();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(king));
        emit KingOfThePad.Crowned(alice, 0.02 ether, address(0), 0, 0.02 ether);
        vm.expectEmit(false, false, false, true, address(king));
        emit KingOfThePad.ExtraSplit(0.01 ether, 0, 0.01 ether, 0.005 ether, 0.005 ether);
        king.takeCrown{value: 0.02 ether}();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        vm.expectEmit(true, true, false, true, address(king));
        emit KingOfThePad.Crowned(bob, 0.03 ether, alice, 0.02 ether, 0.01 ether);
        king.takeCrown{value: 0.03 ether}();
    }

    function test_gameEmitsRolledResolvedBellEndedGraduated() public {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        vm.deal(_imp(0), 1 ether);
        uint256 q = genesis.quote(0.0018 ether);
        uint64 commit = uint64(arb.n());
        vm.prank(_imp(0));
        vm.expectEmit(true, false, false, true, address(genesis));
        // genesis: the 2% burn share joins the pot (0.00016 + 0.00004)
        emit PadGame.Rolled(_imp(0), 1, commit, q, 0.0018 ether, 0.0002 ether, 0);
        genesis.roll{value: 0.002 ether}();
        _roll(genesis, _imp(1));
        arb.advance(5);
        vm.expectEmit(true, false, false, false, address(genesis));
        emit PadGame.RollResolved(_imp(0), 1, 0, 0, false);
        genesis.poke();
        // climb imp0 to the bell: 13 forced +4 rolls
        for (uint256 i; i < 13; i++) {
            vm.warp(block.timestamp + 61);
            _rollForce(genesis, _imp(0), 4);
            if (i % 8 == 7) _roll(genesis, _imp(1));
            if (i == 12) {
                // the poke that resolves the bell roll also finalizes: every roll committed before the end is in
                vm.expectEmit(true, false, false, true, address(genesis));
                emit PadGame.BellRung(_imp(0), 50, uint64(block.timestamp));
                vm.expectEmit(false, false, false, false, address(genesis));
                emit PadGame.Ended(0, 0, 0, address(0), 0, 0, address(0), 0);
            }
            genesis.poke();
        }
        assertEq(genesis.bellRinger(), _imp(0));
        assertEq(genesis.endedAt(), uint64(block.timestamp));
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        assertEq(genesis.ringerPaid(), genesis.rankPool() / 4); // 20% ringer, 80% ranks
        vm.expectEmit(true, false, false, true, address(genesis));
        emit PadGame.Paid(_imp(0), 0, genesis.rankPool());
        genesis.poke(); // pays the single winner (ceil(2/2) = 1)
        // the pool is created inside the graduation call, so PadLiquidity's event precedes the game's
        vm.expectEmit(true, false, false, false, address(liq));
        emit PadLiquidity.GraduatedToPool(address(pvp), 0, 0, false, false);
        vm.expectEmit(false, false, false, false, address(genesis));
        emit PadGame.Graduated(0, 0, 0);
        vm.expectEmit(true, false, false, true, address(pad));
        emit PvPPad.GameDone(address(genesis), false);
        genesis.poke();
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
    }

    function test_launchAndBurnEmit() public {
        _graduateGenesis();
        vm.expectEmit(true, false, false, false, address(pad));
        emit PvPPad.Launched(1, address(0), address(0), "N", "T", "u", 0);
        pad.launch("N", "T", "u");
        PvPPad.Launch memory l = pad.getLaunch(1);
        assertEq(l.name, "N");
        assertEq(l.ticker, "T");
        assertEq(l.imageURL, "u");
        assertEq(PadToken(l.token).imageURL(), "u");
        assertEq(pad.launchCount(), 2);
        vm.deal(address(this), 1 ether);
        vm.expectEmit(true, false, false, true, address(liq));
        emit PadLiquidity.BurnDeposited(address(this), 0.01 ether);
        liq.depositBurn{value: 0.01 ether}();
        vm.warp(block.timestamp + 10 minutes);
        vm.expectEmit(false, false, false, false, address(liq));
        emit PadLiquidity.Burned(0.01 ether, 0);
        liq.burnChunk();
    }

    // ---------------------------------------------------------------- token
    function test_tokenTransferFailurePaths() public {
        _graduateGenesis();
        address holder = _imp(0);
        uint256 bal = pvp.balanceOf(holder);
        assertGt(bal, 0);
        vm.startPrank(holder);
        vm.expectRevert(bytes("zero to"));
        pvp.transfer(address(0), 1);
        vm.expectRevert(bytes("balance"));
        pvp.transfer(bob, bal + 1);
        pvp.approve(bob, 5);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(bytes("allowance"));
        pvp.transferFrom(holder, bob, 6);
        pvp.transferFrom(holder, bob, 5);
        assertEq(pvp.allowance(holder, bob), 0);
        vm.expectRevert(bytes("allowance"));
        pvp.transferFrom(holder, bob, 1);
        vm.stopPrank();
        // infinite allowance is not decremented
        vm.prank(holder);
        pvp.approve(bob, type(uint256).max);
        vm.prank(bob);
        pvp.transferFrom(holder, bob, 1);
        assertEq(pvp.allowance(holder, bob), type(uint256).max);
        assertEq(pvp.balanceOf(bob), 6);
        // unlock is PadLiquidity's alone
        vm.expectRevert(PadToken.NotLiquidity.selector);
        pvp.unlock();
    }

    function test_lockedTokenBlocksApprovedSpendersBeforeGraduation() public {
        _open();
        _mintN(genesis, 1);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        vm.prank(_imp(0));
        pvp.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(PadToken.Locked.selector);
        pvp.transferFrom(_imp(0), bob, 1);
        assertFalse(pvp.unlocked());
    }

    // ---------------------------------------------------------------- pad
    function test_padCallbacksRejectStrangers() public {
        vm.expectRevert(PvPPad.NotGame.selector);
        pad.onGameStarted();
        vm.expectRevert(PvPPad.NotGame.selector);
        pad.onGameFinalized();
        vm.expectRevert(PvPPad.NotGame.selector);
        pad.onGameDone(false);
        vm.expectRevert(PvPPad.NotAllowed.selector);
        pad.startGenesis();
        vm.prank(address(king));
        vm.expectRevert(PvPPad.NotAllowed.selector); // genesis exists already
        pad.startGenesis();
        vm.expectRevert(PvPPad.Nothing.selector);
        pad.claim();
        vm.expectRevert(PvPPad.NotOpen.selector);
        pad.launch("a", "b", "");
        _open();
        vm.prank(OWNER);
        vm.expectRevert(PvPPad.AlreadyOpened.selector);
        pad.openPad();
    }

    function test_upkeepIsSafeWithNothingToDo() public {
        pad.upkeep(address(this)); // before open: nothing started, liquidity bound, no king: must not revert
        assertEq(pad.upkeepCursor(), 0);
        _open();
        pad.upkeep(address(this));
        assertEq(pad.upkeepCursor(), 0);
        _mintN(genesis, 1); // the mint's own upkeep pokes the single started game
        assertEq(pad.upkeepCursor(), 1);
        pad.upkeep(address(this)); // one started game: cursor advances
        assertEq(pad.upkeepCursor(), 2);
    }

    // ---------------------------------------------------------------- game
    function test_fundPotRejectedAfterTheGameEnds() public {
        _graduateGenesis();
        vm.deal(address(pad), 1 ether);
        vm.prank(address(pad));
        vm.expectRevert(PadGame.BadPhase.selector);
        genesis.fundPot{value: 1}();
    }

    function test_clonesCannotBeReinitialized() public {
        vm.expectRevert(PadGame.AlreadyInitialized.selector);
        genesis.initialize(address(this), address(this), address(this), false);
        vm.expectRevert(PadToken.AlreadyInitialized.selector);
        pvp.initialize("x", "y", "", address(this), address(this));
    }

    function test_pokeBeforeFirstMintDoesNothing() public {
        _open();
        genesis.poke();
        assertEq(genesis.phase(), genesis.PHASE_WAITING());
        assertEq(genesis.endsBy(), 0);
        assertEq(genesis.playStart(), 0);
        assertFalse(genesis.isLive());
    }

    function test_finalizerFeeIsCappedAtFiveThousandths() public {
        _open();
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 r; r < 6; r++) {
            if (r != 0) vm.warp(block.timestamp + 9 minutes); // keep both alive until the 60-minute end
            _roll(genesis, _imp(0));
            _roll(genesis, _imp(1));
            arb.advance(5);
        }
        // a big pot: 0.5% would be 0.01 ETH, the cap is 0.005
        vm.deal(address(king), 2 ether);
        vm.prank(address(king));
        genesis.fundPot{value: 2 ether}();
        vm.warp(genesis.endsBy());
        uint256 potBefore = genesis.pot();
        assertEq(potBefore, 2 ether + 12 * 0.0002 ether);
        address finalizer = address(0xF1A1);
        vm.prank(finalizer);
        genesis.poke();
        assertEq(genesis.finalizerFee(), 0.005 ether);
        assertEq(finalizer.balance, 0.005 ether);
        assertEq(genesis.winnerCount(), 1);
        assertEq(genesis.rankPool(), potBefore - 0.005 ether); // no bell: all of the rest to ranks
        assertEq(genesis.ringerPaid(), 0);
    }

    function test_rankPaymentToReenteringWinnerIsHeldAndGameStateIsIntact() public {
        _open();
        ReenteringWinner w = new ReenteringWinner(genesis);
        w.mint();
        _mintN(genesis, 1);
        _toPlay(genesis);
        vm.deal(address(this), 1 ether); // the test funds the winner's rolls; the winner itself holds nothing
        for (uint256 r; r < 6; r++) {
            if (r != 0) vm.warp(block.timestamp + 9 minutes);
            w.roll{value: 0.002 ether}();
            PadGame.Imp memory im = genesis.getImp(address(w));
            _force(genesis, address(w), im.rolls, uint64(arb.n()), 4);
            arb.advance(4);
            _rollForce(genesis, _imp(0), -1);
            genesis.poke();
        }
        vm.warp(genesis.endsBy());
        uint256 potBefore = genesis.pot();
        genesis.poke(); // finalize
        assertEq(genesis.winners(0), address(w));
        uint256 rankPool = genesis.rankPool();
        genesis.poke(); // pay: the winner's receive re-enters poke(), which cannot run inside the payment
        assertEq(genesis.paidCount(), 1);
        assertEq(pad.claimable(address(w)), rankPool, "payment held for the re-entering winner");
        assertEq(address(w).balance, 0, "nothing reached the winner directly");
        assertEq(w.entered(), 0, "the re-entering receive reverted as a whole: nothing it did persisted");
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        assertEq(address(genesis).balance, genesis.curveEth());
        assertEq(potBefore - genesis.finalizerFee(), rankPool);
        genesis.poke(); // graduate
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
    }

    // ---------------------------------------------------------------- king
    function test_takeCrownClosedBeforeOpen() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.NotOpen.selector);
        king.takeCrown{value: 0.01 ether}();
    }

    /// The hold is exactly one hour: one second early is refused, the boundary second is allowed; the next bid
    /// needs exactly 110%, one wei less is refused.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_holdAndMinBidBoundaries(uint256 dt, uint256 firstBid) public {
        _graduateGenesis();
        firstBid = bound(firstBid, 0.01 ether, 1 ether);
        dt = bound(dt, 0, 2 hours);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 10 ether);
        vm.prank(alice);
        king.takeCrown{value: firstBid}();
        uint256 min = firstBid * 110 / 100;
        assertEq(king.minBid(), min);
        vm.warp(block.timestamp + dt);
        vm.prank(bob);
        vm.expectRevert(KingOfThePad.TooLow.selector);
        king.takeCrown{value: min - 1}();
        if (dt < 1 hours) {
            assertFalse(king.canTake());
            vm.prank(bob);
            vm.expectRevert(KingOfThePad.TooSoon.selector);
            king.takeCrown{value: min}();
            assertEq(king.king(), alice);
        } else {
            assertTrue(king.canTake());
            vm.prank(bob);
            king.takeCrown{value: min}();
            assertEq(king.king(), bob);
            // refunded in full at once, plus the LP fees collected for her while she was king
            assertGe(alice.balance, 1 ether, "old king refunded in full");
            assertLt(alice.balance, 1 ether + 0.001 ether);
        }
    }

    function test_reenteringKingRefundIsHeldAndCrownChanges() public {
        _graduateGenesis();
        ReenteringKing rk = new ReenteringKing(king);
        vm.deal(address(this), 1 ether);
        rk.bid{value: 0.02 ether}();
        assertEq(king.king(), address(rk));
        assertEq(address(rk).balance, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        king.takeCrown{value: 0.03 ether}();
        assertEq(king.king(), bob);
        assertEq(king.bid(), 0.03 ether);
        assertEq(address(rk).balance, 0, "nothing reached the re-entering king directly");
        assertEq(rk.entered(), 0, "the re-entering receive reverted as a whole (Reentrant): nothing persisted");
        assertGe(pad.claimable(address(rk)), 0.02 ether, "refund held in the pad");
        assertEq(address(king).balance, 0);
        // the held refund is claimable later: the claim's send has full gas and the king contract is unlocked,
        // so the re-entered distribute(1) simply runs (nothing to collect) and the claim completes
        uint256 owed = pad.claimable(address(rk));
        vm.prank(address(rk));
        pad.claim();
        assertEq(address(rk).balance, owed);
        assertEq(pad.claimable(address(rk)), 0);
        assertEq(address(king).balance, 0);
    }

    function test_distributeClampsAndStrandsNothing() public {
        _graduateGenesis();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.01 ether}();
        uint256 before = alice.balance;
        king.distribute(0);
        assertEq(alice.balance, before);
        king.distribute(7); // more than the pool count is clamped to one pass over the single pool
        assertEq(liq.distributeCursor(), 2); // 1 from the upkeep inside the first takeCrown, 1 now
        assertGe(alice.balance, before); // the burn chunk inside takeCrown's upkeep left fees for the king
        assertEq(address(liq).balance, liq.burnBucket());
        assertEq(address(king).balance, 0);
        before = alice.balance;
        king.distribute(7); // nothing left to collect
        assertEq(alice.balance, before);
    }

    // ---------------------------------------------------------------- curve
    /// The curve quote is monotone in ETH and never exceeds what is left.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_quoteMonotone(uint256 a, uint256 b) public view {
        a = bound(a, 0, 10 ether);
        b = bound(b, a, 10 ether);
        assertLe(genesis.quote(a), genesis.quote(b));
        assertEq(genesis.quote(0), 0);
    }

    /// Every roll keeps the virtual product at or above K and the reserves consistent with what was sold.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_curveProductNeverDrops(uint8 n) public {
        _open();
        _mintN(genesis, 1);
        _toPlay(genesis);
        n = uint8(bound(n, 1, 40));
        uint256 sold;
        for (uint256 i; i < n; i++) {
            uint256 q = genesis.quote(0.0018 ether);
            _roll(genesis, _imp(0));
            (uint256 vEth, uint256 vTok) = genesis.reserves();
            assertGe(vEth * vTok, 1 ether * 1e9 ether, "k dropped");
            assertEq(genesis.tokensSold() - sold, q, "quote differs from the buy");
            sold = genesis.tokensSold();
            assertEq(pvp.balanceOf(_imp(0)), sold);
            arb.advance(5);
            vm.warp(block.timestamp + 60);
        }
    }

    receive() external payable {}
}
