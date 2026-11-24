// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { GapHunterReactive } from "../src/GapHunterReactive.sol";
import { GapHunterExecutor } from "../src/GapHunterExecutor.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockSystemRecorder } from "./MockSystemRecorder.sol";
import { MockV2Factory } from "./MockV2.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPairFull {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/**
 * @notice Full local simulation of the GapHunter loop:
 *         two real Uniswap V2 pools (two factories = two venues) are seeded,
 *         a whale swap opens a price gap, the reactive contract is fed the
 *         resulting Sync log exactly as the Reactive Network would deliver
 *         it, its callback request is captured from the (etched) system
 *         contract, and the callback is then delivered to the executor,
 *         which must close the gap at a profit.
 */
contract GapHunterTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address payable internal constant PROXY = payable(address(0xCA11));
    uint256 internal constant BASE_SEPOLIA = 84532;

    MockSystemRecorder internal recorder;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal pairA; // venue A
    address internal pairB; // venue B
    GapHunterReactive internal rsc;
    GapHunterExecutor internal executor;

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return (withFee * reserveOut) / (reserveIn * 1000 + withFee);
    }

    function setUp() public {
        // Etch the recording system contract onto the real system address.
        recorder = new MockSystemRecorder();
        vm.etch(SYSTEM_ADDR, address(recorder).code);

        tokenA = new MockERC20("Gap Token A", "GTA", 18);
        tokenB = new MockERC20("Gap Token B", "GTB", 18);

        address factoryA = address(new MockV2Factory());
        address factoryB = address(new MockV2Factory());
        pairA = IFactory(factoryA).createPair(address(tokenA), address(tokenB));
        pairB = IFactory(factoryB).createPair(address(tokenA), address(tokenB));

        // Seed both pools at price 1.0 (1,000,000 / 1,000,000 in pair order).
        _seed(pairA, 1_000_000 ether, 1_000_000 ether);
        _seed(pairB, 1_000_000 ether, 1_000_000 ether);

        rsc = new GapHunterReactive(BASE_SEPOLIA, pairA, pairB);
        executor = new GapHunterExecutor(IPayable(PROXY), address(rsc));
        rsc.setExecutor(address(executor));

        // Executor inventory: token1 of the pair ordering.
        address token1 = IPairFull(pairA).token1();
        MockERC20(token1).mint(address(executor), 500_000 ether);
        executor.setCooldown(0);
    }

    function _seed(address pair, uint256 amount0Desired, uint256 amount1Desired) internal {
        address t0 = IPairFull(pair).token0();
        address t1 = IPairFull(pair).token1();
        // Mint in token identity, transfer in pair order.
        MockERC20(t0).mint(address(this), amount0Desired);
        MockERC20(t1).mint(address(this), amount1Desired);
        MockERC20(t0).transfer(pair, amount0Desired);
        MockERC20(t1).transfer(pair, amount1Desired);
        IPairFull(pair).mint(address(this));
    }

    function _sliceFrom(bytes memory b, uint256 start) internal pure returns (bytes memory) {
        bytes memory out = new bytes(b.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return out;
    }

    function _syncLog(address pair) internal view returns (IReactive.LogRecord memory) {
        (uint112 r0, uint112 r1,) = IPairFull(pair).getReserves();
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: pair,
            topic0: 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1,
            topic1: 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad,
            topic2: 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad,
            topic3: 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad,
            data: abi.encode(r0, r1),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 424242,
            logIndex: 0
        });
    }

    function test_subscriptions_registered() public view {
        assertEq(MockSystemRecorder(SYSTEM_ADDR).subscribeCalls(), 2, "two pool subscriptions");
    }

    function test_react_rejects_non_system_caller() public {
        IReactive.LogRecord memory log = _syncLog(pairA);
        vm.expectRevert();
        rsc.react(log);
    }

    function test_full_loop_arbitrage() public {
        address t0 = IPairFull(pairB).token0();
        address t1 = IPairFull(pairB).token1();

        // 1) Whale buys token0 on venue B with 100k token1 -> token0 expensive on B.
        (uint112 bR0, uint112 bR1,) = IPairFull(pairB).getReserves();
        uint256 whaleIn = 100_000 ether;
        uint256 whaleOut = _amountOut(whaleIn, bR1, bR0);
        MockERC20(t1).mint(address(this), whaleIn);
        MockERC20(t1).transfer(pairB, whaleIn);
        IPairFull(pairB).swap(whaleOut, 0, address(this), new bytes(0));

        // 2) Feed both pools' Sync logs to the reactive contract, as the
        //    network would (venue A's unchanged price first, then B's new one).
        vm.roll(1000); // Lasna blocks tick ~1s; clear the RSC's block cooldown window
        IReactive.LogRecord memory logA = _syncLog(pairA);
        vm.prank(SYSTEM_ADDR);
        rsc.react(logA);
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0, "no gap yet from one pool alone");

        IReactive.LogRecord memory logB = _syncLog(pairB);
        vm.prank(SYSTEM_ADDR);
        rsc.react(logB);
        assertEq(rsc.arbsSignalled(), 1, "gap must signal exactly one arbitrage");

        // 3) Inspect the captured callback request.
        MockSystemRecorder sys = MockSystemRecorder(SYSTEM_ADDR);
        assertEq(sys.callbackCalls(), 1);
        assertEq(sys.lastChainId(), BASE_SEPOLIA);
        assertEq(sys.lastRecipient(), address(executor));
        (address injected, uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) =
            abi.decode(_sliceFrom(sys.lastPayload(), 4), (address, uint256, address, address, uint256));
        assertEq(injected, address(0), "proxy placeholder");
        assertEq(arbNonce, 1);
        assertEq(poolBuy, pairA, "buy where token0 is cheap (venue A)");
        assertEq(poolSell, pairB, "sell where token0 is expensive (venue B)");
        assertGt(amountIn, 0);

        // 4) Deliver the callback through the proxy, as Reactive would.
        uint256 execT1Before = MockERC20(t1).balanceOf(address(executor));
        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);
        uint256 execT1After = MockERC20(t1).balanceOf(address(executor));

        assertGt(execT1After, execT1Before, "executor must profit in token1");
        assertEq(executor.arbsExecuted(), 1);
        assertEq(executor.totalProfit(), execT1After - execT1Before);
        assertEq(t0, IPairFull(pairA).token0()); // ordering sanity
    }

    function test_no_signal_without_gap() public {
        IReactive.LogRecord memory logA = _syncLog(pairA);
        vm.prank(SYSTEM_ADDR);
        rsc.react(logA);
        IReactive.LogRecord memory logB = _syncLog(pairB);
        vm.prank(SYSTEM_ADDR);
        rsc.react(logB);
        assertEq(rsc.arbsSignalled(), 0, "equal prices must not signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);
    }

    function test_executor_rejects_wrong_sender() public {
        vm.prank(PROXY);
        vm.expectRevert();
        executor.executeArb(address(0xBEEF), 1, pairA, pairB, 1 ether);
    }
}
