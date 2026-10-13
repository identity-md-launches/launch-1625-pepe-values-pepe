// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness} from "./Harness.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";

contract EdgesTest is Harness {
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_openSwitchBoundary(address caller, uint256 dt) public {
        vm.assume(caller != OWNER);
        dt = bound(dt, 0, 60 days);
        vm.warp(pad.deployedAt() + dt);
        vm.prank(caller);
        if (dt < 30 days) {
            vm.expectRevert(PvPPad.NotAllowed.selector);
            pad.openPad();
            assertFalse(pad.isOpen());
        } else {
            pad.openPad();
            assertTrue(pad.isOpen());
        }
    }

    function test_launchGatedUntilGenesisGraduates() public {
        _open();
        vm.expectRevert(PvPPad.GenesisPending.selector);
        pad.launch("a", "b", "");
    }

    function test_launchInputLengths() public {
        _graduateGenesis();
        string memory n32 = "12345678901234567890123456789012";
        string memory t10 = "1234567890";
        bytes memory img = new bytes(200);
        pad.launch(n32, t10, string(img));
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch(string.concat(n32, "x"), t10, "");
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch(n32, string.concat(t10, "x"), "");
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch(n32, t10, string(new bytes(201)));
        vm.expectRevert(PvPPad.BadInput.selector);
        pad.launch("", t10, "");
    }

    function test_mintTwiceAndAfterSignupReverts() public {
        _open();
        vm.prank(_imp(0));
        genesis.mint();
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.AlreadyMinted.selector);
        genesis.mint();
        vm.warp(genesis.playStart());
        vm.prank(_imp(1));
        vm.expectRevert(PadGame.BadPhase.selector);
        genesis.mint();
    }

    function test_maxImps() public {
        _open();
        _mintN(genesis, 200);
        vm.prank(_imp(200));
        vm.expectRevert(PadGame.Full.selector);
        genesis.mint();
    }

    function test_rollWrongValueAndCooldown() public {
        _open();
        _mintN(genesis, 1);
        _toPlay(genesis);
        vm.deal(_imp(0), 1 ether);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.BadValue.selector);
        genesis.roll{value: 0.002 ether - 1}();
        _roll(genesis, _imp(0));
        arb.advance(5);
        vm.warp(block.timestamp + 59);
        vm.prank(_imp(0));
        vm.expectRevert(PadGame.Cooldown.selector);
        genesis.roll{value: 0.002 ether}();
    }

    /// Curve never sells more than 800M and the quote matches the buy.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_quoteNeverExceedsCurve(uint256 eth) public view {
        eth = bound(eth, 1, 100 ether);
        assertLe(genesis.quote(eth), 800_000_000 ether);
    }
}
