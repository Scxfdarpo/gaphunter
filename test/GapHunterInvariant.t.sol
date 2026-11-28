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

interface IInvFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IInvPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address to) external returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/**
 * @notice Stateful handler for the invariant suite. The fuzzer drives the
 *         whole GapHunter system through this contract in random order:
 *         whale swaps that open and close gaps on both venues, Sync
 *         deliveries (plus noise logs from strangers), block/time travel,
 *         owner retunes of both contracts, and callback deliveries through
 *         the stand-in proxy. Ghost variables mirror what the contracts'
 *         observable state must be if every guard holds, and the invariant
 *         functions in GapHunterInvariantTest compare the two after every
 *         sequence.
 */
contract GapHunterHandler is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address payable internal constant PROXY = payable(address(0xCA11));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant SYNC_TOPIC = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    uint256 internal constant IGNORE_TOPIC = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    GapHunterReactive public rsc;
    GapHunterExecutor public executor;
    address public pairA;
    address public pairB;
    address public owner;

    // Ghost state: the handler's own accounting of what must be true.
    uint256 public ghostFeeds;
    uint256 public ghostA0;
    uint256 public ghostA1;
    uint256 public ghostB0;
    uint256 public ghostB1;
    uint256 public ghostSignals;
    uint256 public ghostLastSignalBlock;
    uint256 public ghostExecSuccess;
    uint256 public ghostDeliveredNonce;

    constructor(GapHunterReactive rsc_, GapHunterExecutor executor_, address pairA_, address pairB_, address owner_) {
        rsc = rsc_;
        executor = executor_;
        pairA = pairA_;
        pairB = pairB_;
        owner = owner_;
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return (withFee * reserveOut) / (reserveIn * 1000 + withFee);
    }

    function _whaleBuy(address pair, uint256 amount1In) internal {
        address t1 = IInvPair(pair).token1();
        (uint112 r0, uint112 r1,) = IInvPair(pair).getReserves();
        uint256 out = _amountOut(amount1In, r1, r0);
        if (out == 0) return;
        MockERC20(t1).mint(address(this), amount1In);
        MockERC20(t1).transfer(pair, amount1In);
        IInvPair(pair).swap(out, 0, address(this), new bytes(0));
    }

    function _whaleSell(address pair, uint256 amount0In) internal {
        address t0 = IInvPair(pair).token0();
        (uint112 r0, uint112 r1,) = IInvPair(pair).getReserves();
        uint256 out = _amountOut(amount0In, r0, r1);
        if (out == 0) return;
        MockERC20(t0).mint(address(this), amount0In);
        MockERC20(t0).transfer(pair, amount0In);
        IInvPair(pair).swap(0, out, address(this), new bytes(0));
    }

    function whaleBuyA(uint256 amount) external {
        _whaleBuy(pairA, bound(amount, 1_000 ether, 300_000 ether));
    }

    function whaleBuyB(uint256 amount) external {
        _whaleBuy(pairB, bound(amount, 1_000 ether, 300_000 ether));
    }

    function whaleSellA(uint256 amount) external {
        _whaleSell(pairA, bound(amount, 1_000 ether, 300_000 ether));
    }

    function whaleSellB(uint256 amount) external {
        _whaleSell(pairB, bound(amount, 1_000 ether, 300_000 ether));
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

    function _feed(address pair) internal {
        (uint112 r0, uint112 r1,) = IInvPair(pair).getReserves();
        if (pair == pairA) {
            ghostA0 = r0;
            ghostA1 = r1;
        } else {
            ghostB0 = r0;
            ghostB1 = r1;
        }
        ghostFeeds++;
        vm.prank(SYSTEM_ADDR);
        rsc.react(_log(pair, r0, r1, SYNC_TOPIC));
        if (rsc.arbsSignalled() > ghostSignals) {
            ghostSignals = rsc.arbsSignalled();
            ghostLastSignalBlock = block.number;
        }
    }

    function feedA() external {
        _feed(pairA);
    }

    function feedB() external {
        _feed(pairB);
    }

    /// Logs from strangers / with wrong topics: must never move any state.
    function feedNoise(address from, uint256 topic0) external {
        address stranger = address(uint160(uint256(keccak256(abi.encode(from, topic0, block.number)))));
        if (stranger == pairA || stranger == pairB) return;
        vm.prank(SYSTEM_ADDR);
        rsc.react(_log(stranger, 1, 1, topic0));
    }

    function advanceBlocks(uint256 n) external {
        vm.roll(block.number + bound(n, 1, 64));
    }

    function advanceTime(uint256 n) external {
        vm.warp(block.timestamp + bound(n, 1, 7200));
    }

    /// Deliver the most recent captured callback through the proxy, as the
    /// Reactive Network would. A reverting delivery is a legitimate
    /// outcome (stale gap, cooldown) and is swallowed; only successes are
    /// counted in the ghost.
    function deliverCallback() external {
        MockSystemRecorder sys = MockSystemRecorder(SYSTEM_ADDR);
        if (sys.callbackCalls() == 0) return;
        uint256 currentNonce = rsc.nonce();
        if (currentNonce <= ghostDeliveredNonce) return;
        ghostDeliveredNonce = currentNonce;

        bytes memory payload = sys.lastPayload();
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (, uint256 arbNonce, address poolBuy, address poolSell, uint256 amountIn) =
            abi.decode(args, (address, uint256, address, address, uint256));

        vm.prank(PROXY);
        try executor.executeArb(address(rsc), arbNonce, poolBuy, poolSell, amountIn) {
            ghostExecSuccess++;
        } catch {}
    }

    /// Owner retunes of the reactive contract's gates, within sane bands.
    function retune(uint256 t, uint256 f, uint256 c, uint256 m) external {
        vm.prank(owner);
        rsc.setParams(bound(t, 0, 2000), bound(f, 10, 1000), bound(c, 0, 50), bound(m, 0, 1000));
    }

    /// Owner retunes of the executor's timestamp cooldown.
    function retuneCooldown(uint256 c) external {
        vm.prank(owner);
        executor.setCooldown(bound(c, 0, 3600));
    }
}

/**
 * @notice Invariant suite: after every randomized handler sequence, the
 *         contracts' observable state must match the handler's ghost
 *         accounting and the system's structural identities — nonce
 *         discipline on both contracts, the executor's balance identity
 *         (token1 held == initial inventory + booked profit), zero token0
 *         dust, stored reserves equal to the last delivered Sync, and
 *         callbacks always routed to the executor on the origin chain.
 */
contract GapHunterInvariantTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address payable internal constant PROXY = payable(address(0xCA11));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant POOL_SIZE = 1_000_000 ether;
    uint256 internal constant INVENTORY = 500_000 ether;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    address internal pairA;
    address internal pairB;
    GapHunterReactive internal rsc;
    GapHunterExecutor internal executor;
    GapHunterHandler internal handler;

    function setUp() public {
        MockSystemRecorder recorder = new MockSystemRecorder();
        vm.etch(SYSTEM_ADDR, address(recorder).code);

        tokenA = new MockERC20("Gap Token A", "GTA", 18);
        tokenB = new MockERC20("Gap Token B", "GTB", 18);

        address factoryA = address(new MockV2Factory());
        address factoryB = address(new MockV2Factory());
        pairA = IInvFactory(factoryA).createPair(address(tokenA), address(tokenB));
        pairB = IInvFactory(factoryB).createPair(address(tokenA), address(tokenB));

        _seed(pairA, POOL_SIZE, POOL_SIZE);
        _seed(pairB, POOL_SIZE, POOL_SIZE);

        rsc = new GapHunterReactive(BASE_SEPOLIA, pairA, pairB);
        executor = new GapHunterExecutor(IPayable(PROXY), address(rsc));
        rsc.setExecutor(address(executor));

        address token1 = IInvPair(pairA).token1();
        MockERC20(token1).mint(address(executor), INVENTORY);
        executor.setCooldown(0);

        handler = new GapHunterHandler(rsc, executor, pairA, pairB, address(this));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = GapHunterHandler.whaleBuyA.selector;
        selectors[1] = GapHunterHandler.whaleBuyB.selector;
        selectors[2] = GapHunterHandler.whaleSellA.selector;
        selectors[3] = GapHunterHandler.whaleSellB.selector;
        selectors[4] = GapHunterHandler.feedA.selector;
        selectors[5] = GapHunterHandler.feedB.selector;
        selectors[6] = GapHunterHandler.feedNoise.selector;
        selectors[7] = GapHunterHandler.advanceBlocks.selector;
        selectors[8] = GapHunterHandler.advanceTime.selector;
        selectors[9] = GapHunterHandler.deliverCallback.selector;
        selectors[10] = GapHunterHandler.retune.selector;
        selectors[11] = GapHunterHandler.retuneCooldown.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function _seed(address pair, uint256 amount0, uint256 amount1) internal {
        address t0 = IInvPair(pair).token0();
        address t1 = IInvPair(pair).token1();
        MockERC20(t0).mint(address(this), amount0);
        MockERC20(t1).mint(address(this), amount1);
        MockERC20(t0).transfer(pair, amount0);
        MockERC20(t1).transfer(pair, amount1);
        IInvPair(pair).mint(address(this));
    }

    /// The RSC's nonce is incremented exactly once per signalled arb:
    /// the two counters can never drift apart.
    function invariant_nonce_equals_signals() public view {
        assertEq(rsc.nonce(), rsc.arbsSignalled());
        assertEq(rsc.arbsSignalled(), handler.ghostSignals());
    }

    /// The executor can only ever consume nonces the RSC has issued.
    function invariant_executor_nonce_within_rsc_nonce() public view {
        assertLe(executor.lastNonce(), rsc.nonce());
    }

    /// Every successful execution on-chain is accounted for by exactly
    /// one successful delivery in the handler — no phantom executions.
    function invariant_executions_match_ghost() public view {
        assertEq(executor.arbsExecuted(), handler.ghostExecSuccess());
    }

    /// Balance identity: the executor's token1 holdings are always the
    /// initial inventory plus exactly the profit it has booked. Nothing
    /// leaks, nothing appears from nowhere.
    function invariant_token1_balance_identity() public view {
        address token1 = IInvPair(pairA).token1();
        assertEq(MockERC20(token1).balanceOf(address(executor)), INVENTORY + executor.totalProfit());
    }

    /// The executor never ends a sequence holding token0: every bought
    /// token0 is sold on in the same atomic callback.
    function invariant_executor_holds_no_token0() public view {
        address token0 = IInvPair(pairA).token0();
        assertEq(MockERC20(token0).balanceOf(address(executor)), 0);
    }

    /// pricesSeen counts exactly the watched pools' Sync deliveries.
    function invariant_prices_seen_matches_ghost() public view {
        assertEq(rsc.pricesSeen(), handler.ghostFeeds());
    }

    /// Stored reserves always equal the reserves in the last Sync
    /// delivered for each pool — stale or invented prices are impossible.
    function invariant_stored_reserves_match_last_feed() public view {
        assertEq(rsc.reserveA0(), handler.ghostA0());
        assertEq(rsc.reserveA1(), handler.ghostA1());
        assertEq(rsc.reserveB0(), handler.ghostB0());
        assertEq(rsc.reserveB1(), handler.ghostB1());
    }

    /// lastArbBlock always points at the block of the most recent signal.
    function invariant_last_arb_block_matches_ghost() public view {
        assertEq(rsc.lastArbBlock(), handler.ghostLastSignalBlock());
    }

    /// Profit is booked if and only if at least one arb has executed,
    /// and every executed arb books a strictly positive profit.
    function invariant_profit_iff_executions() public view {
        if (executor.arbsExecuted() == 0) {
            assertEq(executor.totalProfit(), 0);
        } else {
            assertGt(executor.totalProfit(), 0);
        }
    }

    /// Every callback the RSC requests is routed to the executor, on the
    /// origin chain, with the full callback gas limit.
    function invariant_callback_routing() public view {
        MockSystemRecorder sys = MockSystemRecorder(SYSTEM_ADDR);
        if (sys.callbackCalls() > 0) {
            assertEq(sys.lastRecipient(), address(executor));
            assertEq(sys.lastChainId(), BASE_SEPOLIA);
            assertEq(sys.lastGasLimit(), 1_000_000);
        }
    }

    /// Neither pool can ever be drained by the handler's bounded whales:
    /// both token balances stay strictly positive.
    function invariant_pools_stay_solvent() public view {
        address t0 = IInvPair(pairA).token0();
        address t1 = IInvPair(pairA).token1();
        assertGt(MockERC20(t0).balanceOf(pairA), 0);
        assertGt(MockERC20(t1).balanceOf(pairA), 0);
        assertGt(MockERC20(t0).balanceOf(pairB), 0);
        assertGt(MockERC20(t1).balanceOf(pairB), 0);
    }

    /// A signal is produced only while processing a Sync delivery, so
    /// signals can never outnumber processed prices.
    function invariant_signals_bounded_by_feeds() public view {
        assertLe(rsc.arbsSignalled(), rsc.pricesSeen());
    }
}
