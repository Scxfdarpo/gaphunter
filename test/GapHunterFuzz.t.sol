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

interface IFuzzFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IFuzzPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/**
 * @notice Property / fuzz suite for GapHunter. Where GapHunter.t.sol walks
 *         one scripted gap and GapHunterGuards.t.sol pins the gates at
 *         hand-picked values, this suite states the properties as
 *         universally quantified claims and lets the fuzzer search for
 *         counterexamples across randomized reserves, spreads, callers,
 *         nonces, parameters and timestamps:
 *
 *         - the RSC signals only when the spread, the estimated profit and
 *           the cooldown all allow it, sizes the trade exactly as
 *           configured, and never reacts to strangers or non-Sync logs;
 *         - the executor's behaviour matches the constant-product pricing
 *           model exactly: it executes if and only if the model says the
 *           round trip is profitable, books exactly the modelled profit,
 *           enforces a strictly monotonic nonce and a timestamp cooldown,
 *           and rejects every caller/sender that is not the callback
 *           proxy delivering for the real reactive contract.
 */
contract GapHunterFuzzTest is Test {
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
        pairA = IFuzzFactory(factoryA).createPair(address(tokenA), address(tokenB));
        pairB = IFuzzFactory(factoryB).createPair(address(tokenA), address(tokenB));

        _seed(pairA, POOL_SIZE, POOL_SIZE);
        _seed(pairB, POOL_SIZE, POOL_SIZE);

        rsc = new GapHunterReactive(BASE_SEPOLIA, pairA, pairB);
        executor = new GapHunterExecutor(IPayable(PROXY), address(rsc));
        rsc.setExecutor(address(executor));

        address token1 = IFuzzPair(pairA).token1();
        MockERC20(token1).mint(address(executor), INVENTORY);
        executor.setCooldown(0);
    }

    function _seed(address pair, uint256 amount0, uint256 amount1) internal {
        address t0 = IFuzzPair(pair).token0();
        address t1 = IFuzzPair(pair).token1();
        MockERC20(t0).mint(address(this), amount0);
        MockERC20(t1).mint(address(this), amount1);
        MockERC20(t0).transfer(pair, amount0);
        MockERC20(t1).transfer(pair, amount1);
        IFuzzPair(pair).mint(address(this));
    }

    function _log(address pair, uint112 r0, uint112 r1, uint256 topic0)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: pair,
            topic0: topic0,
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

    function _syncLog(address pair) internal view returns (IReactive.LogRecord memory) {
        (uint112 r0, uint112 r1,) = IFuzzPair(pair).getReserves();
        return _log(pair, r0, r1, SYNC_TOPIC);
    }

    function _feed(address pair) internal {
        IReactive.LogRecord memory log = _syncLog(pair);
        vm.prank(SYSTEM_ADDR);
        rsc.react(log);
    }

    /// @dev Whale spends token1 to buy token0 on `pair` (token0 gets expensive there).
    function _whaleBuyToken0(address pair, uint256 amount1In) internal {
        address t1 = IFuzzPair(pair).token1();
        (uint112 r0, uint112 r1,) = IFuzzPair(pair).getReserves();
        uint256 out = _amountOut(amount1In, r1, r0);
        MockERC20(t1).mint(address(this), amount1In);
        MockERC20(t1).transfer(pair, amount1In);
        IFuzzPair(pair).swap(out, 0, address(this), new bytes(0));
    }

    /// @dev Whale sells token0 into `pair` (token0 gets cheap there).
    function _whaleSellToken0(address pair, uint256 amount0In) internal {
        address t0 = IFuzzPair(pair).token0();
        (uint112 r0, uint112 r1,) = IFuzzPair(pair).getReserves();
        uint256 out = _amountOut(amount0In, r0, r1);
        MockERC20(t0).mint(address(this), amount0In);
        MockERC20(t0).transfer(pair, amount0In);
        IFuzzPair(pair).swap(0, out, address(this), new bytes(0));
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

    // ------------------------------------------------------------------
    // Reactive contract: access control and log filtering
    // ------------------------------------------------------------------

    /// react() is onlySystem: no fuzzed caller other than the system
    /// contract itself may deliver a log.
    function testFuzz_react_rejects_non_system_caller(address caller) public {
        vm.assume(caller != SYSTEM_ADDR);
        IReactive.LogRecord memory log = _syncLog(pairA);
        vm.prank(caller);
        vm.expectRevert();
        rsc.react(log);
        assertEq(rsc.pricesSeen(), 0);
    }

    /// Sync logs from pools the RSC does not watch are ignored, whatever
    /// reserves they claim.
    function testFuzz_react_ignores_unwatched_pool(address stranger, uint112 r0, uint112 r1) public {
        vm.assume(stranger != pairA && stranger != pairB);
        IReactive.LogRecord memory log = _log(stranger, r0, r1, SYNC_TOPIC);
        vm.prank(SYSTEM_ADDR);
        rsc.react(log);
        assertEq(rsc.pricesSeen(), 0, "unwatched pool must be ignored");
        assertEq(rsc.arbsSignalled(), 0);
    }

    /// Logs whose topic0 is not the Sync topic are ignored.
    function testFuzz_react_ignores_non_sync_topic(uint256 topic0) public {
        vm.assume(topic0 != SYNC_TOPIC);
        (uint112 r0, uint112 r1,) = IFuzzPair(pairA).getReserves();
        IReactive.LogRecord memory log = _log(pairA, r0, r1, topic0);
        vm.prank(SYSTEM_ADDR);
        rsc.react(log);
        assertEq(rsc.pricesSeen(), 0, "non-Sync topic must be ignored");
    }

    /// A watched pool's Sync log always lands in the stored reserves
    /// verbatim and bumps the processed counter by exactly one. (No signal
    /// can fire here: the other pool has never been seen, so its stored
    /// reserves are still zero.)
    function testFuzz_react_stores_reserves_verbatim(uint112 r0, uint112 r1) public {
        IReactive.LogRecord memory log = _log(pairA, r0, r1, SYNC_TOPIC);
        vm.prank(SYSTEM_ADDR);
        rsc.react(log);
        assertEq(rsc.reserveA0(), uint256(r0));
        assertEq(rsc.reserveA1(), uint256(r1));
        assertEq(rsc.pricesSeen(), 1);
        assertEq(rsc.arbsSignalled(), 0);
    }

    /// Every owner-only function on the reactive contract rejects every
    /// non-owner caller.
    function testFuzz_reactive_owner_guards(address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert("not owner");
        rsc.setExecutor(caller);
        vm.expectRevert("not owner");
        rsc.setParams(1, 1, 1, 1);
        vm.expectRevert("not owner");
        rsc.withdraw(payable(caller), 1);
        vm.stopPrank();
    }

    /// setParams is a pure storage round-trip for the owner: whatever is
    /// written is what the getters return.
    function testFuzz_setParams_roundtrip(uint256 t, uint256 f, uint256 c, uint256 m) public {
        rsc.setParams(t, f, c, m);
        assertEq(rsc.thresholdBps(), t);
        assertEq(rsc.tradeFractionBps(), f);
        assertEq(rsc.cooldownBlocks(), c);
        assertEq(rsc.minProfitBps(), m);
    }

    /// The owner can withdraw any amount up to the contract balance, to
    /// any ordinary address.
    function testFuzz_reactive_withdraw(address payable to, uint256 amount) public {
        // Ordinary addresses only: precompiles (< 0x100) and
        // fuzz-dictionary contract addresses such as Multicall3
        // (0x7109709E...) reject plain ETH transfers, which is their
        // behaviour, not the withdraw path's.
        to = payable(address(uint160(bound(uint256(uint160(address(to))), 0x10000, type(uint160).max))));
        vm.assume(to.code.length == 0 && to != address(rsc) && to != address(this));
        amount = bound(amount, 0, 10 ether);
        vm.deal(address(rsc), 10 ether);
        uint256 before = to.balance;
        rsc.withdraw(to, amount);
        assertEq(to.balance, before + amount);
        assertEq(address(rsc).balance, 10 ether - amount);
    }

    // ------------------------------------------------------------------
    // Reactive contract: signal gates under fuzzed market conditions
    // ------------------------------------------------------------------

    /// Whale buys of at most 6,000 GTB move venue B's price by at most
    /// ~121 bps — below the 150 bps fee-adjusted threshold — so however
    /// large the (bounded) trade, the RSC must stay silent.
    function testFuzz_no_signal_below_threshold(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 1 ether, 6_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.pricesSeen(), 2);
        assertEq(rsc.arbsSignalled(), 0, "sub-threshold spread must never signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);
    }

    /// Same property on the mirror venue (token0 dumped on venue A makes
    /// it cheap there; small sales stay below the threshold too).
    function testFuzz_no_signal_below_threshold_mirror(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 1 ether, 6_000 ether);
        vm.roll(1000);
        _whaleSellToken0(pairA, whaleIn);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 0, "sub-threshold spread must never signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);
    }

    /// A 100,000 GTB whale buy on venue B opens a 2,097 bps spread. Any
    /// threshold strictly above that spread suppresses the signal.
    function testFuzz_no_signal_when_threshold_above_spread(uint256 thresholdBps) public {
        thresholdBps = bound(thresholdBps, 2098, 100_000);
        rsc.setParams(thresholdBps, 200, 20, 30);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 0, "threshold above the spread must suppress the signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);
    }

    /// Any threshold at or below the default 150 bps lets the same gap
    /// signal exactly once, sized at the default 2% of the buy pool.
    function testFuzz_signal_when_threshold_below_spread(uint256 thresholdBps) public {
        thresholdBps = bound(thresholdBps, 0, 150);
        rsc.setParams(thresholdBps, 200, 20, 30);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) = _lastSignal();
        assertEq(arbNonce, 1);
        assertEq(poolBuy, pairA);
        assertEq(poolSell, pairB);
        assertEq(amountIn, 20_000 ether, "2% of the buy pool's token1 reserves");
    }

    /// The minimum-profit gate: the 100k-whale gap at the default 2% size
    /// estimates to ~1,541 bps of profit. Any gate above that suppresses
    /// the signal even though the spread clears the threshold.
    function testFuzz_no_signal_when_min_profit_above_estimate(uint256 minProfitBps) public {
        minProfitBps = bound(minProfitBps, 1700, 100_000);
        rsc.setParams(150, 200, 20, minProfitBps);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 0, "profit below the gate must not signal");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);
    }

    /// Any minimum-profit gate up to 1,500 bps lets the same gap signal.
    function testFuzz_signal_when_min_profit_below_estimate(uint256 minProfitBps) public {
        minProfitBps = bound(minProfitBps, 0, 1500);
        rsc.setParams(150, 200, 20, minProfitBps);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
    }

    /// The signalled trade size is exactly tradeFractionBps of the buy
    /// pool's token1 reserves, for any configured fraction in a sane band.
    function testFuzz_signal_size_follows_fraction(uint256 fractionBps) public {
        fractionBps = bound(fractionBps, 10, 1000);
        rsc.setParams(150, fractionBps, 20, 30);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 200_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (, address poolBuy,, uint256 amountIn) = _lastSignal();
        assertEq(poolBuy, pairA);
        assertEq(amountIn, (POOL_SIZE * fractionBps) / 10_000, "size = fraction of buy pool token1 reserves");
    }

    /// Direction selection, both branches, under fuzzed gap sizes: the
    /// signal always buys token0 on whichever venue the whale made cheap.
    function testFuzz_signal_direction(uint256 whaleIn, bool cheapOnB) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        if (cheapOnB) {
            _whaleSellToken0(pairB, whaleIn); // token0 cheap on B
        } else {
            _whaleBuyToken0(pairB, whaleIn); // token0 expensive on B = cheap on A
        }
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);
        (, address poolBuy, address poolSell,) = _lastSignal();
        if (cheapOnB) {
            assertEq(poolBuy, pairB);
            assertEq(poolSell, pairA);
        } else {
            assertEq(poolBuy, pairA);
            assertEq(poolSell, pairB);
        }
    }

    /// Inside the 20-block cooldown window no second signal fires,
    /// however close to the boundary the next Sync arrives.
    function testFuzz_cooldown_suppresses_within_window(uint256 rollDelta) public {
        rollDelta = bound(rollDelta, 0, 19);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);

        vm.roll(1000 + rollDelta);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1, "cooldown must suppress signals inside the window");
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 1);
    }

    /// Once the cooldown has lapsed the still-open gap signals again, the
    /// nonce increments by exactly one, and lastArbBlock tracks the block
    /// of the latest signal.
    function testFuzz_cooldown_lapses_and_nonce_increments(uint256 rollDelta) public {
        rollDelta = bound(rollDelta, 20, 500);
        vm.roll(1000);
        _whaleBuyToken0(pairB, 100_000 ether);
        _feed(pairA);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 1);

        vm.roll(1000 + rollDelta);
        _feed(pairB);
        assertEq(rsc.arbsSignalled(), 2, "gap must signal again after the cooldown");
        assertEq(rsc.nonce(), 2, "nonce increments by exactly one per signal");
        assertEq(rsc.lastArbBlock(), 1000 + rollDelta);
        (uint256 arbNonce,,,) = _lastSignal();
        assertEq(arbNonce, 2);
    }

    /// No signal can fire until both pools have been seen at least once:
    /// feeding only the whale-moved pool leaves the other pool's stored
    /// reserves at zero and the RSC silent; completing the pair signals.
    function testFuzz_no_signal_until_both_pools_seen(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        _feed(pairB);
        assertEq(rsc.pricesSeen(), 1);
        assertEq(rsc.arbsSignalled(), 0, "one pool alone can never signal");
        _feed(pairA);
        assertEq(rsc.arbsSignalled(), 1);
    }

    /// Without an executor configured, price updates are still processed
    /// but no callback is ever requested.
    function testFuzz_no_callback_without_executor(uint256 whaleIn) public {
        whaleIn = bound(whaleIn, 50_000 ether, 200_000 ether);
        GapHunterReactive bare = new GapHunterReactive(BASE_SEPOLIA, pairA, pairB);
        vm.roll(1000);
        _whaleBuyToken0(pairB, whaleIn);
        IReactive.LogRecord memory logA = _syncLog(pairA);
        vm.prank(SYSTEM_ADDR);
        bare.react(logA);
        IReactive.LogRecord memory logB = _syncLog(pairB);
        vm.prank(SYSTEM_ADDR);
        bare.react(logB);
        assertEq(bare.pricesSeen(), 2);
        assertEq(bare.arbsSignalled(), 0);
        assertEq(MockSystemRecorder(SYSTEM_ADDR).callbackCalls(), 0);
    }

    /// pricesSeen is an exact counter: n Sync deliveries from the watched
    /// pools (equal prices, so no signals) move it by exactly n.
    function testFuzz_prices_seen_counts_exactly(uint256 n) public {
        n = bound(n, 1, 24);
        for (uint256 i = 0; i < n; i++) {
            _feed(i % 2 == 0 ? pairA : pairB);
        }
        assertEq(rsc.pricesSeen(), n);
        assertEq(rsc.arbsSignalled(), 0, "equal prices never signal");
    }

    // ------------------------------------------------------------------
    // Executor: the pricing-model equivalence property
    // ------------------------------------------------------------------

    /// The central safety property, as an if-and-only-if over randomized
    /// gaps and trade sizes: computing the constant-product round trip
    /// off-chain from live reserves, the executor executes exactly when
    /// the model says the trade is profitable, books exactly the modelled
    /// profit, and otherwise reverts "unprofitable" leaving no trace.
    function testFuzz_executor_matches_pricing_model(uint256 whaleIn, uint256 amountIn) public {
        whaleIn = bound(whaleIn, 1_000 ether, 300_000 ether);
        amountIn = bound(amountIn, 100 ether, 100_000 ether);
        _whaleBuyToken0(pairB, whaleIn);

        address token1 = IFuzzPair(pairA).token1();
        (uint112 bR0, uint112 bR1,) = IFuzzPair(pairA).getReserves();
        (uint112 sR0, uint112 sR1,) = IFuzzPair(pairB).getReserves();
        uint256 bought = _amountOut(amountIn, bR1, bR0);
        uint256 proceeds = _amountOut(bought, sR0, sR1);

        uint256 balanceBefore = MockERC20(token1).balanceOf(address(executor));
        if (proceeds > amountIn) {
            vm.prank(PROXY);
            executor.executeArb(address(rsc), 1, pairA, pairB, amountIn);
            assertEq(executor.arbsExecuted(), 1);
            assertEq(executor.totalProfit(), proceeds - amountIn, "booked profit must equal the model");
            assertEq(
                MockERC20(token1).balanceOf(address(executor)),
                balanceBefore + (proceeds - amountIn),
                "token1 balance must grow by exactly the profit"
            );
            assertEq(MockERC20(IFuzzPair(pairA).token0()).balanceOf(address(executor)), 0, "no token0 dust left");
        } else {
            vm.prank(PROXY);
            vm.expectRevert("unprofitable");
            executor.executeArb(address(rsc), 1, pairA, pairB, amountIn);
            assertEq(executor.arbsExecuted(), 0);
            assertEq(executor.lastNonce(), 0, "a reverted callback consumes nothing");
            assertEq(MockERC20(token1).balanceOf(address(executor)), balanceBefore);
        }
    }

    /// At equal prices every trade size loses the double 0.3% fee, so
    /// every callback reverts as unprofitable.
    function testFuzz_executor_reverts_at_equal_prices(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 200_000 ether);
        vm.prank(PROXY);
        vm.expectRevert("unprofitable");
        executor.executeArb(address(rsc), 1, pairA, pairB, amountIn);
        assertEq(executor.arbsExecuted(), 0);
    }

    /// Even with a wide-open gap, a trade larger than the executor's
    /// token1 inventory reverts on the inventory check (after passing the
    /// profitability check), and nothing executes.
    function testFuzz_executor_reverts_without_inventory(uint256 amountIn) public {
        amountIn = bound(amountIn, INVENTORY + 1 ether, INVENTORY + 100_000 ether);
        _whaleBuyToken0(pairB, 900_000 ether); // ~90% spread: 501k-600k trades are model-profitable
        vm.prank(PROXY);
        vm.expectRevert("no inventory");
        executor.executeArb(address(rsc), 1, pairA, pairB, amountIn);
        assertEq(executor.arbsExecuted(), 0);
    }

    /// Nonce monotonicity under fuzzed nonces: after a successful
    /// execution with nonce n, any nonce <= n reverts as stale and any
    /// nonce > n executes (the gap is still open at these sizes).
    function testFuzz_executor_nonce_monotonic(uint256 nonceA, uint256 nonceB) public {
        nonceA = bound(nonceA, 1, 1_000_000);
        nonceB = bound(nonceB, 1, 2_000_000);
        _whaleBuyToken0(pairB, 100_000 ether);

        vm.prank(PROXY);
        executor.executeArb(address(rsc), nonceA, pairA, pairB, 20_000 ether);
        assertEq(executor.lastNonce(), nonceA);

        if (nonceB <= nonceA) {
            vm.prank(PROXY);
            vm.expectRevert("stale nonce");
            executor.executeArb(address(rsc), nonceB, pairA, pairB, 20_000 ether);
            assertEq(executor.arbsExecuted(), 1);
        } else {
            vm.prank(PROXY);
            executor.executeArb(address(rsc), nonceB, pairA, pairB, 20_000 ether);
            assertEq(executor.arbsExecuted(), 2);
            assertEq(executor.lastNonce(), nonceB);
        }
    }

    /// totalProfit is exactly the sum of the per-trade modelled profits
    /// across consecutive executions.
    function testFuzz_executor_profit_accumulates(uint256 nonceA, uint256 nonceBump) public {
        nonceA = bound(nonceA, 1, 1_000_000);
        nonceBump = bound(nonceBump, 1, 1_000_000);
        _whaleBuyToken0(pairB, 100_000 ether);

        (uint112 bR0, uint112 bR1,) = IFuzzPair(pairA).getReserves();
        (uint112 sR0, uint112 sR1,) = IFuzzPair(pairB).getReserves();
        uint256 profit1 = _amountOut(_amountOut(20_000 ether, bR1, bR0), sR0, sR1) - 20_000 ether;

        vm.prank(PROXY);
        executor.executeArb(address(rsc), nonceA, pairA, pairB, 20_000 ether);
        assertEq(executor.totalProfit(), profit1);

        (bR0, bR1,) = IFuzzPair(pairA).getReserves();
        (sR0, sR1,) = IFuzzPair(pairB).getReserves();
        uint256 profit2 = _amountOut(_amountOut(20_000 ether, bR1, bR0), sR0, sR1) - 20_000 ether;

        vm.prank(PROXY);
        executor.executeArb(address(rsc), nonceA + nonceBump, pairA, pairB, 20_000 ether);
        assertEq(executor.totalProfit(), profit1 + profit2);
        assertEq(executor.arbsExecuted(), 2);
    }

    /// Timestamp cooldown, inside the window: a second execution reverts
    /// for any cooldown and any in-window delay.
    function testFuzz_executor_cooldown_blocks_within_window(uint256 cooldown, uint256 delay) public {
        cooldown = bound(cooldown, 1, 100_000);
        delay = bound(delay, 0, cooldown - 1);
        executor.setCooldown(cooldown);
        _whaleBuyToken0(pairB, 100_000 ether);
        vm.warp(1_700_000_000);

        vm.prank(PROXY);
        executor.executeArb(address(rsc), 1, pairA, pairB, 20_000 ether);

        vm.warp(1_700_000_000 + delay);
        vm.prank(PROXY);
        vm.expectRevert("cooldown");
        executor.executeArb(address(rsc), 2, pairA, pairB, 20_000 ether);
        assertEq(executor.arbsExecuted(), 1);
    }

    /// Timestamp cooldown, past the window: the second execution succeeds.
    function testFuzz_executor_cooldown_allows_after_window(uint256 cooldown, uint256 delay) public {
        cooldown = bound(cooldown, 1, 100_000);
        delay = bound(delay, cooldown, cooldown + 100_000);
        executor.setCooldown(cooldown);
        _whaleBuyToken0(pairB, 100_000 ether);
        vm.warp(1_700_000_000);

        vm.prank(PROXY);
        executor.executeArb(address(rsc), 1, pairA, pairB, 20_000 ether);

        vm.warp(1_700_000_000 + delay);
        vm.prank(PROXY);
        executor.executeArb(address(rsc), 2, pairA, pairB, 20_000 ether);
        assertEq(executor.arbsExecuted(), 2);
        assertEq(executor.lastExecAt(), 1_700_000_000 + delay);
    }

    /// onlyServiceProvider: no fuzzed caller other than the callback
    /// proxy may invoke the callback entry point at all.
    function testFuzz_executor_rejects_non_proxy_caller(address caller) public {
        vm.assume(caller != PROXY);
        vm.prank(caller);
        vm.expectRevert();
        executor.executeArb(address(rsc), 1, pairA, pairB, 1 ether);
        assertEq(executor.arbsExecuted(), 0);
    }

    /// onlyCallbackSender: even delivered by the real proxy, a callback
    /// naming any sender other than the reactive contract is rejected.
    function testFuzz_executor_rejects_wrong_callback_sender(address fakeSender) public {
        vm.assume(fakeSender != address(rsc));
        vm.prank(PROXY);
        vm.expectRevert();
        executor.executeArb(fakeSender, 1, pairA, pairB, 1 ether);
        assertEq(executor.arbsExecuted(), 0);
    }

    /// A callback whose two pools do not share the same token pair is
    /// rejected for any trade size, before funds move.
    function testFuzz_executor_rejects_pair_mismatch(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 100_000 ether);
        MockERC20 tokenC = new MockERC20("Gap Token C", "GTC", 18);
        address factoryC = address(new MockV2Factory());
        address pairC = IFuzzFactory(factoryC).createPair(address(tokenA), address(tokenC));

        vm.prank(PROXY);
        vm.expectRevert("pair mismatch");
        executor.executeArb(address(rsc), 1, pairA, pairC, amountIn);
        assertEq(executor.arbsExecuted(), 0);
    }

    /// Every owner-only function on the executor rejects every non-owner.
    function testFuzz_executor_owner_guards(address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert("not owner");
        executor.setCooldown(1);
        vm.expectRevert("not owner");
        executor.rescue(address(tokenB), caller, 1);
        vm.expectRevert("not owner");
        executor.withdrawNative(payable(caller), 1);
        vm.stopPrank();
    }

    /// setCooldown is a storage round-trip for the owner.
    function testFuzz_setCooldown_roundtrip(uint256 cooldown) public {
        executor.setCooldown(cooldown);
        assertEq(executor.cooldownSeconds(), cooldown);
    }
}
