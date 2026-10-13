// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Arbitrum ArbSys precompile at 0x64 (Robinhood Chain is an Arbitrum Orbit chain).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 arbBlockNum) external view returns (bytes32);
}

interface IPadToken {
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata imageURL_,
        address game_,
        address liquidity_
    ) external;
    function unlock() external;
    function game() external view returns (address);
    function unlocked() external view returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPadGame {
    function initialize(address pad_, address token_, address liquidity_, bool genesis_) external;
    function fundPot() external payable;
    function pokeFrom(address actor) external;
    function isLive() external view returns (bool);
    function endsBy() external view returns (uint64);
    function phase() external view returns (uint8);
}

interface IPvPPad {
    function isOpen() external view returns (bool);
    function isGame(address) external view returns (bool);
    function pvpDone() external view returns (bool);
    function pvpFailed() external view returns (bool);
    function genesisToken() external view returns (address);
    function king() external view returns (address);
    function liquidity() external view returns (address);
    function holdFor(address to) external payable;
    function addCarry() external payable;
    function onGameFinalized() external;
    function onGameDone(bool failed) external;
    function liveGames(uint256 max) external view returns (address[] memory);
    function upkeep(address actor) external;
    function setLiquidity() external;
    function setKing() external;
    function startGenesis() external;
}

interface IPadLiquidity {
    function graduate(address token, uint160 sqrtPriceX96) external payable;
    function depositBurn() external payable;
    function burnChunk() external;
    function distribute(uint256 n) external;
    function setKing() external;
}

interface IKing {
    function king() external view returns (address);
}
