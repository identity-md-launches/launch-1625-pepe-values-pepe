// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IArbSys, IPvPPad, IPadToken, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PadGame
/// @notice EIP-1167 clone template: the bonding curve and the Spireth game of one launch.
/// @dev Timing in seconds uses block.timestamp (the sequencer clock); block ordering and randomness use
///      ArbSys (0x64) arbBlockNumber / arbBlockHash. block.number, blockhash and prevrandao are never used.
contract PadGame {
    // ---------------------------------------------------------------- constants
    IArbSys internal constant ARB = IArbSys(address(0x64));
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant ROLL_PRICE = 0.002 ether;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant V_ETH = 1 ether;
    uint256 internal constant K = V_ETH * SUPPLY;
    uint64 public constant SIGNUP_SECONDS = 10 minutes;
    uint64 public constant GAME_SECONDS = 60 minutes;
    uint64 public constant DEATH_SECONDS = 10 minutes;
    uint64 public constant COOLDOWN = 60 seconds;
    uint256 public constant MAX_IMPS = 200;
    int8 public constant MAX_HEIGHT = 50;
    int8 public constant MISSED_PENALTY = 4; // a roll unresolved past the hash window moves |height| down by this
    uint256 public constant RESOLVE_BATCH = 8;
    uint256 public constant PAY_BATCH = 25;
    uint256 public constant HASH_WINDOW = 256;
    uint256 public constant FINALIZER_CAP = 0.005 ether;
    uint256 internal constant PUSH_GAS = 30_000;

    // phases
    uint8 public constant PHASE_WAITING = 0;
    uint8 public constant PHASE_RUNNING = 1; // signup then play, decided by time
    uint8 public constant PHASE_PAYING = 2;
    uint8 public constant PHASE_GRADUATED = 3;
    uint8 public constant PHASE_FAILED = 4;

    // ---------------------------------------------------------------- storage
    struct Imp {
        bool exists;
        int8 height;
        uint32 rolls;
        uint32 resolvedNonce;
        uint32 heightSeq;
        uint64 lastRollAt;
    }

    struct Pending {
        address imp;
        uint32 nonce;
        uint64 commitBlock;
    }

    IPvPPad public pad;
    IPadToken public token;
    IPadLiquidity public liquidity;
    bool public isGenesis;
    bool public initialized;
    uint8 public phase;
    uint64 public firstMintAt;
    uint64 public endedAt;
    uint64 public maxLastRollAt;
    bool internal locked;

    uint256 public pot;
    uint256 public curveEth;
    uint256 public tokensSold;

    mapping(address => Imp) internal imps;
    address[] public impList;
    Pending[] internal pending;
    uint256 public pendingHead;

    address public bellRinger;
    address[] public winners;
    uint256 public paidCount;
    uint256 public rankPool;
    uint256 public finalizerFee;
    uint256 public ringerPaid;

    // ---------------------------------------------------------------- events
    event Minted(address indexed imp, uint256 count);
    event SignupStarted(uint64 at, uint64 playStart, uint64 endsBy);
    event Rolled(
        address indexed imp,
        uint32 nonce,
        uint64 commitBlock,
        uint256 tokensOut,
        uint256 toCurve,
        uint256 toPot,
        uint256 toBurn
    );
    event RollResolved(address indexed imp, uint32 nonce, int8 delta, int8 height, bool windowMissed);
    event BellRung(address indexed imp, int8 height, uint64 at);
    event Ended(
        uint64 at,
        uint256 living,
        uint256 paid,
        address bellRinger,
        uint256 rankPool,
        uint256 ringerShare,
        address finalizer,
        uint256 fee
    );
    event Paid(address indexed to, uint256 rank, uint256 amount);
    event CarryAdded(uint256 amount);
    event Graduated(uint256 eth, uint256 tokens, uint160 sqrtPriceX96);
    event Failed();
    event PotFunded(address indexed from, uint256 amount);

    error AlreadyInitialized();
    error NotOpen();
    error NotPad();
    error BadPhase();
    error AlreadyMinted();
    error Full();
    error NotImp();
    error Dead();
    error Cooldown();
    error BadValue();
    error Unresolved();
    error Reentrant();

    modifier nonReentrant() {
        if (locked) revert Reentrant();
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        initialized = true; // template can never be initialized
    }

    function initialize(address pad_, address token_, address liquidity_, bool genesis_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        pad = IPvPPad(pad_);
        token = IPadToken(token_);
        liquidity = IPadLiquidity(liquidity_);
        isGenesis = genesis_;
    }

    // ---------------------------------------------------------------- user actions
    /// @notice Free signup. The first mint starts the 10 minute signup window.
    function mint() external nonReentrant {
        if (!pad.isOpen()) revert NotOpen();
        if (phase > PHASE_RUNNING) revert BadPhase();
        if (phase == PHASE_WAITING) {
            phase = PHASE_RUNNING;
            firstMintAt = uint64(block.timestamp);
            maxLastRollAt = firstMintAt + SIGNUP_SECONDS;
            emit SignupStarted(firstMintAt, firstMintAt + SIGNUP_SECONDS, firstMintAt + GAME_SECONDS);
            pad.onGameStarted();
        } else if (block.timestamp >= firstMintAt + SIGNUP_SECONDS) {
            revert BadPhase();
        }
        Imp storage imp = imps[msg.sender];
        if (imp.exists) revert AlreadyMinted();
        if (impList.length >= MAX_IMPS) revert Full();
        imp.exists = true;
        imp.lastRollAt = firstMintAt + SIGNUP_SECONDS;
        impList.push(msg.sender);
        emit Minted(msg.sender, impList.length);
        _resolveBatch();
        pad.upkeep(msg.sender);
    }

    /// @notice Roll the dice: 0.002 ETH, 90% buys the curve for the roller, 8% pot, 2% burn bucket.
    function roll() external payable nonReentrant {
        if (!pad.isOpen()) revert NotOpen();
        if (msg.value != ROLL_PRICE) revert BadValue();
        if (phase != PHASE_RUNNING || endedAt != 0 || _dueEnd() != 0) revert BadPhase();
        if (block.timestamp < firstMintAt + SIGNUP_SECONDS) revert BadPhase();
        Imp storage imp = imps[msg.sender];
        if (!imp.exists) revert NotImp();
        if (block.timestamp > imp.lastRollAt + DEATH_SECONDS) revert Dead();
        if (imp.rolls != 0 && block.timestamp < imp.lastRollAt + COOLDOWN) revert Cooldown();
        // an Imp's roll resolves its previous one; if that resolution rings the bell, play is over
        if (imp.resolvedNonce != imp.rolls) {
            _resolveImp(msg.sender);
            if (imp.resolvedNonce != imp.rolls) revert Unresolved();
            if (endedAt != 0) revert BadPhase();
        }
        imp.rolls += 1;
        imp.lastRollAt = uint64(block.timestamp);
        if (block.timestamp > maxLastRollAt) maxLastRollAt = uint64(block.timestamp);

        uint256 toCurve = msg.value * 90 / 100;
        uint256 toBurn = msg.value * 2 / 100;
        uint256 toPot = msg.value - toCurve - toBurn;
        uint256 out;
        if (tokensSold < CURVE_SUPPLY) {
            // the roll that sells the curve out pays only for what was left; the rest goes to the pot
            uint256 cost;
            (out, cost) = _buy(toCurve);
            curveEth += cost;
            toPot += toCurve - cost;
            toCurve = cost;
        } else {
            toPot += toCurve;
            toCurve = 0;
        }
        if (isGenesis) {
            toPot += toBurn;
            toBurn = 0;
        }
        pot += toPot;
        uint64 commit = uint64(ARB.arbBlockNumber());
        pending.push(Pending(msg.sender, imp.rolls, commit));
        emit Rolled(msg.sender, imp.rolls, commit, out, toCurve, toPot, toBurn);
        if (out != 0) token.transfer(msg.sender, out);
        if (toBurn != 0) liquidity.depositBurn{value: toBurn}();
        _resolveBatch();
        pad.upkeep(msg.sender);
    }

    /// @notice Permissionless upkeep for this game: resolves rolls, ends, pays, graduates (one step per call).
    function poke() external nonReentrant {
        _poke(msg.sender);
        pad.upkeep(msg.sender);
    }

    /// @notice Same as poke but without re-entering the pad's global upkeep (called by the pad).
    function pokeFrom(address actor) external nonReentrant {
        if (msg.sender != address(pad)) revert NotPad();
        _poke(actor);
    }

    /// @notice Adds ETH to the pot (king splits, carry pot).
    function fundPot() external payable {
        if (msg.sender != address(pad) && msg.sender != pad.king()) revert NotPad();
        if (phase > PHASE_RUNNING) revert BadPhase();
        pot += msg.value;
        emit PotFunded(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------- views
    function getImp(address a) external view returns (Imp memory) {
        return imps[a];
    }

    function impCount() external view returns (uint256) {
        return impList.length;
    }

    function pendingCount() external view returns (uint256) {
        return pending.length - pendingHead;
    }

    function getPending(uint256 i) external view returns (Pending memory) {
        return pending[pendingHead + i];
    }

    function winnerCount() external view returns (uint256) {
        return winners.length;
    }

    function playStart() public view returns (uint64) {
        return firstMintAt == 0 ? 0 : firstMintAt + SIGNUP_SECONDS;
    }

    /// @notice Upper bound of the game's end (60 min after the first mint); 0 while waiting.
    function endsBy() external view returns (uint64) {
        return firstMintAt == 0 ? 0 : firstMintAt + GAME_SECONDS;
    }

    function isLive() external view returns (bool) {
        return phase == PHASE_RUNNING && endedAt == 0 && _dueEnd() == 0;
    }

    function isAlive(address a) external view returns (bool) {
        Imp storage imp = imps[a];
        return imp.exists && block.timestamp <= imp.lastRollAt + DEATH_SECONDS;
    }

    function curveSoldOut() external view returns (bool) {
        return tokensSold >= CURVE_SUPPLY;
    }

    /// @notice Virtual reserves of the curve.
    function reserves() public view returns (uint256 vEth, uint256 vTok) {
        vEth = V_ETH + curveEth;
        vTok = SUPPLY - tokensSold;
    }

    /// @notice Tokens a roll's 90% would buy right now.
    function quote(uint256 ethIn) external view returns (uint256) {
        (uint256 vEth, uint256 vTok) = reserves();
        uint256 newTok = (K + vEth + ethIn - 1) / (vEth + ethIn);
        uint256 out = vTok - newTok;
        uint256 left = CURVE_SUPPLY - tokensSold;
        return out > left ? left : out;
    }

    /// @notice sqrtPriceX96 of the pool (currency0 = ETH, currency1 = token) at the final curve price.
    function graduationSqrtPrice() public view returns (uint160) {
        (uint256 vEth, uint256 vTok) = reserves();
        return uint160(_sqrt((vTok << 96) / vEth) << 48);
    }

    // ---------------------------------------------------------------- internals
    /// @dev Buys with `ethIn`; when that would overshoot the curve, buys exactly what is left and returns its cost.
    function _buy(uint256 ethIn) internal returns (uint256 out, uint256 cost) {
        (uint256 vEth, uint256 vTok) = reserves();
        uint256 newTok = (K + vEth + ethIn - 1) / (vEth + ethIn); // round the reserve up: buyer never overpaid by rounding
        out = vTok - newTok;
        cost = ethIn;
        uint256 left = CURVE_SUPPLY - tokensSold;
        if (out > left) {
            out = left;
            newTok = vTok - left;
            cost = (K + newTok - 1) / newTok - vEth; // ETH that moves the reserve exactly to the curve's end
        }
        tokensSold += out;
    }

    /// @dev Time at which the game ended (bell, all dead, or 60 min), or 0 if still running.
    function _dueEnd() internal view returns (uint64) {
        if (endedAt != 0) return endedAt;
        if (phase != PHASE_RUNNING) return 0;
        uint64 tMax = firstMintAt + GAME_SECONDS;
        uint64 tDead = maxLastRollAt + DEATH_SECONDS + 1;
        uint64 t = tMax < tDead ? tMax : tDead;
        return block.timestamp >= t ? t : 0;
    }

    function _resolveBatch() internal {
        uint256 n;
        while (pendingHead < pending.length && n < RESOLVE_BATCH) {
            if (!_resolve(pendingHead)) break;
            pendingHead++;
            n++;
        }
    }

    /// @dev Resolves the imp's latest unresolved roll out of queue order.
    function _resolveImp(address a) internal {
        for (uint256 i = pending.length; i > pendingHead; i--) {
            if (pending[i - 1].imp == a) {
                _resolve(i - 1);
                return;
            }
        }
    }

    function _resolve(uint256 idx) internal returns (bool) {
        Pending storage p = pending[idx];
        Imp storage imp = imps[p.imp];
        if (imp.resolvedNonce >= p.nonce) return true; // already resolved out of order
        uint256 cur = ARB.arbBlockNumber();
        uint256 c = p.commitBlock;
        if (cur <= c + 3) return false;
        int8 delta;
        bool missed = cur > c + 1 + HASH_WINDOW;
        if (!missed) {
            uint256 r = uint256(
                keccak256(
                    abi.encode(
                        address(this),
                        p.imp,
                        p.nonce,
                        ARB.arbBlockHash(c + 1),
                        ARB.arbBlockHash(c + 2),
                        ARB.arbBlockHash(c + 3)
                    )
                )
            ) % 8;
            delta = r < 4 ? -int8(int256(4 - r)) : int8(int256(r - 3));
        } else {
            // The outcome is public from block c+4 and anyone may resolve it, so a roll left unresolved past
            // the hash window must never be better for the roller than any die: it moves |height| down by
            // MISSED_PENALTY (not past 0). Expiring a roll is therefore never preferable to resolving it.
            int8 h0 = imp.height;
            if (h0 > 0) delta = h0 > MISSED_PENALTY ? -MISSED_PENALTY : -h0;
            else if (h0 < 0) delta = -h0 > MISSED_PENALTY ? MISSED_PENALTY : -h0;
        }
        imp.resolvedNonce = p.nonce;
        int8 h = imp.height + delta;
        if (h > MAX_HEIGHT) h = MAX_HEIGHT;
        if (h < -MAX_HEIGHT) h = -MAX_HEIGHT;
        if (h != imp.height) {
            imp.height = h;
            // tie-break by commit order (queue position), not by who resolved first
            imp.heightSeq = uint32(idx + 1);
        }
        emit RollResolved(p.imp, p.nonce, delta, h, missed);
        if ((h == MAX_HEIGHT || h == -MAX_HEIGHT) && endedAt == 0 && _dueEnd() == 0) {
            endedAt = uint64(block.timestamp);
            bellRinger = p.imp;
            emit BellRung(p.imp, h, endedAt);
        }
        return true;
    }

    function _poke(address actor) internal {
        if (phase == PHASE_RUNNING) {
            _resolveBatch();
            uint64 end = _dueEnd();
            if (end == 0) return;
            if (pendingHead < pending.length) return; // wait for every roll committed before the end
            if (endedAt == 0) endedAt = end;
            _finalize(actor);
            return;
        }
        if (phase == PHASE_PAYING) {
            if (paidCount < winners.length) {
                _payBatch();
                return;
            }
            _graduate();
        }
    }

    /// @dev Living imps ranked by |height| desc, earlier heightReachedAt (commit order of the roll that set the
    ///      height) first; insertion sort, <=200 in memory.
    function _rankLiving(uint64 end) internal view returns (address[] memory living, uint256 m) {
        uint256 n = impList.length;
        living = new address[](n);
        uint256[] memory keys = new uint256[](n);
        for (uint256 i; i < n; i++) {
            address a = impList[i];
            Imp storage imp = imps[a];
            if (imp.lastRollAt + DEATH_SECONDS < end) continue;
            uint256 absH = imp.height < 0 ? uint256(uint8(-imp.height)) : uint256(uint8(imp.height));
            uint256 key = (absH << 64) | (type(uint64).max - imp.heightSeq);
            // insertion sort, descending by key (|height| desc, earlier heightReachedAt first)
            uint256 j = m;
            while (j > 0 && keys[j - 1] < key) {
                keys[j] = keys[j - 1];
                living[j] = living[j - 1];
                j--;
            }
            keys[j] = key;
            living[j] = a;
            m++;
        }
    }

    function _finalize(address actor) internal {
        (address[] memory living, uint256 m) = _rankLiving(endedAt);
        uint256 p = pot;
        uint256 fee = p * 5 / 1000;
        if (fee > FINALIZER_CAP) fee = FINALIZER_CAP;
        uint256 rest = p - fee;
        uint256 paidN = (m + 1) / 2;
        uint256 ringerShare;
        phase = PHASE_PAYING;
        pot = 0;
        finalizerFee = fee;
        if (m == 0) {
            if (rest != 0) {
                pad.addCarry{value: rest}();
                emit CarryAdded(rest);
            }
        } else {
            if (bellRinger != address(0)) ringerShare = rest * 20 / 100;
            rankPool = rest - ringerShare;
            for (uint256 i; i < paidN; i++) {
                winners.push(living[i]);
            }
        }
        emit Ended(endedAt, m, paidN, bellRinger, rankPool, ringerShare, actor, fee);
        pad.onGameFinalized();
        if (fee != 0) _push(actor, fee);
        if (ringerShare != 0) {
            ringerPaid = ringerShare;
            _push(bellRinger, ringerShare);
        }
    }

    function _payBatch() internal {
        uint256 total = winners.length;
        uint256 weightSum = total * (total + 1) / 2;
        uint256 i = paidCount;
        uint256 stop = i + PAY_BATCH;
        if (stop > total) stop = total;
        uint256 paidSum;
        for (; i < stop; i++) {
            uint256 amount = rankPool * (total - i) / weightSum;
            paidSum += amount;
            emit Paid(winners[i], i, amount);
            _push(winners[i], amount);
        }
        paidCount = stop;
        if (stop == total) {
            // rounding dust: carry pot
            uint256 dust = address(this).balance - curveEth;
            if (dust != 0) {
                pad.addCarry{value: dust}();
                emit CarryAdded(dust);
            }
        }
    }

    function _graduate() internal {
        uint256 eth = curveEth;
        uint256 toks = token.balanceOf(address(this));
        bool failedLaunch = eth == 0;
        uint160 sqrtP = graduationSqrtPrice();
        phase = failedLaunch ? PHASE_FAILED : PHASE_GRADUATED;
        curveEth = 0;
        token.transfer(address(liquidity), toks);
        liquidity.graduate{value: eth}(address(token), sqrtP);
        if (failedLaunch) emit Failed();
        else emit Graduated(eth, toks, sqrtP);
        pad.onGameDone(failedLaunch);
    }

    /// @dev Gas-capped push; a failed send is held in the pad for the recipient to claim.
    function _push(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount, gas: PUSH_GAS}("");
        if (!ok) pad.holdFor{value: amount}(to);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
