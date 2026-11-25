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

interface IFactory2 {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPairFull2 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/**
 * @notice Guard-rail suite for GapHunter: the conditions under which the
 *         system must NOT trade are as important as the happy path in
 *         GapHunter.t.sol. These tests pin down the spread threshold, the
 *         block cooldown, the trade sizing, the minimum-profit gate, the
 *         executor's live-reprice / replay / timestamp-cooldown guards,
 *         and the owner-only surface of both contracts.
 */
contract GapHunterGuardsTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address payable internal constant PROXY = payable(address(0xCA11));
    address internal constant ATTACKER = address(0xA77AC);
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant SYNC_TOPIC = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 internal constant IGNORE_TOPIC = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal pairA;
    address internal pairB;
    GapHunterReactive internal rsc;
    GapHunterExecutor internal executor;

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return (withFee * reserveOut) / (reserveIn * 1000 + withFee);
    }

    function setUp() public {
        MockSystemRecorder recorder = new MockSystemRecorder();
        vm.etch(SYSTEM_ADDR, address(recorder).code);

        tokenA = new MockERC20("Gap Token A", "GTA", 18);
        tokenB = new MockERC20("Gap Token B", "GTB", 18);

        address factoryA = address(new MockV2Factory());
        address factoryB = address(new MockV2Factory());
        pairA = IFactory2(factoryA).createPair(address(tokenA), address(tokenB));
        pairB = IFactory2(factoryB).createPair(address(tokenA), address(tokenB));

        _seed(pairA, 1_000_000 ether, 1_000_000 ether);
        _seed(pairB, 1_000_000 ether, 1_000_000 ether);

        rsc = new GapHunterReactive(BASE_SEPOLIA, pairA, pairB);
        executor = new GapHunterExecutor(IPayable(PROXY), address(rsc));
        rsc.setExecutor(address(executor));

        address token1 = IPairFull2(pairA).token1();
        MockERC20(token1).mint(address(executor), 500_000 ether);
        executor.setCooldown(0);
    }

    function _seed(address pair, uint256 amount0, uint256 amount1) internal {
        address t0 = IPairFull2(pair).token0();
        address t1 = IPairFull2(pair).token1();
        MockERC20(t0).mint(address(this), amount0);
        MockERC20(t1).mint(address(this), amount1);
        MockERC20(t0).transfer(pair, amount0);
        MockERC20(t1).transfer(pair, amount1);
        IPairFull2(pair).mint(address(this));
    }

    function _syncLog(address pair) internal view returns (IReactive.LogRecord memory) {
        (uint112 r0, uint112 r1,) = IPairFull2(pair).getReserves();
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: pair,
            topic0: SYNC_TOPIC,
            topic1: IGNORE_TOPIC,
            topic2: IGNORE_TOPIC,
            topic3: IGNORE_TOPIC,
            data: abi.encode(r0, r1),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 424242,
            logIndex: 0
        });
    }

    function _feed(address pair) internal {
        IReactive.LogRecord memory log = _syncLog(pair);
        vm.prank(SYSTEM_ADDR);
        rsc.react(log);
    }

    /// @dev Whale spends token1 to buy token0 on `pair` (token0 gets expensive there).
    function _whaleBuyToken0(address pair, uint256 amount1In) internal {
        address t0 = IPairFull2(pair).token0();
        address t1 = IPairFull2(pair).token1();
        (uint112 r0, uint112 r1,) = IPairFull2(pair).getReserves();
        uint256 out = _amountOut(amount1In, r1, r0);
        MockERC20(t1).mint(address(this), amount1In);
        MockERC20(t1).transfer(pair, amount1In);
        IPairFull2(pair).swap(out, 0, address(this), new bytes(0));
        assertEq(IPairFull2(pair).token0(), t0); // silence unused-var style warnings
    }

    /// @dev Whale sells token0 into `pair` (token0 gets cheap there).
    function _whaleSellToken0(address pair, uint256 amount0In) internal {
        address t0 = IPairFull2(pair).token0();
        address t1 = IPairFull2(pair).token1();
        (uint112 r0, uint112 r1,) = IPairFull2(pair).getReserves();
        uint256 out = _amountOut(amount0In, r0, r1);
        MockERC20(t0).mint(address(this), amount0In);
        MockERC20(t0).transfer(pair, amount0In);
        IPairFull2(pair).swap(0, out, address(this), new bytes(0));
        assertEq(IPairFull2(pair).token1(), t1);
    }

    function _sliceFrom(bytes memory b, uint256 start) internal pure returns (bytes memory) {
        bytes memory out = new bytes(b.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return out;
    }

    /// @dev Decode the most recent captured callback payload.
    function _lastSignal()
        internal
        view
        returns (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn)
    {
        MockSystemRecorder sys = MockSystemRecorder(SYSTEM_ADDR);
        (address injected, uint256 n, address b, address s, uint256 a) =
            abi.decode(_sliceFrom(sys.lastPayload(), 4), (address, uint256, address, address, uint256));
        assertEq(injected, address(0), "proxy placeholder");
        return (n, b, s, a);
    }

    // ------------------------------------------------------------------
    // Reactive-side gates
    // ------------------------------------------------------------------

    /// A ~20 bps spread (1,000 GTB whale) is real but below the 150 bps
    /// fee-adjusted threshold: the RSC must see both prices and stay silent.
    function test_no_signal_below_threshold() public {
        vm.roll(1000);
        _whaleBuyToken0(pairB, 1_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.pricesSeen(), 2, "both Sync events processed");
        assertEq(rsc.arbsSignalled(), 0, "sub-threshold spread must not signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0, "no callback may be requested");
    }

    /// After a signal, the 20-block Lasna cooldown suppresses further
    /// signals even while the gap persists; once it lapses the still-open
    /// gap signals again with the next nonce.
    function test_cooldown_blocks_second_signal() public {
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        assertEq(rsc.lastArbBlock(), 1000);

        vm.roll(1005); // inside the 20-block cooldown
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1, "cooldown must suppress the second signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 1);

        vm.roll(1021); // cooldown lapsed, gap still open (nothing executed)
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 2, "gap must signal again after cooldown");
        (uint256 arbNonce,,,) = _lastSignal();
        assertEq(arbNonce, 2, "nonce increments per signal");
    }

    /// Trade size is tradeFractionBps of the buy pool's token1 reserves:
    /// at 500 bps over a 1,000,000 GTB pool the signal must carry exactly
    /// 50,000 GTB.
    function test_trade_size_follows_fraction() public {
        rsc.setParams(150, 500, 20, 30);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (, address poolBuy,, uint256 amountIn) = _lastSignal();
        assertEq(poolBuy, pairA, "token0 is cheap on venue A");
        assertEq(amountIn, 50_000 ether, "5% of the buy pool's token1 reserves");
    }

    /// A wide (~21%) spread clears the threshold, but with the minimum
    /// profit gate raised to 50% the estimated ~16% round trip must be
    /// rejected; restoring the default 30 bps gate lets the same gap signal.
    function test_min_profit_gate_rejects_marginal_gap() public {
        rsc.setParams(150, 200, 20, 5000);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 0, "estimated profit below the gate must not signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);

        rsc.setParams(150, 200, 20, 30);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1, "same gap signals once the gate is back to default");
    }

    /// Direction selection, other branch: token0 dumped on venue B makes it
    /// cheap there, so the signal must buy on B and sell on A, and the
    /// executor must close it at a profit.
    function test_signal_direction_flips() public {
        vm.roll(1000);
        _whaleSellToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();
        assertEq(poolBuy, pairB, "buy where token0 is cheap (venue B)");
        assertEq(poolSell, pairA, "sell where token0 is expensive (venue A)");

        address t1 = IPairFull2(pairA).token1();
        uint256 before = MockERC20(t1).balanceOf(address(executor));
        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);
        assertGt(MockERC20(t1).balanceOf(address(executor)), before, "flipped arb must profit");
        assertEq(executor.arbsExecuted(), 1);
    }

    /// Logs that are not Sync events, and Sync events from pools the RSC
    /// does not watch, must be ignored entirely.
    function test_react_ignores_unrelated_logs() public {
        IReactive.LogRecord memory wrongTopic = _syncLog(pairA);
        wrongTopic.topic0 = 0xdeadbeef;
        vm.prank(SYSTEM_ADDR);
        rsc.react(wrongTopic);
        assertEq(rsc.pricesSeen(), 0, "non-Sync topic ignored");

        IReactive.LogRecord memory stranger = _syncLog(pairA);
        stranger.contractAddress = address(0x1234);
        vm.prank(SYSTEM_ADDR);
        rsc.react(stranger);
        assertEq(rsc.pricesSeen(), 0, "unwatched pool ignored");
        assertEq(rsc.arbsSignalled(), 0);
    }

    /// Every owner-only function on the reactive contract rejects strangers,
    /// and the owner can retune parameters.
    function test_reactive_owner_only_guards() public {
        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        rsc.setExecutor(ATTACKER);

        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        rsc.setParams(1, 1, 1, 1);

        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        rsc.withdraw(payable(ATTACKER), 1);

        rsc.setParams(200, 300, 25, 40);
        assertEq(rsc.thresholdBps(), 200);
        assertEq(rsc.tradeFractionBps(), 300);
        assertEq(rsc.cooldownBlocks(), 25);
        assertEq(rsc.minProfitBps(), 40);
    }

    // ------------------------------------------------------------------
    // Executor-side guards
    // ------------------------------------------------------------------

    /// The executor re-prices from live reserves inside the callback: with
    /// the pools at equal prices the same callback that would have been
    /// profitable mid-gap reverts as unprofitable.
    function test_executor_reverts_unprofitable_callback() public {
        vm.prank(PROXY);
        vm.expectRevert("unprofitable");
        executor.executeArb(address(rsc), 1, pairA, pairB, 20_000 ether);
        assertEq(executor.arbsExecuted(), 0);
        assertEq(executor.lastNonce(), 0, "reverted callback must not consume the nonce");
    }

    /// A delivered callback cannot be replayed: the same nonce reverts,
    /// and so does any older nonce.
    function test_executor_rejects_replayed_nonce() public {
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();

        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);
        assertEq(executor.arbsExecuted(), 1);

        vm.prank(PROXY);
        vm.expectRevert("stale nonce");
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);

        vm.prank(PROXY);
        vm.expectRevert("stale nonce");
        executor.executeArb(address(rsc), arbNonce - 1, poolBuy, poolSell, amountIn);
        assertEq(executor.arbsExecuted(), 1, "replays must not execute");
    }

    /// The executor's timestamp cooldown (Base Sepolia counts time, not
    /// blocks) blocks a second execution inside the window and allows it
    /// once the window has passed, while the gap is still open.
    function test_executor_timestamp_cooldown() public {
        executor.setCooldown(3600);
        vm.warp(1_700_000_000);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        (, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();

        vm.prank(PROXY);
        executor.executeArb(address(rsc), 1, poolBuy, poolSell, amountIn);
        assertEq(executor.arbsExecuted(), 1);

        vm.warp(1_700_000_000 + 10);
        vm.prank(PROXY);
        vm.expectRevert("cooldown");
        executor.executeArb(address(rsc), 2, poolBuy, poolSell, amountIn);

        vm.warp(1_700_000_000 + 3600);
        vm.prank(PROXY);
        executor.executeArb(address(rsc), 2, poolBuy, poolSell, amountIn);
        assertEq(executor.arbsExecuted(), 2, "second arb executes after the cooldown");
        assertGt(executor.totalProfit(), 0);
    }

    /// A callback naming pools for different token pairs is rejected
    /// before any funds move.
    function test_executor_rejects_pair_mismatch() public {
        MockERC20 tokenC = new MockERC20("Gap Token C", "GTC", 18);
        address factoryC = address(new MockV2Factory());
        address pairC = IFactory2(factoryC).createPair(address(tokenA), address(tokenC));

        vm.prank(PROXY);
        vm.expectRevert("pair mismatch");
        executor.executeArb(address(rsc), 1, pairA, pairC, 1 ether);
        assertEq(executor.arbsExecuted(), 0);
    }

    /// Every owner-only function on the executor rejects strangers.
    function test_executor_owner_only_guards() public {
        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        executor.setCooldown(1);

        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        executor.rescue(address(tokenB), ATTACKER, 1);

        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        executor.withdrawNative(payable(ATTACKER), 1);

        executor.setCooldown(120);
        assertEq(executor.cooldownSeconds(), 120, "owner can retune the cooldown");
    }
}
