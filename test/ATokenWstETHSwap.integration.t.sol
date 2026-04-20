// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ATokenWstETHSwap} from "../src/ATokenWstETHSwap.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWstETH} from "../src/interfaces/IWstETH.sol";

/// @notice Integration tests for ATokenWstETHSwap against a mainnet fork.
/// @dev Requires the `mainnet` RPC endpoint (set via the MAINNET_RPC_URL env var).
///      The block is pinned so the vault's on-chain balances (used in assertions)
///      are deterministic.
contract ATokenWstETHSwapIntegrationTest is Test {
    using stdStorage for StdStorage;

    // Event redeclarations — needed so `emit ... ` / `vm.expectEmit` can reference them.
    event SwapWstETH(address indexed user, uint256 aEthWETHIn, uint256 aEthwstETHOut, uint256 profit);
    event ReferralRecorded(address indexed user, address indexed referral, uint256 aEthWETHIn, uint256 aEthwstETHOut);
    event PremiumUpdated(uint256 oldPremium, uint256 newPremium);
    event Paused(address account);
    event Unpaused(address account);

    // ─── Mainnet addresses ───────────────────────────────────────────────
    // Subvault holding the leveraged Aave V3 position (aEthwstETH collateral
    // + variableDebtEthWETH debt). Picked because `debt > supply` at the pinned
    // block — required by the debt-ceiling invariant tests.
    address constant VAULT = 0x893aa69FBAA1ee81B536f0FbE3A3453e86290080;

    IERC20 constant aEthWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);
    IERC20 constant aEthwstETH = IERC20(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);
    IWstETH constant wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 constant variableDebtEthWETH = IERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    // ─── Test actors ─────────────────────────────────────────────────────
    address owner = makeAddr("owner");
    address profitReceiver = makeAddr("profitReceiver");
    address user = makeAddr("user");
    address referral = makeAddr("referral");

    ATokenWstETHSwap swap;

    function setUp() public {
        // At block 24921000:
        //   aEthwstETH.balanceOf(VAULT)          ≈ 135,824.62 wstETH (1.358e23 wei)
        //   variableDebtEthWETH.balanceOf(VAULT) ≈ 141,684.07 WETH   (1.416e23 wei)
        //   aEthWETH.balanceOf(VAULT)            = 0
        // Invariant headroom: debt - supply ≈ 141,684 WETH (drives maxSwapFromDebtCeiling).
        // The vault holds only wstETH collateral and WETH debt — a pure leveraged stETH loop.
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24921000);

        // Direct deploy — no proxy. Premium starts at 0; individual tests set it via setPremium.
        swap = new ATokenWstETHSwap(owner, VAULT, profitReceiver, 0);

        // The vault must pre-approve the swap contract to spend its aEthwstETH.
        vm.prank(VAULT);
        aEthwstETH.approve(address(swap), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _fundUserWithAEthWETH(address to, uint256 amount) internal {
        // Aave's aToken `balanceOf` is `scaledBalance * liquidityIndex / 1e27`,
        // so forge's `deal` post-write check fails. We locate the scaled-balance
        // slot and write it directly, sized to yield at least `amount` of balanceOf.
        uint256 slot = stdstore.target(address(aEthWETH)).sig("balanceOf(address)").with_key(to).find();
        // Since liquidityIndex >= 1e27, writing `amount` to the scaled-balance
        // slot yields balanceOf >= amount.
        vm.store(address(aEthWETH), bytes32(slot), bytes32(amount));
        require(aEthWETH.balanceOf(to) >= amount, "funding produced insufficient aEthWETH");
    }

    /// @dev Return the vault's post-swap aEthWETH balance WITHOUT leaving any state
    ///      behind. Needed for exact-match `expectRevert` on `DebtCeilingBreached`:
    ///      Aave's rayDiv/rayMul rounding can bias `pre + amountIn` by ±1 wei when
    ///      the vault has non-zero pre-balance. Precondition: `user` already funded
    ///      and approved for at least `amountIn`. Requires a mocked debt that
    ///      trivially satisfies `_checkDebtCeiling`; we override to type(max) for
    ///      the probe and re-apply the caller's mock on return.
    function _probePostSwapSupply(uint256 amountIn) internal returns (uint256 postSupply) {
        // Capture the current mocked debt so we can restore it after the probe.
        // `balanceOf` returns whatever `vm.mockCall` has registered — there must be
        // one active before calling this helper.
        uint256 preProbeDebt = variableDebtEthWETH.balanceOf(VAULT);

        uint256 snap = vm.snapshotState();
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(type(uint256).max)
        );
        vm.prank(user);
        swap.swapToWstETH(amountIn, 0);
        postSupply = aEthWETH.balanceOf(VAULT);
        vm.revertToState(snap);

        // `vm.mockCall` registrations are cheatcode state, not EVM state, so they
        // survive `revertToState`. Re-apply the caller's original mock.
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(preProbeDebt)
        );
    }

    // ─── Setup / constructor tests ───────────────────────────────────────

    function test_Setup_InitialState() public view {
        assertEq(swap.owner(), owner);
        assertEq(swap.vault(), VAULT);
        assertEq(swap.profitReceiver(), profitReceiver);
        assertEq(swap.premium(), 0);
        assertFalse(swap.paused(), "should not be paused by default");
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        vm.expectRevert(ATokenWstETHSwap.ZeroAddress.selector);
        new ATokenWstETHSwap(address(0), VAULT, profitReceiver, 0);
    }

    function test_Constructor_RevertsOnZeroVault() public {
        vm.expectRevert(ATokenWstETHSwap.ZeroAddress.selector);
        new ATokenWstETHSwap(owner, address(0), profitReceiver, 0);
    }

    function test_Constructor_RevertsOnZeroProfitReceiver() public {
        vm.expectRevert(ATokenWstETHSwap.ZeroAddress.selector);
        new ATokenWstETHSwap(owner, VAULT, address(0), 0);
    }

    // ─── Swap tests ──────────────────────────────────────────────────────

    function test_SwapToWstETH_ZeroPremium_HappyPath() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 rate = swap.getWstETHRate();
        uint256 expectedOut = (amountIn * 1e18) / rate;
        assertEq(swap.getWstETHAmountOut(amountIn), expectedOut, "preview mismatch");

        uint256 userAEthWETHBefore = aEthWETH.balanceOf(user);
        uint256 userWstBefore = aEthwstETH.balanceOf(user);
        uint256 vaultAEthWETHBefore = aEthWETH.balanceOf(VAULT);
        uint256 vaultWstBefore = aEthwstETH.balanceOf(VAULT);
        uint256 profitReceiverWstBefore = aEthwstETH.balanceOf(profitReceiver);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, expectedOut);

        assertEq(amountOut, expectedOut, "amountOut mismatch");

        // aToken balances accrue interest between calls; tolerate small drift.
        assertApproxEqAbs(aEthWETH.balanceOf(user), userAEthWETHBefore - amountIn, 2, "user aEthWETH");
        assertApproxEqAbs(aEthwstETH.balanceOf(user), userWstBefore + amountOut, 2, "user aEthwstETH");
        assertApproxEqAbs(aEthWETH.balanceOf(VAULT), vaultAEthWETHBefore + amountIn, 2, "vault aEthWETH +input");
        assertApproxEqAbs(aEthwstETH.balanceOf(VAULT), vaultWstBefore - amountOut, 2, "vault aEthwstETH -output");
        assertEq(
            aEthwstETH.balanceOf(profitReceiver),
            profitReceiverWstBefore,
            "profit receiver should be untouched at 0 premium"
        );
    }

    function test_SwapToWstETH_WithPremium_DistributesProfit() public {
        uint256 premium = 20_000; // 2% in 6-decimal precision
        vm.prank(owner);
        swap.setPremium(premium);

        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 rate = swap.getWstETHRate();
        uint256 precision = swap.PREMIUM_PRECISION();
        uint256 effectiveInput = (amountIn * (precision - premium)) / precision;
        uint256 expectedOut = (effectiveInput * 1e18) / rate;
        uint256 fullAmount = (amountIn * 1e18) / rate;
        uint256 expectedProfit = fullAmount - expectedOut;

        assertEq(swap.getWstETHAmountOut(amountIn), expectedOut);
        assertEq(swap.getWstETHProfit(amountIn), expectedProfit);

        uint256 profitReceiverBefore = aEthwstETH.balanceOf(profitReceiver);
        uint256 userWstBefore = aEthwstETH.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, expectedOut);

        assertEq(amountOut, expectedOut);
        assertApproxEqAbs(aEthwstETH.balanceOf(user), userWstBefore + expectedOut, 2);
        assertApproxEqAbs(aEthwstETH.balanceOf(profitReceiver), profitReceiverBefore + expectedProfit, 2);
    }

    function test_SwapToWstETH_RevertsOnSlippage() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);
        uint256 amountOutMin = expectedOut + 1;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ATokenWstETHSwap.SlippageExceeded.selector, expectedOut, amountOutMin));
        swap.swapToWstETH(amountIn, amountOutMin);
    }

    function test_SwapToWstETH_RevertsWhenPaused() public {
        vm.prank(owner);
        swap.pause();
        assertTrue(swap.paused());

        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.ContractPaused.selector);
        swap.swapToWstETH(1 ether, 0);
    }

    function test_SwapToWstETH_RevertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.ZeroAmount.selector);
        swap.swapToWstETH(0, 0);
    }

    // ─── Referral entry-point ────────────────────────────────────────────

    function test_SwapToWstETHWithReferral_EmitsReferralRecorded() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);

        // Expect the referral event with both topics matching and data (amounts) equal.
        vm.expectEmit(true, true, false, true, address(swap));
        emit ReferralRecorded(user, referral, amountIn, expectedOut);

        vm.prank(user);
        swap.swapToWstETHWithReferral(amountIn, 0, referral);
    }

    // ─── View-function invariants ────────────────────────────────────────

    function test_AvailableWstETHLiquidity_MatchesMinOfBalanceAndAllowance() public view {
        uint256 liquidity = swap.availableWstETHLiquidity();
        uint256 bal = aEthwstETH.balanceOf(VAULT);
        uint256 allowance = aEthwstETH.allowance(VAULT, address(swap));
        uint256 expected = bal < allowance ? bal : allowance;
        assertEq(liquidity, expected);
    }

    function test_MaxSwapFromDebtCeiling_IsPositive() public view {
        uint256 supply = aEthWETH.balanceOf(VAULT);
        uint256 debt = variableDebtEthWETH.balanceOf(VAULT);
        // This vault was picked specifically because debt > supply at the pinned block.
        assertGt(debt, supply, "vault is expected to be leveraged (debt > supply)");
        assertGt(swap.maxSwapFromDebtCeiling(), 0);
    }

    // ─── Admin access control ────────────────────────────────────────────

    function test_SetPremium_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.OnlyOwner.selector);
        swap.setPremium(100);
    }

    function test_SetPremium_EmitsPremiumUpdated() public {
        uint256 next = 30_000;
        vm.expectEmit(false, false, false, true, address(swap));
        emit PremiumUpdated(0, next);

        vm.prank(owner);
        swap.setPremium(next);
        assertEq(swap.premium(), next);
    }

    function test_Pause_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.OnlyOwner.selector);
        swap.pause();
    }

    function test_Unpause_RevertsForNonOwner() public {
        vm.prank(owner);
        swap.pause();

        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.OnlyOwner.selector);
        swap.unpause();
    }

    function test_Spell_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.OnlyOwner.selector);
        swap.spell(address(0), "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DEBT-CEILING INVARIANT
    // ═══════════════════════════════════════════════════════════════════════

    function test_SwapToWstETH_RevertsOnDebtCeilingBreach() public {
        // We can't induce a real breach: overshooting the ceiling means draining
        // enough aEthwstETH from the (leveraged) vault to crash its Aave health
        // factor, which reverts before `_checkDebtCeiling` is reached.
        //
        // Instead, spoof `variableDebtEthWETH.balanceOf(VAULT)` so our contract
        // sees a low debt value. Aave's HF math uses `scaledBalanceOf` (different
        // calldata), so the mock doesn't affect its validation.
        uint256 supply = aEthWETH.balanceOf(VAULT);
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(supply + 1)
        );

        uint256 amountIn = 1 ether; // HF-safe on this vault (see happy-path test).
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        // post-swap supply = pre + amountIn (wei-exact, no mid-tx interest drift).
        uint256 expectedSupply = aEthWETH.balanceOf(VAULT) + amountIn;
        uint256 expectedDebt = supply + 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ATokenWstETHSwap.DebtCeilingBreached.selector, expectedSupply, expectedDebt)
        );
        swap.swapToWstETH(amountIn, 0);
    }

    function test_SwapToWstETH_PassesAndFailsAroundCeiling() public {
        // Use mocked debt to straddle the ceiling precisely. Same rationale as
        // `test_SwapToWstETH_RevertsOnDebtCeilingBreach` above.
        uint256 supply = aEthWETH.balanceOf(VAULT);
        uint256 amountIn = 1 ether;

        // Pass side: debt comfortably above post-swap supply → no breach.
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(supply + amountIn + 1 ether)
        );

        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);
        vm.prank(user);
        swap.swapToWstETH(amountIn, 0);

        // Revert side: mock debt so that any further supply increase crosses it.
        uint256 newSupply = aEthWETH.balanceOf(VAULT);
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(newSupply)
        );
        uint256 amountIn2 = 100; // tiny; premium=0 so no profit transfer dust issue.
        _fundUserWithAEthWETH(user, amountIn2);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn2);

        // Probe actual post-swap supply — Aave's ray-rounding drifts by 1 wei when
        // vault has non-zero pre-balance, so `newSupply + amountIn2` is not wei-exact.
        uint256 expectedSupply = _probePostSwapSupply(amountIn2);
        uint256 expectedDebt = newSupply;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ATokenWstETHSwap.DebtCeilingBreached.selector, expectedSupply, expectedDebt)
        );
        swap.swapToWstETH(amountIn2, 0);
    }

    function test_SwapToWstETH_ExactCeilingBoundary() public {
        // Pins the exact `supply >= debt` boundary in `_checkDebtCeiling`.
        // Catches regressions where `>=` is accidentally weakened to `>`.
        uint256 supply = aEthWETH.balanceOf(VAULT);
        uint256 amountIn = 1 ether;

        // Case 1: debt = post-swap supply + 1 → one wei below ceiling, swap passes.
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(supply + amountIn + 1)
        );
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);
        vm.prank(user);
        swap.swapToWstETH(amountIn, 0); // succeeds — strict `>` in invariant

        // Case 2: debt = post-swap supply exactly → equality reverts (supply >= debt).
        uint256 amountIn2 = 1 ether;

        // Seed a mock debt for the probe to read (probe helper captures + restores
        // this value, so it can be anything non-trivial that passes the probe's
        // own disabled-ceiling step).
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(type(uint256).max)
        );
        _fundUserWithAEthWETH(user, amountIn2);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn2);

        uint256 probeSupply = _probePostSwapSupply(amountIn2);

        // Pin debt == probeSupply so supply and debt are wei-equal at the check.
        vm.mockCall(
            address(variableDebtEthWETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(probeSupply)
        );

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ATokenWstETHSwap.DebtCeilingBreached.selector, probeSupply, probeSupply)
        );
        swap.swapToWstETH(amountIn2, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INSUFFICIENT LIQUIDITY — BOTH CODE PATHS
    // ═══════════════════════════════════════════════════════════════════════

    function test_SwapToWstETH_RevertsOnInsufficientAllowance() public {
        uint256 amountIn = 1 ether;
        uint256 rate = swap.getWstETHRate();
        uint256 fullAmount = (amountIn * 1e18) / rate;

        // Reduce the vault's allowance below fullAmount.
        uint256 smallAllowance = fullAmount - 1;
        vm.prank(VAULT);
        aEthwstETH.approve(address(swap), smallAllowance);

        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ATokenWstETHSwap.InsufficientLiquidity.selector, smallAllowance, fullAmount)
        );
        swap.swapToWstETH(amountIn, 0);
    }

    function test_SwapToWstETH_RevertsOnInsufficientBalance() public {
        uint256 amountIn = 1 ether;
        uint256 rate = swap.getWstETHRate();
        uint256 fullAmount = (amountIn * 1e18) / rate;

        // Can't use stdstore.find() for VAULT (nonzero initial balance + scaled-index
        // layout breaks the probe heuristic), and can't `vm.prank(VAULT)` a transfer
        // out — Aave's HF check blocks it on a leveraged position. Spoof balanceOf
        // with a mock instead. Allowance is still MAX from setUp.
        vm.mockCall(
            address(aEthwstETH),
            abi.encodeWithSelector(IERC20.balanceOf.selector, VAULT),
            abi.encode(uint256(0))
        );
        assertEq(aEthwstETH.balanceOf(VAULT), 0, "mock must stick");
        assertEq(aEthwstETH.allowance(VAULT, address(swap)), type(uint256).max, "allowance still MAX");

        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ATokenWstETHSwap.InsufficientLiquidity.selector, 0, fullAmount));
        swap.swapToWstETH(amountIn, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SwapWstETH EVENT
    // ═══════════════════════════════════════════════════════════════════════

    function test_SwapToWstETH_EmitsSwapWstETH_ZeroPremium() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);

        vm.expectEmit(true, false, false, true, address(swap));
        emit SwapWstETH(user, amountIn, expectedOut, 0);

        vm.prank(user);
        swap.swapToWstETH(amountIn, 0);
    }

    function test_SwapToWstETH_EmitsSwapWstETH_WithPremium() public {
        uint256 premium = 20_000;
        vm.prank(owner);
        swap.setPremium(premium);

        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);
        uint256 expectedProfit = swap.getWstETHProfit(amountIn);

        vm.expectEmit(true, false, false, true, address(swap));
        emit SwapWstETH(user, amountIn, expectedOut, expectedProfit);

        vm.prank(user);
        swap.swapToWstETH(amountIn, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // swapToWstETHWithReferral — extended coverage
    // ═══════════════════════════════════════════════════════════════════════

    function test_SwapToWstETHWithReferral_EmitsBothEvents() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);
        uint256 expectedProfit = swap.getWstETHProfit(amountIn);

        // Events must fire in order: SwapWstETH first (from inner swapToWstETH),
        // then ReferralRecorded (after the inner call returns).
        vm.expectEmit(true, false, false, true, address(swap));
        emit SwapWstETH(user, amountIn, expectedOut, expectedProfit);
        vm.expectEmit(true, true, false, true, address(swap));
        emit ReferralRecorded(user, referral, amountIn, expectedOut);

        vm.prank(user);
        swap.swapToWstETHWithReferral(amountIn, 0, referral);
    }

    function test_SwapToWstETHWithReferral_ZeroReferralAddress() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);

        vm.expectEmit(true, true, false, true, address(swap));
        emit ReferralRecorded(user, address(0), amountIn, expectedOut);

        vm.prank(user);
        swap.swapToWstETHWithReferral(amountIn, 0, address(0));
    }

    function test_SwapToWstETHWithReferral_ReturnsCorrectAmount() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETHWithReferral(amountIn, 0, referral);
        assertEq(amountOut, expectedOut);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function test_GetWstETHRateWithPremium_MatchesFormula() public {
        uint256 premium = 50_000;
        vm.prank(owner);
        swap.setPremium(premium);

        uint256 rate = swap.getWstETHRate();
        uint256 precision = swap.PREMIUM_PRECISION();
        uint256 expected = (rate * precision) / (precision - premium);
        assertEq(swap.getWstETHRateWithPremium(), expected);
    }

    function test_MaxSwapToWstETH_ClampedByDebtCeiling() public view {
        // Vault chosen so liquidity (converted to aEthWETH equivalent) exceeds the
        // debt-ceiling headroom — so max is bounded by the ceiling.
        uint256 liquidity = swap.availableWstETHLiquidity();
        uint256 rate = swap.getWstETHRate();
        uint256 maxByLiquidity = (liquidity * rate) / 1e18;
        uint256 maxByCeiling = swap.maxSwapFromDebtCeiling();
        assertLt(maxByCeiling, maxByLiquidity, "vault must be picked so ceiling < liquidity");
        assertEq(swap.maxSwapToWstETH(), maxByCeiling);
    }

    function test_MaxSwapToWstETH_ClampedByLiquidity() public {
        // Lower allowance far below debt-ceiling headroom.
        uint256 tinyAllowance = 1e6;
        vm.prank(VAULT);
        aEthwstETH.approve(address(swap), tinyAllowance);

        uint256 rate = swap.getWstETHRate();
        uint256 expectedMax = (tinyAllowance * rate) / 1e18;
        // Sanity: ceiling must be well above this, otherwise test premise is wrong.
        assertGt(swap.maxSwapFromDebtCeiling(), expectedMax, "ceiling should dominate");
        assertEq(swap.maxSwapToWstETH(), expectedMax);
    }

    function test_MaxSwapToWstETH_ZeroWhenNoLiquidity() public {
        vm.prank(VAULT);
        aEthwstETH.approve(address(swap), 0);
        assertEq(swap.maxSwapToWstETH(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PAUSE / UNPAUSE events + round-trip
    // ═══════════════════════════════════════════════════════════════════════

    function test_Pause_EmitsPausedEvent() public {
        vm.expectEmit(false, false, false, true, address(swap));
        emit Paused(owner);

        vm.prank(owner);
        swap.pause();
    }

    function test_Unpause_EmitsUnpausedEvent() public {
        vm.prank(owner);
        swap.pause();

        vm.expectEmit(false, false, false, true, address(swap));
        emit Unpaused(owner);

        vm.prank(owner);
        swap.unpause();
    }

    function test_PauseUnpause_RoundTrip() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        vm.prank(owner);
        swap.pause();

        vm.prank(user);
        vm.expectRevert(ATokenWstETHSwap.ContractPaused.selector);
        swap.swapToWstETH(amountIn, 0);

        vm.prank(owner);
        swap.unpause();

        vm.prank(user);
        swap.swapToWstETH(amountIn, 0); // succeeds
    }

    // ═══════════════════════════════════════════════════════════════════════
    // spell() — delegatecall happy path + revert propagation
    // ═══════════════════════════════════════════════════════════════════════

    function test_Spell_ExecutesDelegateCall() public {
        bytes memory data = abi.encodeWithSelector(swap.pause.selector);

        // `pause()` emits `Paused(msg.sender)`. Delegatecall preserves msg.sender from
        // the calling frame (spell's frame, where msg.sender == owner), so the event
        // account should be `owner` — NOT address(swap). This proves two things at once:
        //  • delegatecall ran pause()'s code against this contract's storage (paused flag flips)
        //  • msg.sender was preserved through the delegatecall frame
        vm.expectEmit(false, false, false, true, address(swap));
        emit Paused(owner);

        vm.prank(owner);
        swap.spell(address(swap), data);

        assertTrue(swap.paused(), "delegatecalled pause() did not flip storage");
    }

    function test_Spell_PropagatesRevertData() public {
        uint256 tooHigh = swap.MAX_PREMIUM() + 1;
        bytes memory data = abi.encodeWithSelector(ATokenWstETHSwap.setPremium.selector, tooHigh);

        vm.prank(owner);
        vm.expectRevert(ATokenWstETHSwap.PremiumTooHigh.selector);
        swap.spell(address(swap), data);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PREMIUM BOUNDARIES
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetPremium_AtMaxPremium_Succeeds() public {
        uint256 maxPremium = swap.MAX_PREMIUM();
        vm.prank(owner);
        swap.setPremium(maxPremium);
        assertEq(swap.premium(), maxPremium);
    }

    function test_SetPremium_AboveMaxPremium_Reverts() public {
        uint256 justAbove = swap.MAX_PREMIUM() + 1;
        vm.prank(owner);
        vm.expectRevert(ATokenWstETHSwap.PremiumTooHigh.selector);
        swap.setPremium(justAbove);
    }

    function test_Constructor_AcceptsMaxPremium() public {
        uint256 maxPremium = swap.MAX_PREMIUM();
        ATokenWstETHSwap fresh = new ATokenWstETHSwap(owner, VAULT, profitReceiver, maxPremium);
        assertEq(fresh.premium(), maxPremium);
    }

    function test_Constructor_RevertsAboveMaxPremium() public {
        uint256 justAbove = swap.MAX_PREMIUM() + 1;
        vm.expectRevert(ATokenWstETHSwap.PremiumTooHigh.selector);
        new ATokenWstETHSwap(owner, VAULT, profitReceiver, justAbove);
    }

    function test_SwapToWstETH_AtMaxPremium_SplitMatchesFormula() public {
        uint256 maxPremium = swap.MAX_PREMIUM(); // 10%
        vm.prank(owner);
        swap.setPremium(maxPremium);

        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 rate = swap.getWstETHRate();
        uint256 precision = swap.PREMIUM_PRECISION();
        uint256 expectedOut = (amountIn * (precision - maxPremium) / precision) * 1e18 / rate;
        uint256 expectedFull = (amountIn * 1e18) / rate;
        uint256 expectedProfit = expectedFull - expectedOut;

        uint256 profitReceiverBefore = aEthwstETH.balanceOf(profitReceiver);
        uint256 userBefore = aEthwstETH.balanceOf(user);
        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, 0);
        // Exact equality: the formula above is algebraically identical to the
        // contract's amountOut computation (same operand order, same rounding).
        // If the contract's arithmetic changes, this assertion must update.
        assertEq(amountOut, expectedOut, "amountOut mismatch at MAX_PREMIUM");

        // User gets 90%, profitReceiver gets 10% (within 1 wei drift on each leg).
        assertApproxEqAbs(aEthwstETH.balanceOf(user), userBefore + expectedOut, 2, "user leg");
        assertApproxEqAbs(
            aEthwstETH.balanceOf(profitReceiver) - profitReceiverBefore,
            expectedProfit,
            2,
            "profit leg"
        );
    }

    function test_SetPremium_EmitsOldAndNewCorrectly() public {
        vm.prank(owner);
        swap.setPremium(10_000);

        vm.expectEmit(false, false, false, true, address(swap));
        emit PremiumUpdated(10_000, 30_000);

        vm.prank(owner);
        swap.setPremium(30_000);
        assertEq(swap.premium(), 30_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Premium = 0 ⇒ profit = 0
    // ═══════════════════════════════════════════════════════════════════════

    function test_Premium0_ProducesZeroProfit() public view {
        assertEq(swap.premium(), 0, "setUp leaves premium at 0");
        uint256[4] memory amounts = [uint256(1e6), uint256(1e12), uint256(1 ether), uint256(100 ether)];
        for (uint256 i = 0; i < amounts.length; i++) {
            // If this fails by 1 wei for some input, see AUDIT_SCOPE §5.1 (rounding inconsistency).
            assertEq(swap.getWstETHProfit(amounts[i]), 0, "profit must be exactly 0 at premium=0");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Allowance depletion flow
    // ═══════════════════════════════════════════════════════════════════════

    function test_NonMaxAllowance_DepletesAfterSwap() public {
        uint256 amountIn = 1 ether;
        uint256 rate = swap.getWstETHRate();
        uint256 fullAmount = (amountIn * 1e18) / rate;

        assertEq(swap.premium(), 0, "test assumes zero premium (setUp default)");

        // Approve exactly enough for one swap at premium=0 (fullAmount == amountOut).
        vm.prank(VAULT);
        aEthwstETH.approve(address(swap), fullAmount);

        _fundUserWithAEthWETH(user, amountIn * 2);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn * 2);

        vm.prank(user);
        swap.swapToWstETH(amountIn, 0); // consumes the allowance

        // Second identical swap reverts — allowance fully depleted.
        vm.prank(user);
        vm.expectPartialRevert(ATokenWstETHSwap.InsufficientLiquidity.selector);
        swap.swapToWstETH(amountIn, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Fuzz — preview consistency
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_GetWstETHAmountOut_MatchesActualSwap(uint256 amountIn, uint256 premium) public {
        // Bound amountIn to a range that clears both real-world constraints:
        //   • Upper 1 ether — known HF-safe on this vault (happy-path test passes).
        //   • Lower 1e15 (0.001 ETH) — ensures the premium-profit transfer doesn't
        //     round to 0 scaled units inside Aave's aToken.transferFrom, which
        //     reverts tiny transfers. At 0.001 ETH * 1 premium, profit is
        //     ≈ 8e8 wei balanceOf — well above any ray-div rounding threshold.
        // This narrower range still exercises the preview-vs-actual equivalence;
        // the debt-ceiling headroom isn't the binding constraint here.
        amountIn = bound(amountIn, 1e15, 1 ether);
        premium = bound(premium, 0, swap.MAX_PREMIUM());

        vm.prank(owner);
        swap.setPremium(premium);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);

        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, 0);
        assertEq(amountOut, expectedOut);
    }

    function testFuzz_AtMaxPremium_PreviewMatchesActual(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 1 ether);
        uint256 maxPremium = swap.MAX_PREMIUM();
        vm.prank(owner);
        swap.setPremium(maxPremium);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);

        _fundUserWithAEthWETH(user, amountIn);
        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, 0);
        assertEq(amountOut, expectedOut);
    }
}
