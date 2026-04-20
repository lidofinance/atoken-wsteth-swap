// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {LidoATokenSwap} from "../src/LidoATokenSwap.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWstETH} from "../src/interfaces/IWstETH.sol";

/// @notice Integration tests for LidoATokenSwap against a mainnet fork.
/// @dev Requires the `mainnet` RPC endpoint (set via the MAINNET_RPC_URL env var).
contract LidoATokenSwapIntegrationTest is Test {
    using stdStorage for StdStorage;

    // ─── Mainnet addresses ───────────────────────────────────────────────
    address constant MELLOW_VAULT = 0x893aa69FBAA1ee81B536f0FbE3A3453e86290080;

    IERC20 constant aEthWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);
    IERC20 constant aEthwstETH = IERC20(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);
    IWstETH constant wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 constant variableDebtEthWETH = IERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    // ─── Test actors ─────────────────────────────────────────────────────
    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address user = makeAddr("user");
    address referral = makeAddr("referral");

    LidoATokenSwap swap;

    function setUp() public {
        // Pin to a recent block so the vault's on-chain balances (used in assertions) are deterministic.
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24921000);

        LidoATokenSwap impl = new LidoATokenSwap(owner, MELLOW_VAULT, feeRecipient);

        bytes memory initData = abi.encodeWithSelector(LidoATokenSwap.initialize.selector);

        // OssifiableProxy is pinned to solc 0.8.9, so it can't be imported alongside the
        // 0.8.20 contracts under test. `vm.deployCode` loads the precompiled artifact and
        // deploys it at runtime — the prank ensures `msg.sender` inside `initialize`
        // (delegatecalled from the proxy constructor) is the immutable OWNER.
        bytes memory proxyArgs = abi.encode(address(impl), owner, initData);
        vm.prank(owner);
        address proxyAddr = deployCode("OssifiableProxy.sol:OssifiableProxy", proxyArgs);

        swap = LidoATokenSwap(proxyAddr);

        // Sanity: proxy initialized and starts paused.
        assertTrue(swap.isPaused(), "expected paused after initialize");
        assertEq(swap.getFee(), 0, "fee should start at 0");

        vm.prank(owner);
        swap.unpause();

        // Mellow vault must pre-approve the swap contract to spend its aEthwstETH.
        vm.prank(MELLOW_VAULT);
        aEthwstETH.approve(address(swap), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _fundUserWithAEthWETH(address to, uint256 amount) internal {
        // Aave's aToken `balanceOf` is `scaledBalance * liquidityIndex / 1e27`,
        // so forge's `deal` post-write check fails. We locate the scaled-balance slot
        // and write it directly, sized to yield at least `amount` of balanceOf.
        uint256 slot = stdstore.target(address(aEthWETH)).sig("balanceOf(address)").with_key(to).find();
        // Write `amount` to the scaled-balance slot. Since liquidityIndex >= 1e27,
        // this yields balanceOf >= amount.
        vm.store(address(aEthWETH), bytes32(slot), bytes32(amount));
        require(aEthWETH.balanceOf(to) >= amount, "funding produced insufficient aEthWETH");
    }

    // ─── Tests ───────────────────────────────────────────────────────────

    function test_Setup_InitialState() public view {
        assertEq(swap.OWNER(), owner);
        assertEq(swap.MELLOW_VAULT(), MELLOW_VAULT);
        assertEq(swap.FEE_RECIPIENT(), feeRecipient);
        assertFalse(swap.isPaused());
    }

    function test_Initialize_RevertsWhenReinitialized() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LidoATokenSwap.UnexpectedVersion.selector, 1));
        swap.initialize();
    }

    function test_SwapToWstETH_ZeroFee_HappyPath() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 rate = swap.getWstETHRate();
        uint256 expectedOut = (amountIn * 1e18) / rate;
        assertEq(swap.getWstETHAmountOut(amountIn), expectedOut, "preview mismatch");

        uint256 userAEthWETHBefore = aEthWETH.balanceOf(user);
        uint256 userWstBefore = aEthwstETH.balanceOf(user);
        uint256 vaultAEthWETHBefore = aEthWETH.balanceOf(MELLOW_VAULT);
        uint256 vaultWstBefore = aEthwstETH.balanceOf(MELLOW_VAULT);
        uint256 feeRecipientWstBefore = aEthwstETH.balanceOf(feeRecipient);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, expectedOut, referral);

        assertEq(amountOut, expectedOut, "amountOut mismatch");

        // aToken balances accrue interest between calls; tolerate small drift.
        assertApproxEqAbs(aEthWETH.balanceOf(user), userAEthWETHBefore - amountIn, 2, "user aEthWETH");
        assertApproxEqAbs(aEthwstETH.balanceOf(user), userWstBefore + amountOut, 2, "user aEthwstETH");
        assertApproxEqAbs(aEthWETH.balanceOf(MELLOW_VAULT), vaultAEthWETHBefore + amountIn, 2, "vault aEthWETH +input");
        assertApproxEqAbs(aEthwstETH.balanceOf(MELLOW_VAULT), vaultWstBefore - amountOut, 2, "vault aEthwstETH -output");
        assertEq(aEthwstETH.balanceOf(feeRecipient), feeRecipientWstBefore, "fee recipient should be untouched at 0 fee");
    }

    function test_SwapToWstETH_WithFee_DistributesFee() public {
        uint256 feeBps = 200; // 2%
        vm.prank(owner);
        swap.setFee(feeBps);

        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 rate = swap.getWstETHRate();
        uint256 feeInInput = (amountIn * feeBps) / swap.FEE_BASIS();
        uint256 expectedOut = ((amountIn - feeInInput) * 1e18) / rate;
        uint256 expectedFeeOut = (feeInInput * 1e18) / rate;

        assertEq(swap.getWstETHAmountOut(amountIn), expectedOut);
        assertEq(swap.getWstETHFeeInOutput(amountIn), expectedFeeOut);

        uint256 feeRecipientBefore = aEthwstETH.balanceOf(feeRecipient);
        uint256 userWstBefore = aEthwstETH.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = swap.swapToWstETH(amountIn, expectedOut, referral);

        assertEq(amountOut, expectedOut);
        assertApproxEqAbs(aEthwstETH.balanceOf(user), userWstBefore + expectedOut, 2);
        assertApproxEqAbs(aEthwstETH.balanceOf(feeRecipient), feeRecipientBefore + expectedFeeOut, 2);
    }

    function test_SwapToWstETH_RevertsOnSlippage() public {
        uint256 amountIn = 1 ether;
        _fundUserWithAEthWETH(user, amountIn);

        vm.prank(user);
        aEthWETH.approve(address(swap), amountIn);

        uint256 expectedOut = swap.getWstETHAmountOut(amountIn);
        uint256 amountOutMin = expectedOut + 1;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LidoATokenSwap.SlippageExceeded.selector, expectedOut, amountOutMin));
        swap.swapToWstETH(amountIn, amountOutMin, referral);
    }

    function test_SwapToWstETH_RevertsWhenPaused() public {
        vm.prank(owner);
        swap.pause();

        vm.prank(user);
        vm.expectRevert(LidoATokenSwap.ContractPaused.selector);
        swap.swapToWstETH(1 ether, 0, referral);
    }

    function test_SwapToWstETH_RevertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(LidoATokenSwap.ZeroAmount.selector);
        swap.swapToWstETH(0, 0, referral);
    }

    function test_AvailableWstETHLiquidity_MatchesMinOfBalanceAndAllowance() public view {
        uint256 liquidity = swap.availableWstETHLiquidity();
        uint256 bal = aEthwstETH.balanceOf(MELLOW_VAULT);
        uint256 allowance = aEthwstETH.allowance(MELLOW_VAULT, address(swap));
        uint256 expected = bal < allowance ? bal : allowance;
        assertEq(liquidity, expected);
    }

    function test_MaxSwapFromDebtCeiling_IsPositive() public view {
        uint256 supply = aEthWETH.balanceOf(MELLOW_VAULT);
        uint256 debt = variableDebtEthWETH.balanceOf(MELLOW_VAULT);
        // This vault was picked specifically because debt > supply.
        assertGt(debt, supply, "vault is expected to be leveraged (debt > supply)");
        assertGt(swap.maxSwapFromDebtCeiling(), 0);
    }

    function test_SetFee_RevertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(LidoATokenSwap.OnlyOwner.selector);
        swap.setFee(100);
    }

    function test_SetFee_RevertsAboveMax() public {
        uint256 tooHigh = swap.MAX_FEE() + 1;
        vm.prank(owner);
        vm.expectRevert(LidoATokenSwap.FeeTooHigh.selector);
        swap.setFee(tooHigh);
    }
}
