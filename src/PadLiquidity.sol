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
    uint256 public constant DEPTH_DIVISOR = 200; // a sale is also capped at 0.5% of the pool's token depth
    /// @notice Most initialized ticks the graduation swap will cross. More than this in the way (a third party
    ///         parked positions between the pre-initialized price and the target) and the swap is skipped.
    uint256 public constant MAX_PATH_TICKS = 32;
    uint256 internal constant PUSH_GAS = 30_000;

    struct Range {
        int24 lower;
        int24 upper;
    }

    uint8 internal constant ACT_GRADUATE = 1;
    uint8 internal constant ACT_COLLECT = 2;
    uint8 internal constant ACT_BURN = 3;

    IPvPPad public immutable pad;
    IPoolManager public immutable manager;
    address public kingContract;

    address[] public pools; // graduated tokens, in graduation order
    mapping(address => bool) public graduated;
    mapping(address => bool) public failed;
    mapping(address => Range[]) internal positions; // the pad's LP positions per graduated token (1 or 2)
    uint256 public distributeCursor;

    uint256 public burnBucket;
    uint64 public lastBurnAt;
    uint256 public totalBurnedEth;
    bool internal locked;

    event KingBound(address king);
    event GraduatedToPool(
        address indexed token, uint160 targetSqrtPrice, uint160 poolSqrtPrice, bool preInitialized, bool split
    );
    event PositionAdded(address indexed token, int24 tickLower, int24 tickUpper, uint128 liquidity);
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

    /// @notice The pad's LP positions for a graduated token: one full-range position, or (when a third party
    ///         pre-initialized the pool and the price could not be brought to the target) an ETH-only position
    ///         above the target and a token-only position below the pool price.
    function positionsOf(address token) external view returns (Range[] memory) {
        return positions[token];
    }

    /// @notice Initialized ticks a graduation swap would cross between the pool's price and the target
    ///         (counting stops at MAX_PATH_TICKS + 1).
    function pathTicks(address token, uint160 target) external view returns (uint256) {
        PoolId id = poolKey(token).toId();
        (uint160 cur,,,) = manager.getSlot0(id);
        return _initializedTicksBetween(id, cur, target);
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
        PoolId id = key.toId();
        // solhint-disable-next-line no-empty-blocks
        try manager.initialize(key, target) {}
        catch {
            pre = true;
            (uint160 cur,,,) = manager.getSlot0(id);
            // Move the price toward the target with a price limit. The pool key is public, so a third party
            // may have initialized the pool and parked liquidity between the current price and the target;
            // the swap then trades with it. Spend only the part of our stock that the full-range position
            // could not use anyway (see _swapBudget), so the position stays fundable whatever is absorbed.
            // Through an empty pool the price moves to the target for free. The swap's gas grows with every
            // initialized tick on the path, which a third party controls, so it is only attempted when at
            // most MAX_PATH_TICKS are in the way; otherwise the price stays where it is and the positions
            // below are placed around the target instead.
            if (cur != target && _initializedTicksBetween(id, cur, target) <= MAX_PATH_TICKS) {
                (bool zeroForOne, uint256 budget) = _swapBudget(cur, target, eth, tokens);
                BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, -int256(budget), target), "");
                eth = uint256(int256(eth) + d.amount0());
                tokens = uint256(int256(tokens) + d.amount1());
            }
        }
        (uint160 sqrtP,,,) = manager.getSlot0(id);
        BalanceDelta d2 = sqrtP == target
            ? _addPosition(
                key, token, TICK_LOWER, TICK_UPPER, _liquidityFor(TICK_LOWER, TICK_UPPER, sqrtP, eth, tokens)
            )
            : _addSplitPositions(key, token, target, eth, tokens);
        _settleOpen(key);
        emit GraduatedToPool(token, target, sqrtP, pre, sqrtP != target);
        _finishGraduation(token, d2);
    }

    /// @dev The price could not be brought to the target. A full-range position here would offer our ETH to
    ///      token sellers at prices better than the target (ruinous when the pool sits far below it), so
    ///      instead: all ETH goes in a range strictly above both the pool tick and the target, all tokens in a
    ///      range at or below both. Neither side ever trades at a price worse for the pad than the target.
    function _addSplitPositions(PoolKey memory key, address token, uint160 target, uint256 eth, uint256 tokens)
        internal
        returns (BalanceDelta d2)
    {
        (int24 ethLower, int24 tokUpper) = _splitTicks(key.toId(), target);
        if (ethLower < TICK_UPPER) {
            d2 = _addPosition(key, token, ethLower, TICK_UPPER, _liquidityFor(ethLower, TICK_UPPER, 0, eth, 0));
        }
        if (tokUpper > TICK_LOWER) d2 = d2 + _addTokenSide(key, token, tokUpper, tokens);
    }

    function _addTokenSide(PoolKey memory key, address token, int24 tokUpper, uint256 tokens)
        internal
        returns (BalanceDelta)
    {
        uint160 b = TickMath.getSqrtPriceAtTick(tokUpper);
        return _addPosition(key, token, TICK_LOWER, tokUpper, _liquidityFor(TICK_LOWER, tokUpper, b, 0, tokens));
    }

    /// @dev Boundaries of the split positions: the ETH range starts strictly above both the pool tick and the
    ///      target tick; the token range ends at or below both.
    function _splitTicks(PoolId id, uint160 target) internal view returns (int24 ethLower, int24 tokUpper) {
        (, int24 tick,,) = manager.getSlot0(id);
        int24 tTarget = TickMath.getTickAtSqrtPrice(target);
        ethLower = _floorTick(tick > tTarget ? tick : tTarget) + TICK_SPACING;
        tokUpper = _floorTick(tick < tTarget ? tick : tTarget);
    }

    function _addPosition(PoolKey memory key, address token, int24 lower, int24 upper, uint128 liq)
        internal
        returns (BalanceDelta d)
    {
        if (liq == 0) return d;
        (d,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liq)), bytes32(0)), "");
        positions[token].push(Range(lower, upper));
        emit PositionAdded(token, lower, upper, liq);
    }

    /// @dev Largest multiple of TICK_SPACING at or below `tick`.
    function _floorTick(int24 tick) internal pure returns (int24 c) {
        c = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) c--;
        return c * TICK_SPACING;
    }

    /// @dev Number of initialized ticks in the tick bitmap between the two sqrt prices (inclusive on both ends,
    ///      so it never undercounts what a swap between them would cross). Stops at MAX_PATH_TICKS + 1.
    function _initializedTicksBetween(PoolId id, uint160 a, uint160 b) internal view returns (uint256 n) {
        int24 ta = TickMath.getTickAtSqrtPrice(a);
        int24 tb = TickMath.getTickAtSqrtPrice(b);
        if (ta > tb) (ta, tb) = (tb, ta);
        int24 cLo = _floorTick(ta) / TICK_SPACING;
        int24 cHi = _floorTick(tb) / TICK_SPACING;
        int16 wLo = int16(cLo >> 8);
        int16 wHi = int16(cHi >> 8);
        for (int16 w = wLo; w <= wHi; w++) {
            uint256 bits = manager.getTickBitmap(id, w);
            if (w == wLo) bits &= ~((uint256(1) << uint256(int256(cLo) - (int256(w) << 8))) - 1);
            if (w == wHi) {
                uint256 top = uint256(int256(cHi) - (int256(w) << 8));
                if (top < 255) bits &= (uint256(1) << (top + 1)) - 1;
            }
            while (bits != 0) {
                bits &= bits - 1;
                if (++n > MAX_PATH_TICKS) return n;
            }
        }
    }

    function _finishGraduation(address token, BalanceDelta d2) internal {
        // leftovers: tokens to dEaD, ETH rounding dust to the carry pot (never into the pool price)
        uint256 left = IPadToken(token).balanceOf(address(this));
        if (left != 0) IPadToken(token).transfer(DEAD, left);
        uint256 dust = address(this).balance - burnBucket;
        if (dust != 0) pad.addCarry{value: dust}();
        emit LiquidityAdded(token, uint256(-int256(d2.amount0())), uint256(-int256(d2.amount1())), left);
    }

    /// @dev How much of our own stock the pre-initialized-pool swap may spend. Selling X of the side in excess
    ///      at prices between `cur` and `target` brings in at most X * (worst price on the path) of the other
    ///      side, which then needs pairing at the target too; X <= excess / (1 + (target/cur)^2) keeps the
    ///      full-range position fundable with every unit of the scarce side after the swap. At least 1 wei is
    ///      swapped so that an empty pool still has its price moved to the target (nothing is consumed there).
    function _swapBudget(uint160 cur, uint160 target, uint256 eth, uint256 tokens)
        internal
        pure
        returns (bool zeroForOne, uint256 budget)
    {
        uint160 lo = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 hi = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        if (cur < target) {
            // token pricier than at the target: we sell tokens for ETH (oneForZero)
            uint256 l0 = FullMath.mulDiv(eth, FullMath.mulDiv(target, hi, FixedPoint96.Q96), hi - target);
            uint256 need = FullMath.mulDiv(l0, target - lo, FixedPoint96.Q96) + 1;
            if (tokens > need) budget = _share(tokens - need, cur, target);
        } else {
            // token cheaper than at the target: we buy tokens with ETH (zeroForOne)
            zeroForOne = true;
            uint256 l1 = FullMath.mulDiv(tokens, FixedPoint96.Q96, target - lo);
            uint256 need = FullMath.mulDiv(l1, hi - target, FullMath.mulDiv(target, hi, FixedPoint96.Q96)) + 1;
            if (eth > need) budget = _share(eth - need, target, cur);
        }
        if (budget == 0) budget = 1;
    }

    /// @dev excess * a^2 / (a^2 + b^2) for sqrt prices a <= b, without overflow (0 when b/a is astronomical).
    function _share(uint256 excess, uint160 a, uint160 b) internal pure returns (uint256) {
        uint256 q = FullMath.mulDiv(b, FixedPoint96.Q96, a); // b/a in X96, >= Q96
        if (q >= 1 << 128) return 0;
        uint256 r = q * q / FixedPoint96.Q96; // (b/a)^2 in X96
        return FullMath.mulDiv(excess, FixedPoint96.Q96, FixedPoint96.Q96 + r);
    }

    function _collect(PoolKey memory key, address token) internal {
        BalanceDelta fees;
        Range[] storage rs = positions[token];
        for (uint256 i; i < rs.length; i++) {
            (BalanceDelta f,) =
                manager.modifyLiquidity(key, ModifyLiquidityParams(rs[i].lower, rs[i].upper, 0, bytes32(0)), "");
            fees = fees + f;
        }
        uint256 fee0 = uint256(int256(fees.amount0()));
        uint256 fee1 = uint256(int256(fees.amount1()));
        uint256 held = IPadToken(token).balanceOf(address(this));
        uint256 sell = fee1 + held;
        if (sell > SELL_CHUNK) sell = SELL_CHUNK;
        // Anyone may trigger this sale, so keep it too small to sandwich: at most 1/DEPTH_DIVISOR of the token
        // side of the pool's active liquidity, and never past a 1% move of the sqrt price. What is not sold
        // stays here for the next collection. A sandwich pays the 1% pool fee twice on its own volume, which
        // exceeds what it can extract from a chunk this small.
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint256 depth = FullMath.mulDiv(manager.getLiquidity(key.toId()), sqrtP, FixedPoint96.Q96) / DEPTH_DIVISOR;
        if (sell > depth) sell = depth;
        uint256 out;
        if (sell != 0) {
            uint160 limit = uint160(uint256(sqrtP) + uint256(sqrtP) / 100);
            if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
            BalanceDelta d = manager.swap(key, SwapParams(false, -int256(sell), limit), "");
            out = uint256(int256(d.amount0()));
            sell = uint256(-int256(d.amount1()));
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

    /// @dev Largest liquidity in [lowerTick, upperTick] fundable with the given amounts at price `sqrtP`, with a
    ///      tiny safety margin for rounding. Returns 0 (no position) instead of reverting when either side
    ///      cannot fund any liquidity.
    function _liquidityFor(int24 lowerTick, int24 upperTick, uint160 sqrtP, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint160 lo = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 hi = TickMath.getSqrtPriceAtTick(upperTick);
        uint256 l;
        if (sqrtP <= lo) {
            l = FullMath.mulDiv(amount0, FullMath.mulDiv(lo, hi, FixedPoint96.Q96), hi - lo);
        } else if (sqrtP >= hi) {
            l = FullMath.mulDiv(amount1, FixedPoint96.Q96, hi - lo);
        } else {
            uint256 l0 = FullMath.mulDiv(amount0, FullMath.mulDiv(sqrtP, hi, FixedPoint96.Q96), hi - sqrtP);
            uint256 l1 = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtP - lo);
            l = l0 < l1 ? l0 : l1;
        }
        if (l <= 1) return 0;
        l = l - l / 1_000_000 - 1;
        if (l > type(uint128).max) l = type(uint128).max;
        return uint128(l);
    }
}

interface IKingView {
    function king() external view returns (address);
}
