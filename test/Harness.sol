// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";

/// @dev Local stand-in for the ArbSys precompile. Production randomness comes from the real precompile.
contract MockArbSys {
    uint256 public n;
    mapping(uint256 => bytes32) public forced;

    function setBlock(uint256 b) external {
        n = b;
    }

    function advance(uint256 k) external {
        n += k;
    }

    function force(uint256 b, bytes32 h) external {
        forced[b] = h;
    }

    function arbBlockNumber() external view returns (uint256) {
        return n;
    }

    function arbBlockHash(uint256 b) external view returns (bytes32) {
        require(b < n && b + 256 >= n, "Invalid block number");
        bytes32 h = forced[b];
        return h == bytes32(0) ? keccak256(abi.encode("arb", b)) : h;
    }
}

/// @dev A receiver that rejects ETH.
contract Rejecter {
    receive() external payable {
        revert("no");
    }
}

/// @dev Swaps ETH into a pool through PoolManager.unlock (generates LP fees in tests).
contract Swapper {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {}

    function buy(PoolKey memory key, uint256 eth) external payable {
        manager.unlock(abi.encode(key, eth, true));
    }

    function initializeAt(PoolKey memory key, uint160 sqrtP) external {
        manager.initialize(key, sqrtP);
    }

    /// @dev Sells `tokens` of the pool's token for ETH (dumps the price).
    function sell(PoolKey memory key, uint256 tokens) external {
        manager.unlock(abi.encode(key, tokens, false));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amount, bool buy_) = abi.decode(data, (PoolKey, uint256, bool));
        if (buy_) {
            BalanceDelta d = manager.swap(key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), "");
            manager.settle{value: uint256(-int256(d.amount0()))}();
            manager.take(key.currency1, address(this), uint256(int256(d.amount1())));
        } else {
            BalanceDelta d = manager.swap(key, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), "");
            manager.sync(key.currency1);
            PadToken(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(-int256(d.amount1())));
            manager.settle();
            manager.take(key.currency0, address(this), uint256(int256(d.amount0())));
        }
        return "";
    }
}

/// @dev Anyone can do this before graduation: initialize the launch's pool below the graduation price and park
///      ETH-only liquidity between that price and the target (no token is needed: tokens are locked).
contract Griefer {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {}

    function park(PoolKey memory key, int24 lower, int24 upper, int256 liq) external {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(lower));
        manager.unlock(abi.encode(key, lower, upper, liq));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lower, int24 upper, int256 liq) = abi.decode(data, (PoolKey, int24, int24, int256));
        manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liq, bytes32(0)), "");
        int256 d0 = manager.currencyDelta(address(this), key.currency0);
        require(manager.currencyDelta(address(this), key.currency1) == 0, "token side needed");
        manager.settle{value: uint256(-d0)}();
        return "";
    }
}

abstract contract Harness is Test {
    address constant ARB = address(0x64);
    address constant OWNER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockArbSys arb;
    PoolManager manager;
    PadToken tokenTemplate;
    PadGame gameTemplate;
    PvPPad pad;
    PadLiquidity liq;
    KingOfThePad king;
    PadGame genesis;
    PadToken pvp;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        MockArbSys impl = new MockArbSys();
        vm.etch(ARB, address(impl).code);
        arb = MockArbSys(ARB);
        arb.setBlock(10_000);
        manager = new PoolManager(address(this));

        tokenTemplate = new PadToken();
        gameTemplate = new PadGame();
        pad = new PvPPad(OWNER, address(tokenTemplate), address(gameTemplate));
        liq = new PadLiquidity(address(pad), address(manager));
        king = new KingOfThePad(address(pad), address(liq));

        genesis = PadGame(pad.genesisGame());
        pvp = PadToken(pad.genesisToken());
    }

    function _open() internal {
        vm.prank(OWNER);
        pad.openPad();
    }

    function _imp(uint256 i) internal pure returns (address) {
        return address(uint160(0xA000 + i));
    }

    function _mintN(PadGame g, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.prank(_imp(i));
            g.mint();
        }
    }

    function _toPlay(PadGame g) internal {
        vm.warp(g.playStart());
    }

    function _roll(PadGame g, address who) internal {
        vm.deal(who, who.balance + 0.002 ether);
        vm.prank(who);
        g.roll{value: 0.002 ether}();
    }

    /// @dev Forces the next resolution of (imp, nonce) committed at `commit` to produce `want` (-4..-1, 1..4).
    function _force(PadGame g, address imp, uint32 nonce, uint64 commit, int8 want) internal {
        bytes32 h1 = keccak256(abi.encode("arb", uint256(commit) + 1));
        bytes32 h2 = keccak256(abi.encode("arb", uint256(commit) + 2));
        for (uint256 s;; s++) {
            bytes32 h3 = keccak256(abi.encode("force", s));
            uint256 r = uint256(keccak256(abi.encode(address(g), imp, nonce, h1, h2, h3))) % 8;
            int8 d = r < 4 ? -int8(int256(4 - r)) : int8(int256(r - 3));
            if (d == want) {
                arb.force(uint256(commit) + 3, h3);
                return;
            }
        }
    }

    /// @dev Rolls for `who` and forces the outcome `want`; advances enough blocks to make it resolvable.
    function _rollForce(PadGame g, address who, int8 want) internal {
        _roll(g, who);
        PadGame.Imp memory im = g.getImp(who);
        _force(g, who, im.rolls, uint64(arb.n()), want);
        arb.advance(4);
    }

    function _settle(PadGame g) internal {
        for (uint256 i; i < 40 && g.phase() < 3; i++) {
            g.poke();
        }
    }

    /// @dev Plays the genesis game with two imps and graduates it.
    function _graduateGenesis() internal {
        _open();
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
        assertEq(genesis.phase(), genesis.PHASE_GRADUATED());
        assertTrue(pad.pvpDone());
    }
}
