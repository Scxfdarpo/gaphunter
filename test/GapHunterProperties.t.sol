// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { GapHunterReactive } from "../src/GapHunterReactive.sol";
import { GapHunterExecutor } from "../src/GapHunterExecutor.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { MockSystemRecorder } from "./MockSystemRecorder.sol";
import { MockV2Factory } from "./MockV2.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

interface IPropFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPropPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/**
 * @notice End-to-end and cross-contract properties: the full
 *         whale -> Sync -> signal -> callback -> execution loop under
 *         fuzzed market conditions, the exact contents of the events both
 *         contracts emit (recomputed independently from live reserves),
 *         the spread-narrowing effect an execution must have, repeated
 *         gap/execution cycles, and the owner-only value-moving surface
 *         (rescue / withdraw) of the executor.
 */
contract GapHunterPropertiesTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address payable internal constant PROXY = payable(address(0xCA11));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant SYNC_TOPIC = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 internal constant IGNORE_TOPIC = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant POOL_SIZE = 1_000_000 ether;
    uint256 internal constant INVENTORY = 500_000 ether;

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
        pairA = IPropFactory(factoryA).createPair(address(tokenA), address(tokenB));
        pairB = IPropFactory(factoryB).createPair(address(tokenA), address(tokenB));

        _seed(pairA, POOL_SIZE, POOL_SIZE);
        _seed(pairB, POOL_SIZE, POOL_SIZE);

        rsc = new GapHunterReactive(BASE_SEPOLIA, pairA, pairB);
        executor = new GapHunterExecutor(IPayable(PROXY), address(rsc));
        rsc.setExecutor(address(executor));

        address token1 = IPropPair(pairA).token1();
        MockERC20(token1).mint(address(executor), INVENTORY);
        executor.setCooldown(0);
    }

    function _seed(address pair, uint256 amount0, uint256 amount1) internal {
        address t0 = IPropPair(pair).token0();
        address t1 = IPropPair(pair).token1();
        MockERC20(t0).mint(address(this), amount0);
        MockERC20(t1).mint(address(this), amount1);
        MockERC20(t0).transfer(pair, amount0);
        MockERC20(t1).transfer(pair, amount1);
        IPropPair(pair).mint(address(this));
    }

    function _syncLog(address pair) internal view returns (IReactive.LogRecord memory) {
        (uint112 r0, uint112 r1,) = IPropPair(pair).getReserves();
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

    function _whaleBuyToken0(address pair, uint256 amount1In) internal {
        address t1 = IPropPair(pair).token1();
        (uint112 r0, uint112 r1,) = IPropPair(pair).getReserves();
        uint256 out = _amountOut(amount1In, r1, r0);
        MockERC20(t1).mint(address(this), amount1In);
        MockERC20(t1).transfer(pair, amount1In);
        IPropPair(pair).swap(out, 0, address(this), new bytes(0));
    }

    function _whaleSellToken0(address pair, uint256 amount0In) internal {
        address t0 = IPropPair(pair).token0();
        (uint112 r0, uint112 r1,) = IPropPair(pair).getReserves();
        uint256 out = _amountOut(amount0In, r0, r1);
        MockERC20(t0).mint(address(this), amount0In);
        MockERC20(t0).transfer(pair, amount0In);
        IPropPair(pair).swap(0, out, address(this), new bytes(0));
    }

    function _sliceFrom(bytes memory b, uint256 start) internal pure returns (bytes memory) {
        bytes memory out = new bytes(b.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return out;
    }

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

    function _token1() internal view returns (MockERC20) {
        return MockERC20(IPropPair(pairA).token1());
    }

    function _token0() internal view returns (MockERC20) {
        return MockERC20(IPropPair(pairA).token0());
    }

    function _spreadBps() internal view returns (uint256) {
        (uint112 aR0, uint112 aR1,) = IPropPair(pairA).getReserves();
        (uint112 bR0, uint112 bR1,) = IPropPair(pairB).getReserves();
        uint256 priceA = (uint256(aR1) * 1e18) / aR0;
        uint256 priceB = (uint256(bR1) * 1e18) / bR0;
        if (priceA >= priceB) return ((priceA - priceB) * 10_000) / priceB;
        return ((priceB - priceA) * 10_000) / priceA;
    }

    // ------------------------------------------------------------------
    // Full loop under fuzz
    // ------------------------------------------------------------------

    /// The whole loop, fuzzed gap size: whale -> both Syncs -> exactly one
    /// signal -> proxy delivery -> the executor profits, its token1
    /// balance grows by exactly totalProfit, and it holds no token0.
    function testFuzz_full_loop_profits(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();

        uint256 before = _token1().balanceOf(address(executor));
        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);

        uint256 profit = _token1().balanceOf(address(executor)) - before;
        assertGt(profit, 0, "the loop must close the gap at a profit");
        assertEq(executor.totalProfit(), profit);
        assertEq(executor.arbsExecuted(), 1);
        assertEq(_token0().balanceOf(address(executor)), 0, "no token0 left behind");
    }

    /// The mirror loop: token0 dumped on venue B is bought there and sold
    /// on venue A, again at a profit, for any fuzzed dump size.
    function testFuzz_full_loop_mirror_profits(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleSellToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();
        assertEq(poolBuy, pairB);
        assertEq(poolSell, pairA);

        uint256 before = _token1().balanceOf(address(executor));
        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);
        assertGt(_token1().balanceOf(address(executor)), before, "mirror loop must profit");
        assertEq(executor.arbsExecuted(), 1);
    }

    /// An execution must narrow the very spread that triggered it: the
    /// post-trade spread (recomputed from live reserves) is strictly
    /// smaller than the pre-trade spread.
    function testFuzz_execution_narrows_the_spread(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        uint256 spreadBefore = _spreadBps();
        _feed(pairA);
        _feed(pairB);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();

        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);

        uint256 spreadAfter = _spreadBps();
        assertLt(spreadAfter, spreadBefore, "arbitrage must narrow the spread it traded on");
    }

    /// Repeated cycles: k consecutive whale gaps each signal and execute
    /// exactly once, nonces and execution counts advancing in lockstep.
    function testFuzz_repeated_cycles(uint256 cycles) public {
        cycles = bound(cycles, 2, 4);
        vm.roll(1000);
        for (uint256 i = 1; i <= cycles; i++) {
            _whaleBuyToken0(pairB, 100_000 ether);
            vm.roll(1000 + i * 25); // clear the RSC's 20-block cooldown
            _feed(pairA);
            _feed(pairB);
            (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();
            assertEq(arbNonce, i, "nonce advances by one per cycle");
            vm.prank(PROXY);
            executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);
            assertEq(executor.arbsExecuted(), i);
            assertEq(rsc.arbsSignalled(), i);
        }
        assertGt(executor.totalProfit(), 0);
        assertEq(_token1().balanceOf(address(executor)), INVENTORY + executor.totalProfit());
    }

    /// With the RSC cooldown set to zero, back-to-back Sync deliveries of
    /// a still-open gap signal back-to-back, nonces 1 then 2.
    function testFuzz_zero_cooldown_signals_back_to_back(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        rsc.setParams(150, 200, 0, 30);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 2);
        (uint256 arbNonce,,,) = _lastSignal();
        assertEq(arbNonce, 2);
    }

    /// With threshold and minimum-profit gates both at zero, any gap
    /// whose estimated round trip is profitable signals.
    function testFuzz_zero_gates_signal_any_profitable_gap(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        rsc.setParams(0, 200, 20, 0);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
    }

    /// Retuning the trade fraction between signals takes effect on the
    /// very next signal: each payload's size matches the fraction in
    /// force when it was emitted.
    function testFuzz_retune_fraction_applies_to_next_signal(uint256 f1, uint256 f2) public {
        f1 = bound(f1, 50, 500);
        f2 = bound(f2, 50, 500);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 200_000 ether);

        rsc.setParams(150, f1, 20, 30);
        _feed(pairA);
        _feed(pairB);
        (,, , uint256 amount1) = _lastSignal();
        assertEq(amount1, (POOL_SIZE * f1) / 10_000);

        rsc.setParams(150, f2, 20, 30);
        vm.roll(1021); // past the 20-block cooldown; gap still open
        _feed(pairB);
        (,, , uint256 amount2) = _lastSignal();
        assertEq(amount2, (POOL_SIZE * f2) / 10_000);
        assertEq(rsc.arbsSignalled(), 2);
    }

    // ------------------------------------------------------------------
    // Callback routing and event contents
    // ------------------------------------------------------------------

    /// Every signal's callback request is routed to the executor, on the
    /// origin chain, with the full 1,000,000 callback gas limit.
    function testFuzz_signal_callback_routing(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        MockSystemRecorder sys = MockSystemRecorder(SYSTEM_ADDR);
        assertEq(sys.callbackCalls(), 1);
        assertEq(sys.lastRecipient(), address(executor));
        assertEq(sys.lastChainId(), BASE_SEPOLIA);
        assertEq(sys.lastGasLimit(), 1_000_000);
    }

    /// The ArbSignalled event's fields equal an independent recomputation
    /// from live reserves: spread in bps of the cheaper price, trade size
    /// from the configured fraction, and the constant-product estimate.
    function testFuzz_signal_event_matches_recomputation(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);

        vm.recordLogs();
        _feed(pairB);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("ArbSignalled(uint256,address,address,uint256,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(rsc) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), 1, "first signal carries nonce 1");
                (address poolBuy, address poolSell, uint256 amountIn, uint256 spreadBps, uint256 estimatedProfit) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256, uint256));

                (uint112 aR0, uint112 aR1,) = IPropPair(pairA).getReserves();
                (uint112 bR0, uint112 bR1,) = IPropPair(pairB).getReserves();
                uint256 priceA = (uint256(aR1) * 1e18) / aR0;
                uint256 priceB = (uint256(bR1) * 1e18) / bR0;
                assertEq(spreadBps, ((priceB - priceA) * 10_000) / priceA, "event spread must match reserves");
                assertEq(poolBuy, pairA);
                assertEq(poolSell, pairB);
                assertEq(amountIn, (uint256(aR1) * 200) / 10_000);
                uint256 bought = _amountOut(amountIn, aR1, aR0);
                uint256 proceeds = _amountOut(bought, bR0, bR1);
                assertEq(estimatedProfit, proceeds - amountIn, "event estimate must match the model");
            }
        }
        assertTrue(found, "ArbSignalled must be emitted");
    }

    /// The ArbExecuted event's profit equals both the executor's booked
    /// totalProfit and its actual token1 balance gain.
    function testFuzz_execution_event_matches_balances(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();

        uint256 before = _token1().balanceOf(address(executor));
        vm.recordLogs();
        vm.prank(PROXY);
        executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("ArbExecuted(uint256,address,address,uint256,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(executor) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), arbNonce);
                (address b, address s, uint256 aIn, uint256 aOut, uint256 profit) =
                    abi.decode(logs[i].data, (address, address, uint256, uint256, uint256));
                assertEq(b, poolBuy);
                assertEq(s, poolSell);
                assertEq(aIn, amountIn);
                assertEq(aOut - aIn, profit);
                assertEq(profit, executor.totalProfit(), "event profit must equal booked profit");
                assertEq(profit, _token1().balanceOf(address(executor)) - before, "event profit must equal balance gain");
            }
        }
        assertTrue(found, "ArbExecuted must be emitted");
    }

    // ------------------------------------------------------------------
    // Executor bookkeeping and owner surface
    // ------------------------------------------------------------------

    /// lastExecAt records exactly the timestamp of the execution.
    function testFuzz_executor_last_exec_at(uint256 warpTo) public {
        warpTo = bound(warpTo, 1_600_000_000, 2_000_000_000);
        _whaleBuyToken0(pairB, 100_000 ether);
        vm.warp(warpTo);
        vm.prank(PROXY);
        executor.executeArb(address(rsc), 1, pairA, pairB, 20_000 ether);
        assertEq(executor.lastExecAt(), warpTo);
    }

    /// With a zero timestamp cooldown, two executions in the very same
    /// second both succeed.
    function testFuzz_executor_zero_cooldown_same_second(uint256 warpTo) public {
        warpTo = bound(warpTo, 1_600_000_000, 2_000_000_000);
        _whaleBuyToken0(pairB, 100_000 ether);
        vm.warp(warpTo);
        vm.prank(PROXY);
        executor.executeArb(address(rsc), 1, pairA, pairB, 20_000 ether);
        vm.prank(PROXY);
        executor.executeArb(address(rsc), 2, pairA, pairB, 20_000 ether);
        assertEq(executor.arbsExecuted(), 2);
        assertEq(executor.lastExecAt(), warpTo);
    }

    /// The owner's rescue moves exactly the requested amount of any held
    /// token to any recipient, and the executor's balance drops by the
    /// same amount.
    function testFuzz_executor_rescue_moves_exact_amount(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(executor) && to != address(this));
        amount = bound(amount, 0, INVENTORY);
        uint256 toBefore = _token1().balanceOf(to);
        executor.rescue(address(_token1()), to, amount);
        assertEq(_token1().balanceOf(to), toBefore + amount);
        assertEq(_token1().balanceOf(address(executor)), INVENTORY - amount);
    }

    /// The owner's native withdrawal moves exactly the requested amount.
    function testFuzz_executor_withdraw_native(address payable to, uint256 amount) public {
        // Ordinary addresses only: precompiles (< 0x100) reject plain
        // value calls despite having no code, and fuzz-dictionary contract
        // addresses may reject them too.
        to = payable(address(uint160(bound(uint256(uint160(address(to))), 0x10000, type(uint160).max))));
        vm.assume(to.code.length == 0 && to != address(executor) && to != address(this));
        amount = bound(amount, 0, 5 ether);
        vm.deal(address(executor), 5 ether);
        uint256 before = to.balance;
        executor.withdrawNative(to, amount);
        assertEq(to.balance, before + amount);
        assertEq(address(executor).balance, 5 ether - amount);
    }

    // ------------------------------------------------------------------
    // Extreme reserve shapes must not break the decision logic
    // ------------------------------------------------------------------

    /// Both pools reporting the same (fuzzed) reserves means equal prices
    /// at any scale — including near the uint112 ceiling — and no signal.
    function testFuzz_equal_extreme_reserves_no_signal(uint112 r) public {
        vm.assume(r > 0);
        IReactive.LogRecord memory logA = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: pairA,
            topic0: SYNC_TOPIC,
            topic1: IGNORE_TOPIC,
            topic2: IGNORE_TOPIC,
            topic3: IGNORE_TOPIC,
            data: abi.encode(r, r),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 424242,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        rsc.react(logA);
        IReactive.LogRecord memory logB = logA;
        logB.contractAddress = pairB;
        vm.prank(SYSTEM_ADDR);
        rsc.react(logB);
        assertEq(rsc.pricesSeen(), 2);
        assertEq(rsc.arbsSignalled(), 0, "equal prices at any scale must not signal");
    }

    /// A maximally skewed second pool (1 wei of token0 against a fuzzed
    /// ocean of token1) still produces a decision, not a panic: the RSC
    /// prices it, sizes off venue A, and signals. The ocean must exceed
    /// the 20,000-ether trade size — a pool holding less token1 than the
    /// trade needs back is correctly judged unprofitable.
    function testFuzz_skewed_extreme_reserves_still_decide(uint112 ocean) public {
        vm.assume(ocean > 100_000 ether);
        vm.roll(1000);
        _feed(pairA); // venue A at its real 1M / 1M reserves
        IReactive.LogRecord memory logB = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: pairB,
            topic0: SYNC_TOPIC,
            topic1: IGNORE_TOPIC,
            topic2: IGNORE_TOPIC,
            topic3: IGNORE_TOPIC,
            data: abi.encode(uint112(1), ocean),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 424242,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        rsc.react(logB);
        assertEq(rsc.arbsSignalled(), 1, "an extreme but real spread must still signal");
        (, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();
        assertEq(poolBuy, pairA);
        assertEq(poolSell, pairB);
        assertEq(amountIn, 20_000 ether);
    }
}
