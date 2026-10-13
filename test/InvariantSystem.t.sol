// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Harness, MockArbSys, Rejecter, Swapper} from "./Harness.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";

/// @dev Drives the whole system after the genesis launch graduated: crown bids (some from a receiver that
///      rejects ETH), fee distribution, burn chunks, burn and carry deposits, pool swaps that generate fees,
///      new launches with their games, upkeep and escrow claims, all in random order with bounded inputs.
///      Every rule the brief states for these calls is asserted inside the handler (a call must succeed
///      exactly when the rule allows it), and the ghost totals feed the invariants below.
contract SystemHandler is Test {
    PvPPad public pad;
    PadLiquidity public liq;
    KingOfThePad public king;
    PadToken public pvp;
    MockArbSys public arb;
    Swapper public swapper;
    address constant DEV = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address[] public actors;
    PadGame[] public games;
    uint256 public constant MAX_LAUNCHES = 3;

    // ghosts
    mapping(address => uint256) public funded; // ETH dealt to the actor by the handler
    mapping(address => uint256) public extraPaid; // part of each bid that is split away (never refunded)
    mapping(address => uint256) public spent; // rolls, burn and carry deposits made by the actor
    uint256 public ghostExtra; // sum of every "extra" the king contract split
    uint256 public ghostBurnIn; // ETH that entered the burn bucket (deposits, king share, 2% of rolls)
    uint256 public lastDead; // PvP at dEaD after the previous call
    uint256 public lastBid;
    uint256 public kingLocked; // what the sitting king fronted to refund their predecessor
    bool public deadDecreased;
    bool public bidRuleBroken;
    uint256 public crowns;
    uint256 public crownAttempts;
    uint256 public crownAllowed;
    uint256 public refundsChecked;

    constructor(PvPPad p, PadLiquidity l, KingOfThePad k, PadToken t, MockArbSys a, Swapper s) {
        pad = p;
        liq = l;
        king = k;
        pvp = t;
        arb = a;
        swapper = s;
        for (uint256 i; i < 5; i++) {
            actors.push(i == 2 ? address(new Rejecter()) : address(uint160(0xC000 + i)));
        }
        lastDead = pvp.balanceOf(DEAD);
        ghostBurnIn = liq.burnBucket() + liq.totalBurnedEth();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function gameCount() external view returns (uint256) {
        return games.length;
    }

    function _actor(uint256 a) internal view returns (address) {
        return actors[a % actors.length];
    }

    function _fund(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        funded[who] += amount;
    }

    function _after() internal {
        uint256 dead = pvp.balanceOf(DEAD);
        if (dead < lastDead) deadDecreased = true;
        lastDead = dead;
    }

    // ---------------------------------------------------------------- crown
    function takeCrown(uint256 a, uint256 amt, uint8 mode) external {
        address who = _actor(a);
        // mode: 0 bid below the minimum; 1 bid without waiting; 2/3 wait exactly until the hold expires
        if (mode % 4 >= 2 && !king.canTake()) vm.warp(king.crownedAt() + king.HOLD_SECONDS());
        uint256 min = king.minBid();
        amt = mode % 4 == 0 ? bound(amt, 0, min - 1) : bound(amt, min, min * 2 + 0.01 ether);
        _fund(who, amt);
        address old = king.king();
        uint256 oldBid = king.bid();
        uint256 oldWealth = old == address(0) ? 0 : old.balance + pad.claimable(old);
        bool expectOk = amt >= min && king.canTake();
        crownAttempts++;
        if (expectOk) crownAllowed++;
        vm.prank(who);
        try king.takeCrown{value: amt}() {
            assertTrue(expectOk, "takeCrown succeeded against the rules");
            assertEq(king.king(), who);
            assertEq(king.bid(), amt);
            assertEq(king.crownedAt(), uint64(block.timestamp));
            uint256 extra = amt - oldBid;
            extraPaid[who] += extra;
            kingLocked = oldBid; // the refund the new king fronted; it comes back when they are dethroned
            ghostExtra += extra;
            ghostBurnIn += extra / 4;
            if (oldBid != 0 && old != who) {
                // the old king is refunded in full at once (or the refund is held for them)
                assertGe(old.balance + pad.claimable(old) - oldWealth, oldBid, "old king not refunded in full");
                refundsChecked++;
            }
            if (lastBid != 0 && amt < lastBid * 110 / 100) bidRuleBroken = true;
            lastBid = amt;
            crowns++;
        } catch {
            assertFalse(expectOk, "takeCrown reverted although the rules allow it");
        }
        _after();
    }

    function distribute(uint256 n) external {
        try king.distribute(bound(n, 0, 5)) {} catch {}
        _after();
    }

    // ---------------------------------------------------------------- burn bucket
    function burnChunk() external {
        bool due = liq.burnDue();
        uint256 bucket = liq.burnBucket();
        uint256 burned = liq.totalBurnedEth();
        uint256 dead = pvp.balanceOf(DEAD);
        try liq.burnChunk() {
            assertTrue(due, "burnChunk ran although not due");
            uint256 chunk = bucket > 0.02 ether ? 0.02 ether : bucket;
            assertEq(liq.burnBucket(), bucket - chunk, "burn chunk size");
            assertEq(liq.totalBurnedEth(), burned + chunk);
            // a dust chunk (a few wei) rounds to zero tokens in the pool; anything meaningful must burn
            if (chunk >= 1e9) assertGt(pvp.balanceOf(DEAD), dead, "burn bought nothing");
            else assertGe(pvp.balanceOf(DEAD), dead);
            assertEq(liq.lastBurnAt(), uint64(block.timestamp));
        } catch {
            assertFalse(due, "burnChunk reverted although due");
        }
        _after();
    }

    function depositBurn(uint256 a, uint256 amt) external {
        address who = _actor(a);
        amt = bound(amt, 0, 0.05 ether);
        _fund(who, amt);
        vm.prank(who);
        liq.depositBurn{value: amt}();
        spent[who] += amt;
        ghostBurnIn += amt;
        _after();
    }

    function addCarry(uint256 a, uint256 amt) external {
        address who = _actor(a);
        amt = bound(amt, 0, 0.05 ether);
        _fund(who, amt);
        vm.prank(who);
        pad.addCarry{value: amt}();
        spent[who] += amt;
        _after();
    }

    // ---------------------------------------------------------------- pool activity (fees for the king)
    function swap(uint256 eth) external {
        eth = bound(eth, 0.001 ether, 0.2 ether);
        vm.deal(address(swapper), address(swapper).balance + eth);
        try swapper.buy(liq.poolKey(address(pvp)), eth) {} catch {}
        _after();
    }

    // ---------------------------------------------------------------- launches and games
    function launch(uint256 a) external {
        if (games.length >= MAX_LAUNCHES) return;
        address who = _actor(a);
        vm.prank(who);
        (, address g) = pad.launch("Fuzz", "FZ", "");
        games.push(PadGame(g));
        _after();
    }

    function mint(uint256 a, uint256 gi) external {
        if (games.length == 0) return;
        address who = _actor(a);
        vm.prank(who);
        try games[gi % games.length].mint() {} catch {}
        _after();
    }

    function roll(uint256 a, uint256 gi) external {
        if (games.length == 0) return;
        address who = _actor(a);
        PadGame g = games[gi % games.length];
        _fund(who, 0.002 ether);
        vm.prank(who);
        try g.roll{value: 0.002 ether}() {
            spent[who] += 0.002 ether;
            ghostBurnIn += 0.002 ether * 2 / 100;
        } catch {}
        _after();
    }

    function poke(uint256 gi) external {
        if (games.length == 0) return;
        try games[gi % games.length].poke() {} catch {}
        _after();
    }

    function upkeep(uint256 a) external {
        pad.upkeep(_actor(a));
        _after();
    }

    function claim(uint256 a) external {
        address who = _actor(a);
        vm.prank(who);
        try pad.claim() {} catch {}
        _after();
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 5400)); // long enough that the 1h crown hold expires regularly
        arb.advance(bound(s, 1, 40));
    }
}

contract InvariantSystemTest is Harness {
    SystemHandler handler;
    uint256 devStart;

    function setUp() public override {
        super.setUp();
        _graduateGenesis();
        Swapper s = new Swapper(manager);
        handler = new SystemHandler(pad, liq, king, pvp, arb, s);
        devStart = OWNER.balance;
        targetContract(address(handler));
    }

    /// The king contract is a pass-through: it never holds ETH between calls.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 50
    function invariant_kingHoldsNothing() public view {
        assertEq(address(king).balance, 0);
    }

    /// Every extra split by the crown is accounted for and the dev share actually arrived.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 50
    function invariant_kingSplitAccounting() public view {
        assertEq(king.totalToPots() + king.totalToBurn() + king.totalToDev(), handler.ghostExtra());
        // per-bid floor(extra/2) sums to at most floor(sum/2), short by at most one wei per crowning
        assertLe(king.totalToPots(), handler.ghostExtra() / 2);
        assertGe(king.totalToPots() + handler.crowns(), handler.ghostExtra() / 2);
        assertEq(OWNER.balance - devStart, king.totalToDev());
        assertFalse(handler.bidRuleBroken());
        if (king.king() != address(0)) assertGe(king.bid(), king.MIN_FIRST_BID());
    }

    /// PadLiquidity holds exactly the burn bucket; everything that entered the bucket is either waiting or burned.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 50
    function invariant_liquidityHoldsOnlyTheBurnBucket() public view {
        assertEq(address(liq).balance, liq.burnBucket());
        assertEq(liq.burnBucket() + liq.totalBurnedEth(), handler.ghostBurnIn());
        assertEq(pvp.balanceOf(address(liq)), 0);
    }

    /// The pad always holds at least the carry pot plus every failed send it escrows.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 50
    function invariant_padHoldsWhatItOwes() public view {
        assertGe(address(pad).balance, pad.carryPot() + pad.totalClaimable());
    }

    /// No bidder loses more than the extra they paid and what they spent on purpose; the current king's bid is
    /// still owed to them. Fees and prizes can only add to this. Holds for the receiver that rejects ETH too.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 50
    function invariant_biddersOnlyLoseTheExtra() public view {
        for (uint256 i; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 owed = handler.funded(a) - handler.extraPaid(a) - handler.spent(a);
            if (king.king() == a) owed -= handler.kingLocked();
            assertGe(a.balance + pad.claimable(a), owed);
        }
    }

    /// PvP supply is fixed, burned PvP never comes back, and every launched game holds its pot plus curve ETH.
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 50
    function invariant_supplyBurnAndGameBalances() public view {
        assertEq(pvp.totalSupply(), 1e9 ether);
        assertFalse(handler.deadDecreased());
        for (uint256 i; i < handler.gameCount(); i++) {
            PadGame g = handler.games(i);
            PadToken t = PadToken(address(g.token()));
            assertEq(t.totalSupply(), 1e9 ether);
            assertLe(g.tokensSold(), 800_000_000 ether);
            if (g.phase() <= g.PHASE_RUNNING()) {
                assertEq(address(g).balance, g.pot() + g.curveEth());
                assertFalse(t.unlocked());
            } else if (g.phase() >= g.PHASE_GRADUATED()) {
                assertEq(address(g).balance, 0);
                assertEq(g.curveEth(), 0);
                assertEq(t.unlocked(), g.phase() == g.PHASE_GRADUATED());
            }
        }
    }
}
