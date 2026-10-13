// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Rejecter} from "./Harness.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract DeployTest is Harness {
    /// @dev Deploys the five contracts from their raw creation code with CREATE (not `new`, which this Foundry
    ///      version rewrites into an unmetered cheatcode) and measures the real EVM gas of the whole sequence,
    ///      genesis launch included. The launch runs it as one transaction.
    function test_deployGasUnderTarget() public {
        address pm = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // not called by any constructor
        uint256 g0 = gasleft();
        address t = _create(type(PadToken).creationCode);
        address g = _create(type(PadGame).creationCode);
        address p = _create(abi.encodePacked(type(PvPPad).creationCode, abi.encode(OWNER, t, g)));
        address l = _create(abi.encodePacked(type(PadLiquidity).creationCode, abi.encode(p, pm)));
        address k = _create(abi.encodePacked(type(KingOfThePad).creationCode, abi.encode(p, l)));
        uint256 used = g0 - gasleft() + 21_000;
        emit log_named_uint("deploy gas (five contracts + genesis + 21k base)", used);
        assertLt(used, 13_000_000, "deploy gas over target");
        assertLt(used, 16_777_216, "deploy gas over the hard limit");
        assertEq(PvPPad(p).king(), k);
        assertTrue(PvPPad(p).genesisGame() != address(0));
    }

    function _create(bytes memory code) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 32), mload(code))
        }
        require(a != address(0), "create failed");
    }

    function test_runtimeSizesAndOpcodes() public view {
        address[5] memory cs =
            [address(tokenTemplate), address(gameTemplate), address(pad), address(liq), address(king)];
        for (uint256 i; i < cs.length; i++) {
            bytes memory code = cs[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576, "runtime too large");
            for (uint256 j; j < code.length; j++) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function test_bindingsAndGenesis() public view {
        assertEq(pad.owner(), OWNER);
        assertEq(pad.DEV(), OWNER);
        assertEq(pad.liquidity(), address(liq));
        assertEq(pad.king(), address(king));
        assertEq(liq.kingContract(), address(king));
        assertEq(pad.launchCount(), 1);
        PvPPad.Launch memory l = pad.getLaunch(0);
        assertEq(l.name, "Pepes Value Pepes");
        assertEq(l.ticker, "PvP");
        assertEq(l.game, address(genesis));
        assertEq(l.token, address(pvp));
        assertEq(pvp.name(), "Pepes Value Pepes");
        assertEq(pvp.balanceOf(address(genesis)), 1e9 ether);
        assertTrue(genesis.isGenesis());
        assertEq(genesis.phase(), genesis.PHASE_WAITING());
        assertTrue(pad.isGame(address(genesis)));
        assertEq(pad.activeCount(), 1);
    }

    function test_bindingsAreOneShot() public {
        vm.expectRevert(PvPPad.AlreadyBound.selector);
        pad.setLiquidity();
        vm.expectRevert(PvPPad.AlreadyBound.selector);
        pad.setKing();
        vm.expectRevert(PadLiquidity.AlreadyBound.selector);
        liq.setKing();
        vm.expectRevert(PvPPad.NotAllowed.selector);
        pad.startGenesis();
        vm.prank(address(king));
        vm.expectRevert(PvPPad.NotAllowed.selector);
        pad.startGenesis();
    }

    function test_templatesCannotBeInitialized() public {
        vm.expectRevert(PadToken.AlreadyInitialized.selector);
        tokenTemplate.initialize("a", "b", "", address(1), address(2));
        vm.expectRevert(PadGame.AlreadyInitialized.selector);
        gameTemplate.initialize(address(1), address(2), address(3), false);
        vm.expectRevert(PadToken.AlreadyInitialized.selector);
        pvp.initialize("a", "b", "", address(1), address(2));
        vm.expectRevert(PadGame.AlreadyInitialized.selector);
        genesis.initialize(address(1), address(2), address(3), false);
    }

    function test_openSwitch() public {
        assertFalse(pad.isOpen());
        vm.expectRevert(PadGame.NotOpen.selector);
        genesis.mint();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(PadGame.NotOpen.selector);
        genesis.roll{value: 0.002 ether}();
        vm.expectRevert(PvPPad.NotOpen.selector);
        pad.launch("x", "y", "");
        vm.expectRevert(KingOfThePad.NotOpen.selector);
        king.takeCrown{value: 0.01 ether}();

        // not the owner, before 30 days
        vm.prank(address(0xBAD));
        vm.expectRevert(PvPPad.NotAllowed.selector);
        pad.openPad();
        // anyone after 30 days
        vm.warp(pad.deployedAt() + 30 days);
        vm.prank(address(0xBAD));
        pad.openPad();
        assertTrue(pad.isOpen());
        vm.prank(OWNER);
        vm.expectRevert(PvPPad.AlreadyOpened.selector);
        pad.openPad();
        genesis.mint();
        assertEq(genesis.impCount(), 1);
    }

    function test_ownerOpensEarly() public {
        vm.prank(OWNER);
        pad.openPad();
        assertTrue(pad.opened());
        assertEq(pad.openedAt(), uint64(block.timestamp));
    }

    function test_escrowClaim() public {
        vm.expectRevert(PvPPad.NotGame.selector);
        pad.holdFor{value: 0}(address(1));
        vm.prank(address(genesis));
        vm.deal(address(genesis), 1 ether);
        pad.holdFor{value: 1 ether}(address(this));
        assertEq(pad.claimable(address(this)), 1 ether);
        assertEq(pad.totalClaimable(), 1 ether);
        uint256 b = address(this).balance;
        pad.claim();
        assertEq(address(this).balance - b, 1 ether);
        vm.expectRevert(PvPPad.Nothing.selector);
        pad.claim();
    }

    function test_launchToken() public {
        LaunchToken t = new LaunchToken();
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.balanceOf(address(this)), 1_000_000_000 ether);
        assertEq(t.decimals(), 18);
        assertEq(t.name(), "Pepe Values Pepe");
        assertEq(t.symbol(), "PVP");
        assertTrue(t.transfer(address(1), 5 ether));
        assertEq(t.balanceOf(address(1)), 5 ether);
        t.approve(address(2), 3 ether);
        vm.prank(address(2));
        t.transferFrom(address(this), address(3), 3 ether);
        assertEq(t.balanceOf(address(3)), 3 ether);
        uint256 tooMuch = t.balanceOf(address(this)) + 1;
        vm.expectRevert();
        t.transfer(address(1), tooMuch);
    }

    receive() external payable {}
}
