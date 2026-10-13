// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Rejecter} from "./Harness.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";

contract KingTest is Harness {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_kingClosedUntilGenesisGraduates() public {
        _open();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.GenesisPending.selector);
        king.takeCrown{value: 0.01 ether}();
    }

    function test_firstBidAndSplitToCarry() public {
        _graduateGenesis();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.TooLow.selector);
        king.takeCrown{value: 0.009 ether}();
        uint256 devBefore = OWNER.balance;
        uint256 carryBefore = pad.carryPot();
        vm.prank(alice);
        king.takeCrown{value: 0.02 ether}();
        assertEq(king.king(), alice);
        assertEq(king.bid(), 0.02 ether);
        assertEq(king.crownedAt(), uint64(block.timestamp));
        // whole first bid is "extra": 50% pots (no live game: carry), 25% burn, 25% dev
        assertEq(pad.carryPot() - carryBefore, 0.01 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedEth(), 0.005 ether); // upkeep may already have burned a chunk
        assertEq(OWNER.balance - devBefore, 0.005 ether);
        assertEq(king.totalToPots(), 0.01 ether);
        assertEq(king.totalToBurn(), 0.005 ether);
        assertEq(king.totalToDev(), 0.005 ether);
        assertEq(address(king).balance, 0);
        assertEq(king.minBid(), 0.022 ether);
    }

    function test_secondBidRefundsAndRequiresHold() public {
        _graduateGenesis();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.02 ether}();
        vm.prank(bob);
        vm.expectRevert(KingOfThePad.TooLow.selector);
        king.takeCrown{value: 0.021 ether}();
        vm.prank(bob);
        vm.expectRevert(KingOfThePad.TooSoon.selector);
        king.takeCrown{value: 0.022 ether}();
        vm.warp(block.timestamp + 1 hours);
        uint256 aliceBefore = alice.balance;
        uint256 carryBefore = pad.carryPot();
        uint256 burnBefore = liq.burnBucket() + liq.totalBurnedEth();
        uint256 devBefore = OWNER.balance;
        vm.prank(bob);
        king.takeCrown{value: 0.03 ether}();
        assertEq(king.king(), bob);
        // refunded in full at once, plus the LP fees the burn chunk generated while alice was king
        assertGe(alice.balance - aliceBefore, 0.02 ether);
        assertLt(alice.balance - aliceBefore, 0.0201 ether);
        // extra = 0.01: 0.005 pots (carry), 0.0025 burn, 0.0025 dev
        assertEq(pad.carryPot() - carryBefore, 0.005 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedEth() - burnBefore, 0.0025 ether);
        assertEq(OWNER.balance - devBefore, 0.0025 ether);
        assertEq(address(king).balance, 0);
    }

    function test_refundToRejectingKingIsHeld() public {
        _graduateGenesis();
        Rejecter rj = new Rejecter();
        vm.deal(address(rj), 1 ether);
        vm.prank(address(rj));
        king.takeCrown{value: 0.02 ether}();
        vm.warp(block.timestamp + 1 hours);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        king.takeCrown{value: 0.03 ether}();
        assertGe(pad.claimable(address(rj)), 0.02 ether); // refund (plus collected fees) held for the rejecting king
        assertEq(address(pad).balance, pad.totalClaimable() + pad.carryPot());
        vm.prank(address(rj));
        vm.expectRevert(PvPPad.SendFailed.selector);
        pad.claim();
    }

    function test_splitGoesToLiveGamePots() public {
        _graduateGenesis();
        (, address g1) = pad.launch("One", "ONE", "");
        (, address g2) = pad.launch("Two", "TWO", "");
        (, address g3) = pad.launch("Three", "THR", ""); // never starts: not live
        vm.prank(_imp(1));
        PadGame(g1).mint();
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(_imp(2));
        PadGame(g2).mint();
        address[] memory live = pad.liveGames(10);
        assertEq(live.length, 2);
        assertEq(live[0], g1); // soonest ending first
        assertEq(live[1], g2);
        uint256 p1 = PadGame(g1).pot();
        uint256 p2 = PadGame(g2).pot();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.02 ether}();
        assertEq(PadGame(g1).pot() - p1, 0.005 ether);
        assertEq(PadGame(g2).pot() - p2, 0.005 ether);
        assertEq(PadGame(g3).pot(), 0);
        assertEq(pad.carryPot(), 0);
    }

    function test_liveGamesCappedAtTenSoonestEnding() public {
        _graduateGenesis();
        address[] memory games = new address[](13);
        for (uint256 i; i < 13; i++) {
            (, games[i]) = pad.launch("G", "G", "");
        }
        // start them in reverse order so the soonest ending are the last launched
        for (uint256 i = 13; i > 0; i--) {
            vm.prank(_imp(i));
            PadGame(games[i - 1]).mint();
            vm.warp(block.timestamp + 10);
        }
        address[] memory live = pad.liveGames(10);
        assertEq(live.length, 10);
        assertEq(live[0], games[12]);
        assertEq(live[9], games[3]);
    }

    /// @dev Free launches that never start are not scanned: they cannot hide live games from the king split nor
    ///      receive upkeep pokes.
    function test_launchSpamDoesNotHideLiveGamesOrStarveUpkeep() public {
        _graduateGenesis();
        address spammer = address(0x5BAD);
        for (uint256 i; i < 64; i++) {
            vm.prank(spammer);
            pad.launch("spam", "SPAM", "");
        }
        (, address g) = pad.launch("Honest", "HON", "");
        vm.prank(_imp(1));
        PadGame(g).mint();
        assertEq(pad.activeCount(), 65);
        assertEq(pad.startedCount(), 1);
        assertEq(pad.startedGame(0), g);
        address[] memory live = pad.liveGames(10);
        assertEq(live.length, 1);
        assertEq(live[0], g);
        uint256 p = PadGame(g).pot();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.02 ether}();
        assertEq(PadGame(g).pot() - p, 0.01 ether, "live game gets the 50%");
        assertEq(pad.carryPot(), 0);
        // upkeep pokes the started game, never the 64 waiting ones: the due game is finalized by a stranger's call
        _toPlay(PadGame(g));
        _roll(PadGame(g), _imp(1));
        arb.advance(5);
        vm.warp(PadGame(g).endsBy());
        pad.upkeep(address(this));
        assertEq(PadGame(g).phase(), PadGame(g).PHASE_PAYING());
        assertEq(pad.startedCount(), 0);
        assertEq(pad.settlingCount(), 1);
        assertEq(pad.settlingGame(0), g);
        pad.upkeep(address(this)); // pays the single winner
        pad.upkeep(address(this)); // graduates
        assertEq(PadGame(g).phase(), PadGame(g).PHASE_GRADUATED());
        assertEq(pad.settlingCount(), 0);
        assertEq(pad.activeCount(), 64);
    }

    function test_liveGamesZeroReturnsEmpty() public {
        _graduateGenesis();
        (, address g) = pad.launch("One", "ONE", "");
        vm.prank(_imp(1));
        PadGame(g).mint();
        assertTrue(PadGame(g).isLive());
        assertEq(pad.liveGames(0).length, 0);
        assertEq(pad.liveGames(1).length, 1);
    }

    function test_endedGamesLeaveTheLiveScan() public {
        _graduateGenesis();
        (, address g1) = pad.launch("One", "ONE", "");
        (, address g2) = pad.launch("Two", "TWO", "");
        vm.prank(_imp(1));
        PadGame(g1).mint();
        vm.warp(block.timestamp + 15 minutes);
        vm.prank(_imp(2));
        PadGame(g2).mint();
        vm.warp(PadGame(g1).playStart() + 10 minutes + 1); // g1: everyone dead, ended but not yet finalized
        assertFalse(PadGame(g1).isLive());
        address[] memory live = pad.liveGames(10);
        assertEq(live.length, 1);
        assertEq(live[0], g2);
        PadGame(g1).poke(); // finalize: leaves the started list
        assertEq(pad.startedCount(), 1);
        assertEq(pad.startedGame(0), g2);
    }

    function test_takeCrownDistributesFirst() public {
        _graduateGenesis();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        king.takeCrown{value: 0.02 ether}();
        // distribute with no fees: harmless
        king.distribute(2);
        assertEq(liq.distributeCursor(), 2);
    }
}
