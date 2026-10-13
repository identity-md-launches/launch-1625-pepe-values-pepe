// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Rejecter} from "./Harness.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";

contract GameTest is Harness {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        _open();
    }

    // ------------------------------------------------------------ signup
    function test_firstMintStartsSignup() public {
        assertEq(genesis.phase(), genesis.PHASE_WAITING());
        _mintN(genesis, 1);
        assertEq(genesis.phase(), genesis.PHASE_RUNNING());
        assertEq(genesis.firstMintAt(), uint64(block.timestamp));
        assertEq(genesis.playStart(), uint64(block.timestamp + 10 minutes));
        assertEq(genesis.endsBy(), uint64(block.timestamp + 60 minutes));
        assertTrue(genesis.isLive());
        // one per wallet
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.AlreadyMinted.selector);
        genesis.mint();
        // late signup
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(_imp(5));
        vm.expectRevert(PadGame.BadPhase.selector);
        genesis.mint();
    }

    function test_maxImps() public {
        _mintN(genesis, 200);
        assertEq(genesis.impCount(), 200);
        vm.prank(_imp(200));
        vm.expectRevert(PadGame.Full.selector);
        genesis.mint();
    }

    // ------------------------------------------------------------ rolls and curve
    function test_rollRequiresPlayPhaseImpAndPrice() public {
        _mintN(genesis, 1);
        vm.deal(_imp(0), 1 ether);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.BadPhase.selector); // still signup
        genesis.roll{value: 0.002 ether}();
        _toPlay(genesis);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.BadValue.selector);
        genesis.roll{value: 0.001 ether}();
        vm.deal(_imp(9), 1 ether);
        vm.prank(_imp(9));
        vm.expectRevert(PadGame.NotImp.selector);
        genesis.roll{value: 0.002 ether}();
    }

    function test_rollSplitGenesisBurnToPot() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        uint256 expectTokens = genesis.quote(0.0018 ether);
        _roll(genesis, _imp(0));
        assertEq(pvp.balanceOf(_imp(0)), expectTokens);
        assertEq(genesis.curveEth(), 0.0018 ether);
        assertEq(genesis.pot(), 0.0002 ether); // 8% + the 2% burn share (genesis)
        assertEq(liq.burnBucket(), 0);
        assertEq(genesis.tokensSold(), expectTokens);
        assertEq(genesis.pendingCount(), 1);
        // tokens are locked for holders until graduation
        vm.prank(_imp(0));
        vm.expectRevert(PadToken.Locked.selector);
        pvp.transfer(address(1), 1);
    }

    function test_curveMath() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        (uint256 vE, uint256 vT) = genesis.reserves();
        assertEq(vE, 1 ether);
        assertEq(vT, 1e9 ether);
        // virtual constant product: 1 ETH in buys half the supply
        uint256 q = genesis.quote(1 ether);
        assertApproxEqAbs(q, 5e8 ether, 1e6);
        // 4 ETH sells exactly the 800M curve
        assertEq(genesis.quote(4 ether), 8e8 ether);
        assertEq(genesis.quote(5 ether), 8e8 ether);
        _roll(genesis, _imp(0));
        (vE, vT) = genesis.reserves();
        assertEq(vE, 1.0018 ether);
        assertApproxEqAbs(vE * vT, 1e45, vE); // invariant up to the rounding of the reserve
    }

    function test_cooldownAndDeath() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        arb.advance(5);
        vm.deal(_imp(0), 1 ether);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.Cooldown.selector);
        genesis.roll{value: 0.002 ether}();
        vm.warp(block.timestamp + 60);
        _roll(genesis, _imp(0));
        arb.advance(5);
        // dead after 10 minutes without a roll
        vm.warp(block.timestamp + 10 minutes + 1);
        assertFalse(genesis.isAlive(_imp(0)));
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.BadPhase.selector); // everyone dead: the game has ended
        genesis.roll{value: 0.002 ether}();
    }

    function test_deathWithoutEverRolling() public {
        _mintN(genesis, 2);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        arb.advance(5);
        vm.warp(block.timestamp + 9 minutes);
        _roll(genesis, _imp(0));
        arb.advance(5);
        vm.warp(genesis.playStart() + 10 minutes + 1);
        assertTrue(genesis.isLive());
        assertTrue(genesis.isAlive(_imp(0)));
        assertFalse(genesis.isAlive(_imp(1)));
        vm.deal(_imp(1), 1 ether);
        vm.prank(_imp(1));
        vm.expectRevert(PadGame.Dead.selector);
        genesis.roll{value: 0.002 ether}();
    }

    // ------------------------------------------------------------ RNG
    function test_rngCommitAndResolve() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        uint64 commit = uint64(arb.n());
        _roll(genesis, _imp(0));
        PadGame.Pending memory p = genesis.getPending(0);
        assertEq(p.imp, _imp(0));
        assertEq(p.nonce, 1);
        assertEq(p.commitBlock, commit);
        // not resolvable until block commit+4
        arb.advance(3);
        genesis.poke();
        assertEq(genesis.pendingCount(), 1);
        arb.advance(1);
        genesis.poke();
        assertEq(genesis.pendingCount(), 0);
        PadGame.Imp memory im = genesis.getImp(_imp(0));
        bytes32 h1 = arb.arbBlockHash(commit + 1);
        bytes32 h2 = arb.arbBlockHash(commit + 2);
        bytes32 h3 = arb.arbBlockHash(commit + 3);
        uint256 r = uint256(keccak256(abi.encode(address(genesis), _imp(0), uint32(1), h1, h2, h3))) % 8;
        int8 expectDelta = r < 4 ? -int8(int256(4 - r)) : int8(int256(r - 3));
        assertEq(im.height, expectDelta);
        assertTrue(expectDelta != 0 && expectDelta >= -4 && expectDelta <= 4);
        assertEq(im.resolvedNonce, 1);
        assertEq(im.heightSeq, 1);
    }

    function test_rngWindowMissedFromZeroStaysZero() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        arb.advance(300);
        genesis.poke();
        assertEq(genesis.pendingCount(), 0);
        assertEq(genesis.getImp(_imp(0)).height, 0);
        assertEq(genesis.getImp(_imp(0)).resolvedNonce, 1);
    }

    /// @dev The reviewer's withholding scenario: the roller resolves good dice and lets bad dice expire. An
    ///      expired roll now costs MISSED_PENALTY toward zero, so expiring is never better than resolving.
    function test_withholdingBadRollsNeverHelps() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        _rollForce(genesis, _imp(0), 4);
        genesis.poke();
        assertEq(genesis.getImp(_imp(0)).height, 4);
        vm.warp(block.timestamp + 61);
        _rollForce(genesis, _imp(0), -4); // bad die, determined at commit+3, left unresolved
        arb.advance(260); // past the 256-block window
        vm.warp(block.timestamp + 65);
        _rollForce(genesis, _imp(0), 3); // the own roll resolves the previous one: expired
        assertEq(genesis.getImp(_imp(0)).height, 0, "expired roll moved 4 toward zero, same as the honest -4");
        genesis.poke();
        assertEq(genesis.getImp(_imp(0)).height, 3);
        // generalised: +4, -4(expired), +3, -3(expired), +2, -4(expired): honest sum is -2, |h| = 2
        int8[3] memory next = [int8(-3), 2, -4];
        for (uint256 i; i < next.length; i++) {
            vm.warp(block.timestamp + 61);
            _rollForce(genesis, _imp(0), next[i]);
            if (next[i] > 0) genesis.poke();
            else arb.advance(260);
        }
        vm.warp(block.timestamp + 61);
        _roll(genesis, _imp(0)); // resolves the last expired roll
        int8 h = genesis.getImp(_imp(0)).height;
        assertLe(h, 2, "withholding must not beat the dice");
        assertEq(h, 0); // 4 -> 0 (expired) -> 3 -> 0 (expired) -> 2 -> 0 (expired)
    }

    function test_missedPenaltyPullsTowardZeroFromBothSidesAndNeverPastIt() public {
        _mintN(genesis, 2);
        _toPlay(genesis);
        _rollForce(genesis, _imp(0), -2);
        _rollForce(genesis, _imp(1), 4);
        genesis.poke();
        assertEq(genesis.getImp(_imp(0)).height, -2);
        vm.warp(block.timestamp + 61);
        _roll(genesis, _imp(0));
        _roll(genesis, _imp(1));
        arb.advance(300);
        genesis.poke();
        assertEq(genesis.getImp(_imp(0)).height, 0, "-2 + penalty stops at 0");
        assertEq(genesis.getImp(_imp(1)).height, 0, "4 - 4");
    }

    function test_resolveBatchOfEightAndOwnRollResolvesPrevious() public {
        _mintN(genesis, 12);
        _toPlay(genesis);
        for (uint256 i; i < 12; i++) {
            _roll(genesis, _imp(i));
        }
        assertEq(genesis.pendingCount(), 12);
        arb.advance(4);
        genesis.poke();
        assertEq(genesis.pendingCount(), 4); // 8 oldest resolved
        // imp 11's own roll resolves its previous one even though it is last in the queue
        vm.warp(block.timestamp + 60);
        _roll(genesis, _imp(11));
        assertEq(genesis.getImp(_imp(11)).resolvedNonce, 1);
        assertEq(genesis.getImp(_imp(11)).rolls, 2);
        // the queue entry it skipped is dropped when reached
        arb.advance(4);
        genesis.poke();
        assertEq(genesis.pendingCount(), 0);
        assertEq(genesis.getImp(_imp(11)).resolvedNonce, 2);
    }

    function test_rollRevertsWhenPreviousUnresolvable() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        vm.warp(block.timestamp + 60); // cooldown over but no new L2 blocks
        vm.deal(_imp(0), 1 ether);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.Unresolved.selector);
        genesis.roll{value: 0.002 ether}();
    }

    // ------------------------------------------------------------ bell, clamp, end
    function test_bellRingsAtPlusFifty() public {
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 i; i < 13; i++) {
            _rollForce(genesis, _imp(0), 4);
            _rollForce(genesis, _imp(1), -1);
            genesis.poke();
            vm.warp(block.timestamp + 60);
        }
        PadGame.Imp memory im = genesis.getImp(_imp(0));
        assertEq(im.height, 50); // 13 * 4 = 52 clamped at 50
        assertEq(genesis.bellRinger(), _imp(0));
        assertTrue(genesis.endedAt() != 0);
        assertFalse(genesis.isLive());
        vm.deal(_imp(1), 1 ether);
        vm.prank(_imp(1));
        vm.expectRevert(PadGame.BadPhase.selector);
        genesis.roll{value: 0.002 ether}();
        // the poke after the bell already finalized: 26 rolls x 0.0002 ETH (8% + genesis burn share) were in the pot
        uint256 potBefore = 26 * 0.0002 ether;
        uint256 b0 = _imp(0).balance - 0.002 ether * 0; // imp0 was paid inside that poke
        uint256 bThis = address(this).balance;
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        uint256 fee = potBefore * 5 / 1000;
        if (fee > 0.005 ether) fee = 0.005 ether;
        assertEq(genesis.finalizerFee(), fee);
        bThis;
        b0;
        uint256 rest = potBefore - fee;
        assertEq(genesis.ringerPaid(), rest * 20 / 100);
        assertEq(_imp(0).balance, rest * 20 / 100); // imp0 spent every wei it was dealt on rolls
        assertEq(genesis.rankPool(), rest - rest * 20 / 100);
        assertEq(genesis.winnerCount(), 1); // ceil(2/2)
        assertEq(genesis.winners(0), _imp(0));
    }

    /// @dev Two imps whose pending rolls both reach 50: the older commit rings, whoever resolves first. The imp
    ///      whose own roll() would ring the bell out of order is refused (play ended), and the tie-break follows
    ///      commit order.
    function test_bellAndTieBreakFollowCommitOrder() public {
        _mintN(genesis, 2);
        _toPlay(genesis);
        for (uint256 i; i < 12; i++) {
            _rollForce(genesis, _imp(0), 4);
            _rollForce(genesis, _imp(1), 4);
            genesis.poke();
            vm.warp(block.timestamp + 60);
        }
        assertEq(genesis.getImp(_imp(0)).height, 48);
        assertEq(genesis.getImp(_imp(1)).height, 48);
        // round 13: A commits first, B three blocks later; both land on +4
        _roll(genesis, _imp(0));
        _force(genesis, _imp(0), 13, uint64(arb.n()), 4);
        arb.advance(3);
        _roll(genesis, _imp(1));
        _force(genesis, _imp(1), 13, uint64(arb.n()), 4);
        arb.advance(4);
        vm.warp(block.timestamp + 60);
        uint256 potBefore = genesis.pot();
        // B tries to jump the queue: its own roll would resolve B's roll first and ring the bell -> refused
        vm.deal(_imp(1), 1 ether);
        vm.prank(_imp(1));
        vm.expectRevert(PadGame.BadPhase.selector);
        genesis.roll{value: 0.002 ether}();
        assertEq(genesis.pot(), potBefore);
        assertEq(genesis.bellRinger(), address(0));
        genesis.poke(); // resolves in commit order: A rings, B also reaches 50 afterwards
        assertEq(genesis.bellRinger(), _imp(0));
        assertEq(genesis.getImp(_imp(0)).height, 50);
        assertEq(genesis.getImp(_imp(1)).height, 50);
        assertLt(genesis.getImp(_imp(0)).heightSeq, genesis.getImp(_imp(1)).heightSeq);
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        assertEq(genesis.winners(0), _imp(0), "tie at 50 goes to the earlier commit");
    }

    /// @dev heightSeq is the commit position even when a later roll is resolved first (own-roll resolution).
    function test_tieBreakIgnoresResolutionOrder() public {
        _mintN(genesis, 2);
        _toPlay(genesis);
        _roll(genesis, _imp(0)); // A commits first
        _force(genesis, _imp(0), 1, uint64(arb.n()), 3);
        arb.advance(3); // B's hash blocks do not overlap A's forced one
        _roll(genesis, _imp(1)); // B commits later
        _force(genesis, _imp(1), 1, uint64(arb.n()), 3);
        arb.advance(4);
        vm.warp(block.timestamp + 60);
        _roll(genesis, _imp(1)); // B's own roll resolves B's first roll before the batch reaches A's older one
        assertEq(genesis.getImp(_imp(1)).height, 3);
        assertEq(genesis.getImp(_imp(0)).height, 3);
        assertLt(genesis.getImp(_imp(0)).heightSeq, genesis.getImp(_imp(1)).heightSeq, "A reached 3 first");
    }

    /// @dev A roll whose own-roll resolution rings the bell is refused: nothing is charged or queued after the end.
    function test_rollAfterOwnBellIsRefused() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        for (uint256 i; i < 12; i++) {
            _rollForce(genesis, _imp(0), 4);
            genesis.poke();
            vm.warp(block.timestamp + 60);
        }
        _rollForce(genesis, _imp(0), 4); // resolvable but unresolved: would reach 50
        vm.warp(block.timestamp + 61);
        uint256 potBefore = genesis.pot();
        vm.deal(_imp(0), 1 ether);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.BadPhase.selector);
        genesis.roll{value: 0.002 ether}();
        assertEq(genesis.pot(), potBefore);
        assertEq(genesis.endedAt(), 0);
        assertEq(genesis.getImp(_imp(0)).rolls, 13);
        genesis.poke();
        assertEq(genesis.bellRinger(), _imp(0));
        assertEq(genesis.getImp(_imp(0)).resolvedNonce, 13);
        assertEq(genesis.pendingCount(), 0);
    }

    function test_negativeClampAndBell() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        for (uint256 i; i < 13; i++) {
            _rollForce(genesis, _imp(0), -4);
            genesis.poke();
            vm.warp(block.timestamp + 60);
        }
        assertEq(genesis.getImp(_imp(0)).height, -50);
        assertEq(genesis.bellRinger(), _imp(0));
    }

    function test_rankingTiesAndTriangularSplit() public {
        _mintN(genesis, 5);
        _toPlay(genesis);
        // six rounds nine minutes apart keep imps 0..3 alive to the 60 minute end; imp4 never rolls and dies
        int8[6] memory d0 = [int8(4), 4, 1, -1, 1, -1]; // 8
        int8[6] memory d1 = [int8(4), 4, 1, -1, 1, -1]; // 8, reached later than imp0
        int8[6] memory d2 = [int8(-4), -1, 1, -1, 1, -1]; // -5
        int8[6] memory d3 = [int8(1), 1, -1, 1, -1, 1]; // 2
        for (uint256 r; r < 6; r++) {
            if (r != 0) vm.warp(block.timestamp + 9 minutes);
            _rollForce(genesis, _imp(0), d0[r]);
            _rollForce(genesis, _imp(1), d1[r]);
            _rollForce(genesis, _imp(2), d2[r]);
            _rollForce(genesis, _imp(3), d3[r]);
            genesis.poke();
        }
        assertEq(genesis.getImp(_imp(0)).height, 8);
        assertEq(genesis.getImp(_imp(1)).height, 8);
        assertEq(genesis.getImp(_imp(2)).height, -5);
        assertEq(genesis.getImp(_imp(3)).height, 2);
        assertLt(genesis.getImp(_imp(0)).heightSeq, genesis.getImp(_imp(1)).heightSeq);
        vm.warp(genesis.endsBy());
        assertTrue(genesis.isAlive(_imp(0)));
        assertFalse(genesis.isAlive(_imp(4)));
        uint256 potBefore = genesis.pot();
        uint256[4] memory before = [_imp(0).balance, _imp(1).balance, _imp(2).balance, _imp(3).balance];
        genesis.poke(); // finalize: 4 living (imp4 dead), top 2 paid
        assertEq(genesis.winnerCount(), 2);
        assertEq(genesis.winners(0), _imp(0)); // tie at |8| with imp1, imp0 reached it first
        assertEq(genesis.winners(1), _imp(1));
        assertEq(genesis.bellRinger(), address(0));
        uint256 fee = potBefore * 5 / 1000;
        if (fee > 0.005 ether) fee = 0.005 ether;
        uint256 pool = potBefore - fee;
        assertEq(genesis.rankPool(), pool); // no bell: everything to the ranks
        genesis.poke(); // pay batch
        assertEq(_imp(0).balance - before[0], pool * 2 / 3);
        assertEq(_imp(1).balance - before[1], pool * 1 / 3);
        assertEq(_imp(2).balance, before[2]);
        assertEq(_imp(3).balance, before[3]);
        assertEq(genesis.paidCount(), 2);
        assertEq(genesis.pot(), 0);
        // dust went to the carry pot, curve ETH is intact for graduation
        assertEq(address(genesis).balance, genesis.curveEth());
    }

    function test_allDeadCarriesPot() public {
        _mintN(genesis, 2);
        _toPlay(genesis);
        _roll(genesis, _imp(0));
        _roll(genesis, _imp(1));
        arb.advance(5);
        vm.warp(block.timestamp + 10 minutes + 1);
        uint256 potBefore = genesis.pot();
        assertFalse(genesis.isLive());
        genesis.poke();
        assertEq(genesis.phase(), genesis.PHASE_PAYING());
        assertEq(genesis.winnerCount(), 0);
        uint256 fee = potBefore * 5 / 1000;
        assertEq(pad.carryPot(), potBefore - fee);
        genesis.poke(); // graduates (ETH was raised)
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
    }

    function test_failedSendIsClaimable() public {
        Rejecter rj = new Rejecter();
        vm.prank(address(rj));
        genesis.mint();
        _mintN(genesis, 1);
        _toPlay(genesis);
        for (uint256 r; r < 6; r++) {
            if (r != 0) vm.warp(block.timestamp + 9 minutes);
            _rollForce(genesis, address(rj), r % 2 == 0 ? int8(4) : int8(-1));
            _rollForce(genesis, _imp(0), r % 2 == 0 ? int8(1) : int8(-1));
            genesis.poke();
        }
        vm.warp(genesis.endsBy());
        uint256 potBefore = genesis.pot();
        genesis.poke();
        genesis.poke();
        uint256 fee = potBefore * 5 / 1000;
        uint256 pool = potBefore - fee;
        assertEq(genesis.winners(0), address(rj));
        assertEq(pad.claimable(address(rj)), pool); // 1 winner of 2 living, push failed, held in the pad
        assertEq(address(pad).balance, pool);
    }

    function test_payoutBatchesOfTwentyFive() public {
        _mintN(genesis, 120);
        _toPlay(genesis);
        for (uint256 i; i < 120; i++) {
            _roll(genesis, _imp(i));
        }
        arb.advance(5);
        // imp0 climbs to the bell in 13 minutes; everyone else rolls again at minute 9 to stay alive
        for (uint256 m = 1; m <= 13; m++) {
            vm.warp(block.timestamp + 60);
            _rollForce(genesis, _imp(0), 4);
            if (m == 9) {
                for (uint256 i = 1; i < 120; i++) {
                    _roll(genesis, _imp(i));
                }
                arb.advance(5);
            }
        }
        _settle(genesis); // resolves 8 per poke until the bell resolves, then finalizes, pays 25 per poke, graduates
        assertEq(genesis.bellRinger(), _imp(0)); // resolve 8 per poke, finalize, pay 25 per poke, graduate
        assertEq(genesis.winnerCount(), 60);
        assertEq(genesis.paidCount(), 60);
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
        uint256 total;
        for (uint256 i; i < 120; i++) {
            total += _imp(i).balance;
        }
        assertGt(total, 0);
    }

    function test_soldOutCurveSendsRollToPot() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        // 2,223 rolls would be needed; the curve state is written directly to reach the sold-out branch
        stdstore.target(address(genesis)).sig("tokensSold()").checked_write(uint256(8e8 ether));
        stdstore.target(address(genesis)).sig("curveEth()").checked_write(uint256(4 ether));
        vm.deal(address(genesis), address(genesis).balance + 4 ether);
        assertTrue(genesis.curveSoldOut());
        assertEq(genesis.quote(0.0018 ether), 0);
        uint256 potBefore = genesis.pot();
        uint256 curveBefore = genesis.curveEth();
        _roll(genesis, _imp(0));
        assertEq(genesis.pot() - potBefore, 0.002 ether); // 90% + 8% + 2% (genesis)
        assertEq(genesis.curveEth(), curveBefore);
        assertEq(pvp.balanceOf(_imp(0)), 0);
    }

    /// @dev The roll that sells the curve out pays only for the tokens left; the rest of its 90% goes to the pot.
    function test_soldOutCrossingRollPaysOnlyForWhatIsLeft() public {
        _mintN(genesis, 1);
        _toPlay(genesis);
        uint256 left = 10_000 ether; // tokens still on the curve
        uint256 vTok = 2e8 ether + left;
        uint256 vEth = (1e45 + vTok - 1) / vTok; // consistent virtual ETH reserve for that point of the curve
        stdstore.target(address(genesis)).sig("tokensSold()").checked_write(uint256(8e8 ether) - left);
        stdstore.target(address(genesis)).sig("curveEth()").checked_write(vEth - 1 ether);
        vm.deal(address(genesis), address(genesis).balance + vEth - 1 ether);
        assertGt(genesis.quote(0.0018 ether), left - 1); // 0.0018 ETH would buy more than is left
        assertEq(genesis.quote(0.0018 ether), left);
        uint256 potBefore = genesis.pot();
        _roll(genesis, _imp(0));
        assertEq(pvp.balanceOf(_imp(0)), left);
        assertTrue(genesis.curveSoldOut());
        assertEq(genesis.curveEth(), 4 ether, "the curve ends at exactly 4 ETH");
        uint256 cost = 5 ether - vEth;
        assertLt(cost, 0.0018 ether);
        assertEq(genesis.pot() - potBefore, 0.002 ether - cost, "overpayment went to the pot");
        assertEq(address(genesis).balance, genesis.pot() + genesis.curveEth());
        (uint256 e, uint256 t) = genesis.reserves();
        assertEq(e, 5 ether);
        assertEq(t, 2e8 ether);
    }

    function test_fundPotOnlyPadOrKing() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(PadGame.NotPad.selector);
        genesis.fundPot{value: 1}();
        vm.prank(address(pad));
        vm.deal(address(pad), 1 ether);
        genesis.fundPot{value: 1}();
        assertEq(genesis.pot(), 1);
    }

    function test_pokeFromOnlyPad() public {
        vm.expectRevert(PadGame.NotPad.selector);
        genesis.pokeFrom(address(this));
    }

    receive() external payable {}
}
