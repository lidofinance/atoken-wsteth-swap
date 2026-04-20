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
    event ReferralRecorded(address indexed user, address indexed referral);
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

    function test_Constructor_RevertsOnPremiumAtOrAboveMax() public {
        uint256 tooHigh = swap.PREMIUM_PRECISION();
        vm.expectRevert(ATokenWstETHSwap.PremiumTooHigh.selector);
        new ATokenWstETHSwap(owner, VAULT, profitReceiver, tooHigh);
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

        // Expect the referral event with both topics matching.
        vm.expectEmit(true, true, false, false, address(swap));
        emit ReferralRecorded(user, referral);

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

    function test_SetPremium_RevertsAtOrAboveMax() public {
        uint256 tooHigh = swap.PREMIUM_PRECISION();
        vm.prank(owner);
        vm.expectRevert(ATokenWstETHSwap.PremiumTooHigh.selector);
        swap.setPremium(tooHigh);
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
}
