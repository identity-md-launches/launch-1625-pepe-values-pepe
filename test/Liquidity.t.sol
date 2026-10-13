// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Harness, Swapper, Rejecter} from "./Harness.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
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
