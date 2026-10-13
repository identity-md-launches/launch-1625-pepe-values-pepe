// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Harness, MockArbSys, Rejecter} from "./Harness.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PvPPad} from "../src/PvPPad.sol";

/// @dev Drives the genesis game with several actors (some reject ETH) in random order.
contract GameHandler is Test {
    PadGame public game;
    PvPPad public pad;
    PadToken public token;
    MockArbSys public arb;
    address[] public actors;

    uint256 public ghostRollsIn; // ETH paid into the game by rolls
    uint256 public ghostOut; // ETH that left the game (fee, ringer, winners, carry, graduation)
    uint8 public maxPhaseSeen;
    bool public phaseWentBack;
    uint256 public rolls;

    constructor(PadGame g, PvPPad p, PadToken t, MockArbSys a) {
        game = g;
        pad = p;
        token = t;
        arb = a;
        for (uint256 i; i < 6; i++) {
            actors.push(i % 3 == 2 ? address(new Rejecter()) : address(uint160(0xB000 + i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _track() internal {
        uint8 ph = game.phase();
        if (ph < maxPhaseSeen) phaseWentBack = true;
        if (ph > maxPhaseSeen) maxPhaseSeen = ph;
    }

    function mint(uint256 a) external {
        address who = actors[a % actors.length];
        vm.prank(who);
        try game.mint() {} catch {}
        _track();
    }

    function roll(uint256 a) external {
        address who = actors[a % actors.length];
        vm.deal(who, who.balance + 0.002 ether);
        vm.prank(who);
        try game.roll{value: 0.002 ether}() {
            ghostRollsIn += 0.002 ether;
            rolls++;
        } catch {}
        _track();
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 700));
        arb.advance(bound(s, 1, 40));
    }

    function poke() external {
        try game.poke() {} catch {}
        _track();
    }

    function claim(uint256 a) external {
        address who = actors[a % actors.length];
        vm.prank(who);
        try pad.claim() {} catch {}
    }
}

contract InvariantTest is Harness {
    GameHandler handler;
    uint256 constant SUPPLY = 1e9 ether;

    function setUp() public override {
        super.setUp();
        _open();
        handler = new GameHandler(genesis, pad, pvp, arb);
        targetContract(address(handler));
    }

    /// While the game runs it holds exactly its pot plus the curve ETH (genesis: burn share goes to the pot).
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_gameBalanceMatchesAccounting() public view {
        if (genesis.phase() <= genesis.PHASE_RUNNING()) {
            assertEq(address(genesis).balance, genesis.pot() + genesis.curveEth());
            assertEq(address(genesis).balance, handler.ghostRollsIn());
        }
        if (genesis.phase() >= genesis.PHASE_GRADUATED()) {
            assertEq(address(genesis).balance, 0);
            assertEq(genesis.curveEth(), 0);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_tokenSupplyFixedAndCurveCapped() public view {
        assertEq(pvp.totalSupply(), SUPPLY);
        assertLe(genesis.tokensSold(), 800_000_000 ether);
        if (genesis.phase() <= genesis.PHASE_RUNNING()) {
            uint256 held;
            for (uint256 i; i < handler.actorCount(); i++) {
                held += pvp.balanceOf(handler.actors(i));
            }
            assertEq(held, genesis.tokensSold());
            assertEq(pvp.balanceOf(address(genesis)) + held, SUPPLY);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_padHoldsWhatItOwes() public view {
        assertGe(address(pad).balance, pad.carryPot() + pad.totalClaimable());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_phaseNeverGoesBack() public view {
        assertFalse(handler.phaseWentBack());
        assertLe(genesis.impCount(), 200);
    }
}
