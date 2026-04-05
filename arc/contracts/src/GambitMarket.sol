// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GambitMarket
/// @notice 5-minute crypto prediction markets on Arc. Stablecoin-native (USDC).
/// @dev Settlement via Chainlink CRE workflow (price feed + on-chain callback).
contract GambitMarket {
    error MarketDoesNotExist();
    error MarketAlreadySettled();
    error MarketNotSettled();
    error MarketNotExpired();
    error InvalidAmount();
    error NothingToClaim();
    error AlreadyClaimed();
    error TransferFailed();

    event MarketCreated(
        uint256 indexed marketId,
        string asset,
        uint256 strikePrice,
        uint48 startTime,
        uint48 endTime
    );
    event PositionOpened(
        uint256 indexed marketId,
        address indexed user,
        Direction direction,
        uint256 amount
    );
    event SettlementRequested(
        uint256 indexed marketId,
        string asset,
        uint256 strikePrice,
        uint48 endTime
    );
    event MarketSettled(
        uint256 indexed marketId,
        uint256 finalPrice,
        Direction outcome
    );
    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 amount
    );

    enum Direction {
        Up,
        Down
    }

    struct Market {
        string asset;          // "btc", "eth", "xrp"
        uint256 strikePrice;   // price at market creation (8 decimals)
        uint256 finalPrice;    // price at settlement (8 decimals)
        uint48 startTime;
        uint48 endTime;
        bool settled;
        Direction outcome;
        uint256 totalUpPool;
        uint256 totalDownPool;
    }

    struct Position {
        uint256 amount;
        Direction direction;
        bool claimed;
    }

    IERC20 public immutable usdc;
    address public operator;

    uint256 public nextMarketId;
    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => Position)) public positions;

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    constructor(address _usdc, address _operator) {
        usdc = IERC20(_usdc);
        operator = _operator;
    }

    /// @notice Create a new 5-minute prediction market.
    function createMarket(
        string memory asset,
        uint256 strikePrice,
        uint48 duration
    ) external onlyOperator returns (uint256 marketId) {
        marketId = nextMarketId++;
        uint48 startTime = uint48(block.timestamp);
        uint48 endTime = startTime + duration;

        markets[marketId] = Market({
            asset: asset,
            strikePrice: strikePrice,
            finalPrice: 0,
            startTime: startTime,
            endTime: endTime,
            settled: false,
            outcome: Direction.Up,
            totalUpPool: 0,
            totalDownPool: 0
        });

        emit MarketCreated(marketId, asset, strikePrice, startTime, endTime);
    }

    /// @notice Place a bet on a market. Requires USDC approval.
    function placeBet(
        uint256 marketId,
        Direction direction,
        uint256 amount
    ) external {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketDoesNotExist();
        if (m.settled) revert MarketAlreadySettled();
        if (block.timestamp >= m.endTime) revert MarketAlreadySettled();
        if (amount == 0) revert InvalidAmount();

        // Transfer USDC from user
        require(usdc.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");

        // Add to existing position or create new
        Position storage pos = positions[marketId][msg.sender];
        if (pos.amount > 0 && pos.direction != direction) {
            // User already has opposite position, not allowed
            revert("Cannot bet both directions");
        }
        pos.amount += amount;
        pos.direction = direction;

        if (direction == Direction.Up) {
            m.totalUpPool += amount;
        } else {
            m.totalDownPool += amount;
        }

        emit PositionOpened(marketId, msg.sender, direction, amount);
    }

    /// @notice Request settlement after market expires. Emits event for CRE.
    function requestSettlement(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketDoesNotExist();
        if (m.settled) revert MarketAlreadySettled();
        if (block.timestamp < m.endTime) revert MarketNotExpired();

        emit SettlementRequested(marketId, m.asset, m.strikePrice, m.endTime);
    }

    /// @notice Settle a market with the final price. Called by operator (or CRE).
    function settleMarket(
        uint256 marketId,
        uint256 finalPrice
    ) external onlyOperator {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketDoesNotExist();
        if (m.settled) revert MarketAlreadySettled();

        m.settled = true;
        m.finalPrice = finalPrice;
        m.outcome = finalPrice >= m.strikePrice ? Direction.Up : Direction.Down;

        emit MarketSettled(marketId, finalPrice, m.outcome);
    }

    /// @notice Claim winnings from a settled market.
    function claim(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketDoesNotExist();
        if (!m.settled) revert MarketNotSettled();

        Position storage pos = positions[marketId][msg.sender];
        if (pos.amount == 0) revert NothingToClaim();
        if (pos.claimed) revert AlreadyClaimed();
        if (pos.direction != m.outcome) revert NothingToClaim();

        pos.claimed = true;

        uint256 totalPool = m.totalUpPool + m.totalDownPool;
        uint256 winningPool = m.outcome == Direction.Up ? m.totalUpPool : m.totalDownPool;
        uint256 payout = (pos.amount * totalPool) / winningPool;

        require(usdc.transfer(msg.sender, payout), "USDC transfer failed");

        emit WinningsClaimed(marketId, msg.sender, payout);
    }

    // View functions

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    function getPosition(uint256 marketId, address user) external view returns (Position memory) {
        return positions[marketId][user];
    }

    function getActiveMarkets(uint256 fromId, uint256 count) external view returns (Market[] memory) {
        Market[] memory result = new Market[](count);
        for (uint256 i = 0; i < count && fromId + i < nextMarketId; i++) {
            result[i] = markets[fromId + i];
        }
        return result;
    }
}
