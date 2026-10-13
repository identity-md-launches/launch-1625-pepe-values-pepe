// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPadGame, IPadToken, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PvPPad
/// @notice Registry and factory of launches, carry pot, failed-send escrow, open switch and global upkeep.
/// @dev The owner's only power is openPad(). dev is immutable. Later contracts (PadLiquidity, KingOfThePad)
///      bind themselves once from their constructors.
contract PvPPad {
    address public constant DEV = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    uint256 public constant OPEN_DELAY = 30 days;
    uint256 public constant MAX_LIVE = 10;
    uint256 public constant LIVE_SCAN = 64;
    uint256 internal constant POKE_GAS = 3_000_000;
    uint256 internal constant DISTRIBUTE_GAS = 1_500_000;
    uint256 internal constant BURN_GAS = 700_000;

    struct Launch {
        address token;
        address game;
        string name;
        string ticker;
        string imageURL;
        uint64 createdAt;
    }

    address public immutable owner;
    address public immutable tokenTemplate;
    address public immutable gameTemplate;
    uint64 public immutable deployedAt;

    address public liquidity;
    address public king;
    bool public opened;
    uint64 public openedAt;
    bool public pvpDone;
    bool public pvpFailed;
    address public genesisToken;
    address public genesisGame;

    Launch[] internal launches;
    mapping(address => bool) public isGame;
    mapping(address => uint256) public gameIndex; // game => launch index
    address[] internal active; // games not yet graduated/failed
    mapping(address => uint256) internal activeIndex; // 1-based
    uint256 public upkeepCursor;
    bool internal upkeepRunning;

    uint256 public carryPot;
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;

    event Opened(address indexed by, uint64 at);
    event Launched(
        uint256 indexed id,
        address indexed token,
        address indexed game,
        string name,
        string ticker,
        string imageURL,
        uint256 carryIn
    );
    event LiquidityBound(address liquidity);
    event KingBound(address king);
    event GenesisDone(bool failed);
    event CarryIn(address indexed from, uint256 amount);
    event CarryOut(address indexed game, uint256 amount);
    event Held(address indexed to, uint256 amount);
    event Claimed(address indexed to, uint256 amount);
    event GameFinalized(address indexed game);
    event GameDone(address indexed game, bool failed);
    event UpkeepPoked(address indexed game, bool ok);

    error NotOpen();
    error AlreadyOpened();
    error NotAllowed();
    error AlreadyBound();
    error GenesisPending();
    error BadInput();
    error NotGame();
    error Nothing();
    error SendFailed();

    constructor(address owner_, address tokenTemplate_, address gameTemplate_) {
        owner = owner_;
        tokenTemplate = tokenTemplate_;
        gameTemplate = gameTemplate_;
        deployedAt = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- open switch
    /// @notice Owner any time, or anyone 30 days after deployment. One-way.
    function openPad() external {
        if (opened) revert AlreadyOpened();
        if (msg.sender != owner && block.timestamp < deployedAt + OPEN_DELAY) revert NotAllowed();
        opened = true;
        openedAt = uint64(block.timestamp);
        emit Opened(msg.sender, openedAt);
    }

    function isOpen() external view returns (bool) {
        return opened;
    }

    // ---------------------------------------------------------------- one-shot bindings
    function setLiquidity() external {
        if (liquidity != address(0)) revert AlreadyBound();
        liquidity = msg.sender;
        emit LiquidityBound(msg.sender);
    }

    function setKing() external {
        if (king != address(0)) revert AlreadyBound();
        king = msg.sender;
        emit KingBound(msg.sender);
    }

    /// @notice Creates launch #1 "Pepes Value Pepes" (PvP). Called once from KingOfThePad's constructor.
    function startGenesis() external {
        if (msg.sender != king || genesisGame != address(0)) revert NotAllowed();
        if (liquidity == address(0)) revert NotAllowed();
        (address t, address g) = _create("Pepes Value Pepes", "PvP", "", true);
        genesisToken = t;
        genesisGame = g;
    }

    // ---------------------------------------------------------------- launches
    function launch(string calldata name, string calldata ticker, string calldata imageURL)
        external
        returns (address token, address game)
    {
        if (!opened) revert NotOpen();
        if (!pvpDone) revert GenesisPending();
        if (
            bytes(name).length == 0 || bytes(name).length > 32 || bytes(ticker).length == 0 || bytes(ticker).length > 10
                || bytes(imageURL).length > 200
        ) {
            revert BadInput();
        }
        (token, game) = _create(name, ticker, imageURL, false);
        _upkeep(msg.sender);
    }

    function _create(string memory name, string memory ticker, string memory imageURL, bool genesis)
        internal
        returns (address token, address game)
    {
        token = _clone(tokenTemplate);
        game = _clone(gameTemplate);
        IPadToken(token).initialize(name, ticker, imageURL, game, liquidity);
        IPadGame(game).initialize(address(this), token, liquidity, genesis);
        uint256 id = launches.length;
        launches.push(Launch(token, game, name, ticker, imageURL, uint64(block.timestamp)));
        isGame[game] = true;
        gameIndex[game] = id;
        active.push(game);
        activeIndex[game] = active.length;
        uint256 carry = carryPot;
        if (carry != 0) {
            carryPot = 0;
            IPadGame(game).fundPot{value: carry}();
            emit CarryOut(game, carry);
        }
        emit Launched(id, token, game, name, ticker, imageURL, carry);
    }

    function _clone(address impl) internal returns (address inst) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            inst := create(0, 0x09, 0x37)
        }
        require(inst != address(0), "clone");
    }

    // ---------------------------------------------------------------- game callbacks
    function onGameFinalized() external {
        if (!isGame[msg.sender]) revert NotGame();
        emit GameFinalized(msg.sender);
    }

    function onGameDone(bool failed) external {
        if (!isGame[msg.sender]) revert NotGame();
        _removeActive(msg.sender);
        if (msg.sender == genesisGame && !pvpDone) {
            pvpDone = true;
            pvpFailed = failed;
            emit GenesisDone(failed);
        }
        emit GameDone(msg.sender, failed);
    }

    function _removeActive(address game) internal {
        uint256 idx = activeIndex[game];
        if (idx == 0) return;
        uint256 last = active.length;
        if (idx != last) {
            address moved = active[last - 1];
            active[idx - 1] = moved;
            activeIndex[moved] = idx;
        }
        active.pop();
        activeIndex[game] = 0;
    }

    /// @notice ETH for the next launched game's pot. Games, the king and anyone else may add.
    function addCarry() external payable {
        carryPot += msg.value;
        emit CarryIn(msg.sender, msg.value);
    }

    /// @notice Escrow for a push that failed; only system contracts may deposit.
    function holdFor(address to) external payable {
        if (!isGame[msg.sender] && msg.sender != liquidity && msg.sender != king) revert NotGame();
        claimable[to] += msg.value;
        totalClaimable += msg.value;
        emit Held(to, msg.value);
    }

    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert Nothing();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert SendFailed();
        emit Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- views
    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function getLaunch(uint256 id) external view returns (Launch memory) {
        return launches[id];
    }

    function activeCount() external view returns (uint256) {
        return active.length;
    }

    function activeGame(uint256 i) external view returns (address) {
        return active[i];
    }

    /// @notice Up to `max` live games (started, not ended), soonest ending first, scanned over the first
    ///         LIVE_SCAN active games.
    function liveGames(uint256 max) external view returns (address[] memory out) {
        if (max > MAX_LIVE) max = MAX_LIVE;
        uint256 n = active.length;
        if (n > LIVE_SCAN) n = LIVE_SCAN;
        address[] memory buf = new address[](max);
        uint64[] memory ends = new uint64[](max);
        uint256 m;
        for (uint256 i; i < n; i++) {
            IPadGame g = IPadGame(active[i]);
            if (!g.isLive()) continue;
            uint64 e = g.endsBy();
            if (m == max && e >= ends[m - 1]) continue;
            uint256 j = m == max ? m - 1 : m;
            while (j > 0 && ends[j - 1] > e) {
                ends[j] = ends[j - 1];
                buf[j] = buf[j - 1];
                j--;
            }
            ends[j] = e;
            buf[j] = address(g);
            if (m < max) m++;
        }
        out = new address[](m);
        for (uint256 i; i < m; i++) {
            out[i] = buf[i];
        }
    }

    // ---------------------------------------------------------------- upkeep
    /// @notice Bounded global upkeep: poke one active game round-robin, distribute 2 pools, burn a chunk.
    ///         Called by every state-changing action of the system; also callable by anyone.
    function upkeep(address actor) external {
        _upkeep(actor);
    }

    function _upkeep(address actor) internal {
        if (upkeepRunning) return;
        upkeepRunning = true;
        uint256 n = active.length;
        if (n != 0) {
            address g = active[upkeepCursor % n];
            upkeepCursor++;
            if (g != msg.sender) {
                // solhint-disable-next-line no-empty-blocks
                try IPadGame(g).pokeFrom{gas: POKE_GAS}(actor) {
                    emit UpkeepPoked(g, true);
                } catch {
                    emit UpkeepPoked(g, false);
                }
            }
        }
        address liq = liquidity;
        if (liq != address(0) && liq != msg.sender) {
            // solhint-disable-next-line no-empty-blocks
            try IPadLiquidity(liq).distribute{gas: DISTRIBUTE_GAS}(2) {} catch {}
            // solhint-disable-next-line no-empty-blocks
            try IPadLiquidity(liq).burnChunk{gas: BURN_GAS}() {} catch {}
        }
        upkeepRunning = false;
    }
}
