// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/**
 * @title GapHunterReactive
 * @notice Reactive Smart Contract (deployed on Reactive Lasna) that watches two
 *         Uniswap V2 pools for the same token pair on an origin chain. Whenever
 *         the pools' prices diverge beyond a fee-adjusted threshold, it requests
 *         a callback that makes GapHunterExecutor arbitrage the gap away.
 * @dev The full loop is on-chain: origin Sync event -> react() here ->
 *      requestCallbackV_1_0 -> callback proxy -> GapHunterExecutor.executeArb.
 *      No bot, keeper, or server is involved anywhere in the loop.
 */
contract GapHunterReactive is AbstractReactive {
    /// @notice topic0 of Uniswap V2's Sync(uint112,uint112) event.
    uint256 public constant SYNC_TOPIC_0 =
        0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;

    /// @notice Gas reserved for the arbitrage callback on the destination chain.
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice Chain the watched pools live on (Base Sepolia = 84532).
    uint256 public immutable originChainId;
    /// @notice The two watched pools (same token0/token1, different venues).
    address public immutable poolA;
    address public immutable poolB;
    /// @notice Contract deployer, allowed to retune parameters.
    address public immutable owner;

    /// @notice Destination contract that executes the arbitrage (set after deploy).
    address public executor;
    /// @notice Minimum price divergence, in basis points of the cheaper price,
    ///         before an arbitrage is signalled (must clear 2x 0.3% swap fees).
    uint256 public thresholdBps = 150;
    /// @notice Trade size as basis points of the buy pool's token1 reserves.
    uint256 public tradeFractionBps = 200;
    /// @notice Minimum Lasna blocks between two signalled arbitrages.
    uint256 public cooldownBlocks = 20;
    /// @notice Minimum estimated profit, in basis points of the amount spent.
    uint256 public minProfitBps = 30;

    // Latest reserves seen for each pool (token0, token1).
    uint256 public reserveA0;
    uint256 public reserveA1;
    uint256 public reserveB0;
    uint256 public reserveB1;
    /// @notice Lasna block of the last signalled arbitrage.
    uint256 public lastArbBlock;
    /// @notice Monotonic nonce handed to the executor (replay protection).
    uint256 public nonce;
    /// @notice How many price updates this contract has processed.
    uint256 public pricesSeen;
    /// @notice How many arbitrages have been signalled.
    uint256 public arbsSignalled;

    event PriceSeen(address indexed pool, uint256 reserve0, uint256 reserve1);
    event ArbSignalled(
        uint256 indexed arbNonce,
        address poolBuy,
        address poolSell,
        uint256 amountIn,
        uint256 spreadBps,
        uint256 estimatedProfit
    );
    event ExecutorSet(address executor);
    event ParamsSet(uint256 thresholdBps, uint256 tradeFractionBps, uint256 cooldownBlocks, uint256 minProfitBps);

    constructor(uint256 originChainId_, address poolA_, address poolB_) payable {
        originChainId = originChainId_;
        poolA = poolA_;
        poolB = poolB_;
        owner = msg.sender;

        SYSTEM.subscribe(originChainId_, poolA_, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, poolB_, SYNC_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setExecutor(address executor_) external {
        require(msg.sender == owner, "not owner");
        executor = executor_;
        emit ExecutorSet(executor_);
    }

    function setParams(uint256 thresholdBps_, uint256 tradeFractionBps_, uint256 cooldownBlocks_, uint256 minProfitBps_)
        external
    {
        require(msg.sender == owner, "not owner");
        thresholdBps = thresholdBps_;
        tradeFractionBps = tradeFractionBps_;
        cooldownBlocks = cooldownBlocks_;
        minProfitBps = minProfitBps_;
        emit ParamsSet(thresholdBps_, tradeFractionBps_, cooldownBlocks_, minProfitBps_);
    }

    /// @notice Uniswap V2 getAmountOut with the 0.3% fee.
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.topic0 != SYNC_TOPIC_0) return;
        (uint112 newReserve0, uint112 newReserve1) = abi.decode(log_.data, (uint112, uint112));

        if (log_.contractAddress == poolA) {
            reserveA0 = newReserve0;
            reserveA1 = newReserve1;
        } else if (log_.contractAddress == poolB) {
            reserveB0 = newReserve0;
            reserveB1 = newReserve1;
        } else {
            return;
        }
        pricesSeen++;
        emit PriceSeen(log_.contractAddress, newReserve0, newReserve1);

        if (executor == address(0)) return;
        if (reserveA0 == 0 || reserveB0 == 0) return; // need both pools priced
        if (block.number < lastArbBlock + cooldownBlocks) return;

        // Spot prices of token0, denominated in token1, scaled by 1e18.
        uint256 priceA = (reserveA1 * 1e18) / reserveA0;
        uint256 priceB = (reserveB1 * 1e18) / reserveB0;
        if (priceA == priceB) return;

        address poolBuy;
        address poolSell;
        uint256 buyReserve1;
        uint256 buyReserve0;
        uint256 sellReserve0;
        uint256 sellReserve1;
        uint256 spreadBps;

        if (priceA > priceB) {
            // token0 is cheap on B, expensive on A: buy on B, sell on A.
            spreadBps = ((priceA - priceB) * 10_000) / priceB;
            poolBuy = poolB;
            poolSell = poolA;
            buyReserve0 = reserveB0;
            buyReserve1 = reserveB1;
            sellReserve0 = reserveA0;
            sellReserve1 = reserveA1;
        } else {
            spreadBps = ((priceB - priceA) * 10_000) / priceA;
            poolBuy = poolA;
            poolSell = poolB;
            buyReserve0 = reserveA0;
            buyReserve1 = reserveA1;
            sellReserve0 = reserveB0;
            sellReserve1 = reserveB1;
        }
        if (spreadBps < thresholdBps) return;

        // Size the trade off the buy pool's token1 depth, then estimate the
        // round trip against the stored reserves before spending a callback.
        uint256 amountIn = (buyReserve1 * tradeFractionBps) / 10_000;
        if (amountIn == 0) return;
        uint256 bought = _amountOut(amountIn, buyReserve1, buyReserve0); // token0 received
        uint256 proceeds = _amountOut(bought, sellReserve0, sellReserve1); // token1 received back
        if (proceeds <= amountIn) return;
        uint256 estimatedProfit = proceeds - amountIn;
        if (estimatedProfit * 10_000 < amountIn * minProfitBps) return;

        lastArbBlock = block.number;
        uint256 arbNonce = ++nonce;
        arbsSignalled++;

        bytes memory payload = abi.encodeWithSignature(
            "executeArb(address,uint256,address,address,uint256)", address(0), arbNonce, poolBuy, poolSell, amountIn
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId, recipient: executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        );
        emit ArbSignalled(arbNonce, poolBuy, poolSell, amountIn, spreadBps, estimatedProfit);
    }

    /// @notice Rescue native funds stuck in the contract.
    function withdraw(address payable to_, uint256 amount_) external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = to_.call{ value: amount_ }("");
        require(ok, "transfer failed");
    }
}
