// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV2PairMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/**
 * @title GapHunterExecutor
 * @notice Destination-chain half of GapHunter (deployed on Base Sepolia).
 *         Receives callbacks from GapHunterReactive and atomically arbitrages
 *         two Uniswap V2 pools for the same pair: buy token0 with token1 on
 *         the cheap pool, sell token0 for token1 on the expensive pool, keep
 *         the difference. The executor trades its own inventory, funded by
 *         the owner; profits accumulate in token1 and are owner-withdrawable.
 * @dev Both swap legs are priced from live reserves inside this call and the
 *      whole callback reverts unless the round trip is profitable, so a stale
 *      signal can never lose money (beyond the callback's own gas, which the
 *      Reactive callback proxy pays).
 */
contract GapHunterExecutor is AbstractCallback {
    /// @notice Contract deployer.
    address public immutable owner;
    /// @notice Minimum seconds between executed arbitrages (timestamp-based,
    ///         per the Base Sepolia guidance to not count blocks there).
    uint256 public cooldownSeconds = 60;
    /// @notice Last accepted callback nonce (replay protection).
    uint256 public lastNonce;
    /// @notice Timestamp of the last executed arbitrage.
    uint256 public lastExecAt;
    /// @notice Cumulative arbitrage profit, denominated in token1.
    uint256 public totalProfit;
    /// @notice How many arbitrages have executed.
    uint256 public arbsExecuted;

    event ArbExecuted(
        uint256 indexed arbNonce, address poolBuy, address poolSell, uint256 amountIn, uint256 amountOut, uint256 profit
    );
    event CooldownSet(uint256 cooldownSeconds);
    event Rescued(address token, address to, uint256 amount);

    constructor(IPayable callbackProxy_, address reactiveContract_) payable AbstractCallback(callbackProxy_, reactiveContract_) {
        owner = msg.sender;
    }

    function setCooldown(uint256 cooldownSeconds_) external {
        require(msg.sender == owner, "not owner");
        cooldownSeconds = cooldownSeconds_;
        emit CooldownSet(cooldownSeconds_);
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    /**
     * @notice Callback entry point. The callback proxy overwrites the first
     *         argument with the reactive contract's address.
     * @param reactive_      GapHunterReactive's address (injected by the proxy).
     * @param arbNonce_      Signal nonce from the reactive contract.
     * @param poolBuy_       Pool where token0 is cheap.
     * @param poolSell_      Pool where token0 is expensive.
     * @param amountIn_      token1 to spend on the buy leg.
     */
    function executeArb(address reactive_, uint256 arbNonce_, address poolBuy_, address poolSell_, uint256 amountIn_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        require(arbNonce_ > lastNonce, "stale nonce");
        require(block.timestamp >= lastExecAt + cooldownSeconds, "cooldown");
        lastNonce = arbNonce_;
        lastExecAt = block.timestamp;

        IUniswapV2PairMinimal buyPair = IUniswapV2PairMinimal(poolBuy_);
        IUniswapV2PairMinimal sellPair = IUniswapV2PairMinimal(poolSell_);
        address token0 = buyPair.token0();
        address token1 = buyPair.token1();
        require(sellPair.token0() == token0 && sellPair.token1() == token1, "pair mismatch");

        (uint112 bR0, uint112 bR1,) = buyPair.getReserves();
        (uint112 sR0, uint112 sR1,) = sellPair.getReserves();

        // Price both legs from live reserves; revert unless profitable.
        uint256 bought = _amountOut(amountIn_, bR1, bR0); // token0 out of the buy pool
        uint256 proceeds = _amountOut(bought, sR0, sR1); // token1 out of the sell pool
        require(proceeds > amountIn_, "unprofitable");

        require(IERC20Minimal(token1).balanceOf(address(this)) >= amountIn_, "no inventory");

        // Leg 1: token1 -> token0 on the cheap pool.
        require(IERC20Minimal(token1).transfer(poolBuy_, amountIn_), "fund buy failed");
        buyPair.swap(bought, 0, address(this), new bytes(0));

        // Leg 2: token0 -> token1 on the expensive pool.
        require(IERC20Minimal(token0).transfer(poolSell_, bought), "fund sell failed");
        sellPair.swap(0, proceeds, address(this), new bytes(0));

        uint256 profit = proceeds - amountIn_;
        totalProfit += profit;
        arbsExecuted++;
        emit ArbExecuted(arbNonce_, poolBuy_, poolSell_, amountIn_, proceeds, profit);
    }

    /// @notice Owner rescue for any token held by the executor (inventory/profits).
    function rescue(address token_, address to_, uint256 amount_) external {
        require(msg.sender == owner, "not owner");
        require(IERC20Minimal(token_).transfer(to_, amount_), "rescue failed");
        emit Rescued(token_, to_, amount_);
    }

    /// @notice Owner withdrawal of native funds (used to pay callback debt).
    function withdrawNative(address payable to_, uint256 amount_) external {
        require(msg.sender == owner, "not owner");
        (bool ok,) = to_.call{ value: amount_ }("");
        require(ok, "transfer failed");
    }
}
