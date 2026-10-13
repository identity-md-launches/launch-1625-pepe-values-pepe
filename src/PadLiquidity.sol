// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IPvPPad, IPadToken} from "./interfaces/Interfaces.sol";

/// @title PadLiquidity
/// @notice Graduates launches into Uniswap v4 pools (native ETH / token, fee 1%, tickSpacing 200, no hooks),
///         owns every LP position forever, collects their fees for the king, and burns PvP with the burn bucket.
/// @dev Only talks to v4 through PoolManager.unlock with its own funds.
contract PadLiquidity {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 public constant POOL_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;
    uint256 public constant BURN_MAX = 0.02 ether;
    uint64 public constant BURN_INTERVAL = 10 minutes;
    uint256 public constant SELL_CHUNK = 1_000_000 ether; // tokens sold per collection, per pool
    uint256 internal constant PUSH_GAS = 30_000;

    uint8 internal constant ACT_GRADUATE = 1;
    uint8 internal constant ACT_COLLECT = 2;
    uint8 internal constant ACT_BURN = 3;

    IPvPPad public immutable pad;
    IPoolManager public immutable manager;
    address public kingContract;

    address[] public pools; // graduated tokens, in graduation order
    mapping(address => bool) public graduated;
    mapping(address => bool) public failed;
    uint256 public distributeCursor;

    uint256 public burnBucket;
    uint64 public lastBurnAt;
    uint256 public totalBurnedEth;
    bool internal locked;

    event KingBound(address king);
    event GraduatedToPool(
        address indexed token, uint160 targetSqrtPrice, uint160 poolSqrtPrice, uint128 liquidity, bool preInitialized
    );
    event LiquidityAdded(address indexed token, uint256 ethIn, uint256 tokensIn, uint256 tokensBurned);
    event GraduationFailed(address indexed token, uint256 tokensBurned);
    event BurnDeposited(address indexed from, uint256 amount);
    event Burned(uint256 ethIn, uint256 tokensBurned);
    event FeesCollected(
        address indexed token, uint256 ethFees, uint256 tokenFees, uint256 tokensSold, uint256 ethToKing
    );
    event SentToKing(address indexed king, uint256 amount);

    error NotGame();
    error NotManager();
    error AlreadyBound();
    error NoKing();
    error NotDue();
    error Reentrant();
    error BadToken();

    modifier nonReentrant() {
        if (locked) revert Reentrant();
        locked = true;
        _;
        locked = false;
    }

    constructor(address pad_, address manager_) {
        pad = IPvPPad(pad_);
        manager = IPoolManager(manager_);
        IPvPPad(pad_).setLiquidity();
    }

    receive() external payable {}

    function setKing() external {
        if (kingContract != address(0)) revert AlreadyBound();
        kingContract = msg.sender;
        emit KingBound(msg.sender);
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function poolKey(address token) public pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), POOL_FEE, TICK_SPACING, IHooks(address(0)));
    }

    function poolSqrtPrice(address token) external view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolKey(token).toId());
    }

    function burnDue() public view returns (bool) {
        return pad.pvpDone() && !pad.pvpFailed() && burnBucket != 0 && block.timestamp >= lastBurnAt + BURN_INTERVAL;
    }

    // ---------------------------------------------------------------- graduation
    /// @notice Called by a launch's game with the curve ETH; the tokens must already be held here.
    function graduate(address token, uint160 sqrtPriceX96) external payable nonReentrant {
        if (!pad.isGame(msg.sender) || IPadToken(token).game() != msg.sender || graduated[token]) revert NotGame();
        graduated[token] = true;
        uint256 tokens = IPadToken(token).balanceOf(address(this));
        if (msg.value == 0) {
            failed[token] = true;
            if (tokens != 0) IPadToken(token).transfer(DEAD, tokens);
            emit GraduationFailed(token, tokens);
            return;
        }
        pools.push(token);
        manager.unlock(abi.encode(ACT_GRADUATE, token, sqrtPriceX96, msg.value, tokens));
        IPadToken(token).unlock();
    }

    // ---------------------------------------------------------------- burn bucket
    function depositBurn() external payable {
        if (pad.pvpDone() && pad.pvpFailed()) {
            // genesis failed: no PvP pool can ever exist, so the burn share feeds the carry pot instead
            pad.addCarry{value: msg.value}();
            return;
        }
        burnBucket += msg.value;
        emit BurnDeposited(msg.sender, msg.value);
    }

    /// @notice Buys PvP with up to 0.02 ETH of the burn bucket and sends it to dEaD. One buy per 10 minutes.
    function burnChunk() external nonReentrant {
        if (!burnDue()) revert NotDue();
        uint256 amount = burnBucket > BURN_MAX ? BURN_MAX : burnBucket;
        burnBucket -= amount;
        lastBurnAt = uint64(block.timestamp);
        totalBurnedEth += amount;
        manager.unlock(abi.encode(ACT_BURN, pad.genesisToken(), uint160(0), amount, uint256(0)));
    }

    // ---------------------------------------------------------------- fee distribution
    /// @notice Collects LP fees from the next n pools round-robin, sells the token side (chunk-capped) and
    ///         sends all ETH to the current king.
    function distribute(uint256 n) external nonReentrant {
        address k = kingContract == address(0) ? address(0) : IKingView(kingContract).king();
        if (k == address(0)) revert NoKing();
        uint256 len = pools.length;
        if (len == 0) return;
        if (n > len) n = len;
        uint256 before = address(this).balance;
        for (uint256 i; i < n; i++) {
            address token = pools[distributeCursor % len];
            distributeCursor++;
            manager.unlock(abi.encode(ACT_COLLECT, token, uint160(0), uint256(0), uint256(0)));
        }
        uint256 got = address(this).balance - before;
        if (got != 0) {
            emit SentToKing(k, got);
            (bool ok,) = k.call{value: got, gas: PUSH_GAS}("");
            if (!ok) pad.holdFor{value: got}(k);
        }
    }

    // ---------------------------------------------------------------- v4 callback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (uint8 act, address token, uint160 target, uint256 eth, uint256 tokens) =
            abi.decode(data, (uint8, address, uint160, uint256, uint256));
        PoolKey memory key = poolKey(token);
        if (act == ACT_GRADUATE) _graduate(key, token, target, eth, tokens);
        else if (act == ACT_COLLECT) _collect(key, token);
        else _burn(key, eth);
        return "";
    }

    function _graduate(PoolKey memory key, address token, uint160 target, uint256 eth, uint256 tokens) internal {
        bool pre;
        // solhint-disable-next-line no-empty-blocks
        try manager.initialize(key, target) {}
        catch {
            pre = true;
            (uint160 cur,,,) = manager.getSlot0(key.toId());
            if (cur != target) {
                // move the price to the target with a price limit, spending only our own funds
                bool zeroForOne = cur > target;
                BalanceDelta d =
                    manager.swap(key, SwapParams(zeroForOne, zeroForOne ? -int256(eth) : -int256(tokens), target), "");
                eth = uint256(int256(eth) + d.amount0());
                tokens = uint256(int256(tokens) + d.amount1());
            }
        }
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint128 liq = _fullRangeLiquidity(sqrtP, eth, tokens);
        (BalanceDelta d2,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(uint256(liq)), bytes32(0)), ""
        );
        _settleOpen(key);
        emit GraduatedToPool(token, target, sqrtP, liq, pre);
        _finishGraduation(token, d2);
    }

    function _finishGraduation(address token, BalanceDelta d2) internal {
        // leftovers: tokens to dEaD, ETH rounding dust to the carry pot (never into the pool price)
        uint256 left = IPadToken(token).balanceOf(address(this));
        if (left != 0) IPadToken(token).transfer(DEAD, left);
        uint256 dust = address(this).balance - burnBucket;
        if (dust != 0) pad.addCarry{value: dust}();
        emit LiquidityAdded(token, uint256(-int256(d2.amount0())), uint256(-int256(d2.amount1())), left);
    }

    function _collect(PoolKey memory key, address token) internal {
        (BalanceDelta fees,) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, 0, bytes32(0)), "");
        uint256 fee0 = uint256(int256(fees.amount0()));
        uint256 fee1 = uint256(int256(fees.amount1()));
        uint256 held = IPadToken(token).balanceOf(address(this));
        uint256 sell = fee1 + held;
        if (sell > SELL_CHUNK) sell = SELL_CHUNK;
        uint256 out;
        if (sell != 0) {
            BalanceDelta d = manager.swap(key, SwapParams(false, -int256(sell), TickMath.MAX_SQRT_PRICE - 1), "");
            out = uint256(int256(d.amount0()));
        }
        _settleOpen(key);
        emit FeesCollected(token, fee0, fee1, sell, fee0 + out);
    }

    function _burn(PoolKey memory key, uint256 eth) internal {
        BalanceDelta d = manager.swap(key, SwapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1), "");
        uint256 out = uint256(int256(d.amount1()));
        manager.settle{value: eth}();
        if (out != 0) manager.take(key.currency1, DEAD, out);
        emit Burned(eth, out);
    }

    /// @dev Settles whatever delta is still open on both currencies of the key.
    function _settleOpen(PoolKey memory key) internal {
        int256 d0 = manager.currencyDelta(address(this), key.currency0);
        if (d0 > 0) manager.take(key.currency0, address(this), uint256(d0));
        else if (d0 < 0) manager.settle{value: uint256(-d0)}();
        int256 d1 = manager.currencyDelta(address(this), key.currency1);
        if (d1 > 0) {
            manager.take(key.currency1, address(this), uint256(d1));
        } else if (d1 < 0) {
            manager.sync(key.currency1);
            IPadToken(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(-d1));
            manager.settle();
        }
    }

    /// @dev Largest full-range liquidity fundable with the given amounts, with a tiny safety margin for rounding.
    function _fullRangeLiquidity(uint160 sqrtP, uint256 amount0, uint256 amount1) internal pure returns (uint128) {
        uint160 lo = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 hi = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint256 inter = FullMath.mulDiv(sqrtP, hi, FixedPoint96.Q96);
        uint256 l0 = FullMath.mulDiv(amount0, inter, hi - sqrtP);
        uint256 l1 = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtP - lo);
        uint256 l = l0 < l1 ? l0 : l1;
        l = l - l / 1_000_000 - 1;
        return uint128(l);
    }
}

interface IKingView {
    function king() external view returns (address);
}
