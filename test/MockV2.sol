// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Faithful local re-implementation of the Uniswap V2 pair/factory
 *         semantics used by the GapHunter tests: sorted token order,
 *         constant-product reserves, 0.3% fee enforced by the invariant
 *         check on swap, and the Sync event the reactive contract watches.
 * @dev The live deployment uses the canonical Uniswap v2-core bytecode
 *      (compiled with solc 0.5.16); this mock exists so the full loop can be
 *      tested inside a single Foundry compilation. Behavioural parity is
 *      what matters here: reserves, fee math, and event shape are identical.
 */
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    event Sync(uint112 reserve0, uint112 reserve1);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to
    );

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function mint(address) external returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        liquidity = amount0 + amount1; // test-only LP accounting; value is irrelevant here
        emit Mint(msg.sender, amount0, amount1);
        emit Sync(reserve0, reserve1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "insufficient output");
        if (amount0Out > 0) require(IERC20(token0).transfer(to, amount0Out), "t0 out failed");
        if (amount1Out > 0) require(IERC20(token1).transfer(to, amount1Out), "t1 out failed");

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "insufficient input");

        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(balance0Adjusted * balance1Adjusted >= uint256(reserve0) * reserve1 * 1_000_000, "K invariant");

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
        emit Sync(reserve0, reserve1);
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockV2Pair(t0, t1));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}
