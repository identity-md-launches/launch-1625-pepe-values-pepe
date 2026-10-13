// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPvPPad, IPadGame, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title KingOfThePad
/// @notice Crown auction: the king receives every graduated pool's LP fees. Its constructor binds to the pad
///         and PadLiquidity and starts the genesis launch.
contract KingOfThePad {
    address public constant DEV = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    uint256 public constant MIN_FIRST_BID = 0.01 ether;
    uint256 public constant HOLD_SECONDS = 1 hours;
    uint256 public constant DISTRIBUTE_BATCH = 2;
    uint256 internal constant PUSH_GAS = 30_000;

    IPvPPad public immutable pad;
    IPadLiquidity public immutable liquidity;

    address public king;
    uint256 public bid;
    uint64 public crownedAt;
    uint256 public totalToPots;
    uint256 public totalToBurn;
    uint256 public totalToDev;
    bool internal locked;

    event Crowned(address indexed king, uint256 bid, address indexed previous, uint256 refunded, uint256 extra);
    event ExtraSplit(uint256 toPots, uint256 games, uint256 toCarry, uint256 toBurn, uint256 toDev);

    error NotOpen();
    error GenesisPending();
    error TooLow();
    error TooSoon();
    error Reentrant();

    modifier nonReentrant() {
        if (locked) revert Reentrant();
        locked = true;
        _;
        locked = false;
    }

    constructor(address pad_, address liquidity_) {
        pad = IPvPPad(pad_);
        liquidity = IPadLiquidity(liquidity_);
        IPvPPad(pad_).setKing();
        IPadLiquidity(liquidity_).setKing();
        IPvPPad(pad_).startGenesis();
    }

    function minBid() public view returns (uint256) {
        return king == address(0) ? MIN_FIRST_BID : bid * 110 / 100;
    }

    function canTake() public view returns (bool) {
        return king == address(0) || block.timestamp >= crownedAt + HOLD_SECONDS;
    }

    /// @notice Take the crown. First bid >= 0.01 ETH, then >= 110% of the current bid once the king held 1h.
    function takeCrown() external payable nonReentrant {
        if (!pad.isOpen()) revert NotOpen();
        if (!pad.pvpDone()) revert GenesisPending();
        if (msg.value < minBid()) revert TooLow();
        if (!canTake()) revert TooSoon();
        // pay the outgoing king their pending fees first
        _distribute(DISTRIBUTE_BATCH);
        address old = king;
        uint256 oldBid = bid;
        uint256 extra = msg.value - oldBid;
        king = msg.sender;
        bid = msg.value;
        crownedAt = uint64(block.timestamp);
        emit Crowned(msg.sender, msg.value, old, oldBid, extra);
        if (oldBid != 0) _push(old, oldBid);
        _split(extra);
        pad.upkeep(msg.sender);
    }

    /// @notice Collect LP fees from the next n pools and send them to the king.
    function distribute(uint256 n) external nonReentrant {
        _distribute(n);
    }

    function _distribute(uint256 n) internal {
        if (king == address(0)) return;
        // solhint-disable-next-line no-empty-blocks
        try liquidity.distribute(n) {} catch {}
    }

    function _split(uint256 extra) internal {
        uint256 toPots = extra / 2;
        uint256 toBurn = extra / 4;
        uint256 toDev = extra - toPots - toBurn;
        address[] memory games = pad.liveGames(10);
        uint256 carry;
        if (games.length == 0) {
            carry = toPots;
            if (toPots != 0) pad.addCarry{value: toPots}();
        } else {
            uint256 share = toPots / games.length;
            uint256 rem = toPots - share * games.length;
            for (uint256 i; i < games.length; i++) {
                uint256 amt = i == 0 ? share + rem : share;
                if (amt != 0) IPadGame(games[i]).fundPot{value: amt}();
            }
        }
        totalToPots += toPots;
        totalToBurn += toBurn;
        totalToDev += toDev;
        if (toBurn != 0) liquidity.depositBurn{value: toBurn}();
        if (toDev != 0) _push(DEV, toDev);
        emit ExtraSplit(toPots, games.length, carry, toBurn, toDev);
    }

    function _push(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount, gas: PUSH_GAS}("");
        if (!ok) pad.holdFor{value: amount}(to);
    }
}
