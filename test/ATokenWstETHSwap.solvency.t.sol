// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, stdStorage, StdStorage, console2} from "forge-std/Test.sol";
import {ATokenWstETHSwap} from "../src/ATokenWstETHSwap.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Minimal Aave V3 Pool interface for repay-with-aTokens + HF read.
interface IAavePool {
    function repayWithATokens(address asset, uint256 amount, uint256 interestRateMode) external returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

/// @notice End-to-end solvency proof for ATokenWstETHSwap.
/// @dev Runs a full de-leveraging loop on a mainnet fork with no mocks:
///      each iteration, a user swaps aEthWETH → aEthwstETH, then the vault
///      (as operator) repays its WETH debt directly with the aEthWETH it
///      just received, via Aave's `repayWithATokens`. This sidesteps
///      underlying-WETH-liquidity constraints entirely — no interaction
///      with `virtualUnderlyingBalance`, so the test works regardless of
///      the WETH reserve's utilization.
contract ATokenWstETHSwapSolvencyTest is Test {
    using stdStorage for StdStorage;

    // ─── Mainnet addresses ───────────────────────────────────────────────
    address constant VAULT = 0x893aa69FBAA1ee81B536f0FbE3A3453e86290080;
    IAavePool constant AAVE_POOL = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IERC20 constant aEthWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);
    IERC20 constant aEthwstETH = IERC20(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);
    IERC20 constant variableDebtEthWETH = IERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    // ─── Actors ──────────────────────────────────────────────────────────
    address owner = makeAddr("owner");
    address profitReceiver = makeAddr("profitReceiver");
    address user = makeAddr("user");

    ATokenWstETHSwap swap;

    // ─── Tunables ────────────────────────────────────────────────────────
    // 95 × 1% = 95% unwind. Safe upper bound: at iter N, supply-after-swap=chunk,
    // debt=debtStart*(1-(N-1)/100); `_checkDebtCeiling` reverts at N≥100.
    uint256 constant ITERATIONS = 95;
    uint256 constant HF_SAFETY_THRESHOLD = 1.05e18;
    uint256 constant VARIABLE_RATE_MODE = 2;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24921000);

        swap = new ATokenWstETHSwap(owner, VAULT, profitReceiver, 0);

        vm.prank(VAULT);
        aEthwstETH.approve(address(swap), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev Duplicate of the integration-test helper — this file stands alone.
    function _fundUserWithAEthWETH(address to, uint256 amount) internal {
        uint256 slot = stdstore.target(address(aEthWETH)).sig("balanceOf(address)").with_key(to).find();
        vm.store(address(aEthWETH), bytes32(slot), bytes32(amount));
        require(aEthWETH.balanceOf(to) >= amount, "funding produced insufficient aEthWETH");
    }

    function _healthFactor() internal view returns (uint256 hf) {
        (,,,,, hf) = AAVE_POOL.getUserAccountData(VAULT);
    }

    // ─── The solvency test ───────────────────────────────────────────────

    function test_Solvency_UnwindViaRepeatedSwapAndRepay() public {
        uint256 debtStart = variableDebtEthWETH.balanceOf(VAULT);
        uint256 collatStart = aEthwstETH.balanceOf(VAULT);
        uint256 supplyStart = aEthWETH.balanceOf(VAULT);

        assertGt(debtStart, supplyStart, "vault must be leveraged (debt > supply)");
        assertEq(supplyStart, 0, "vault should hold no aEthWETH at start (pure leveraged loop)");
        assertGt(collatStart, 0, "vault should hold wstETH collateral");

        uint256 hfStart = _healthFactor();
        console2.log("=== Solvency unwind: start ===");
        console2.log("  debtStart   =", debtStart);
        console2.log("  collatStart =", collatStart);
        console2.log("  hfStart     =", hfStart);

        uint256 chunk = debtStart / 100; // ≈1% of position per iteration → ≈10% total unwind
        require(chunk > 1e15, "computed chunk is implausibly small");

        uint256 totalRepaid;
        for (uint256 i = 0; i < ITERATIONS; i++) {
            uint256 debtBefore = variableDebtEthWETH.balanceOf(VAULT);
            uint256 collatBefore = aEthwstETH.balanceOf(VAULT);

            // 1) User swap: aEthWETH → aEthwstETH, routed through the swap contract.
            _fundUserWithAEthWETH(user, chunk);
            vm.prank(user);
            aEthWETH.approve(address(swap), chunk);
            vm.prank(user);
            swap.swapToWstETH(chunk, 0);

            // 2) Vault operator flow: repay WETH debt directly with aEthWETH.
            //    `repayWithATokens(asset, max, rateMode)` burns the caller's aTokens
            //    and reduces their debt by the same balanceOf amount in one shot.
            //    `type(uint256).max` tells Aave to clamp to min(aToken balance, debt).
            uint256 aEthWETHHeld = aEthWETH.balanceOf(VAULT);
            require(aEthWETHHeld > 0, "vault received no aEthWETH from swap");

            vm.prank(VAULT);
            uint256 repaid = AAVE_POOL.repayWithATokens(WETH, type(uint256).max, VARIABLE_RATE_MODE);

            // 3) Post-iteration assertions.
            uint256 debtAfter = variableDebtEthWETH.balanceOf(VAULT);
            uint256 collatAfter = aEthwstETH.balanceOf(VAULT);
            uint256 vaultAEthWETH = aEthWETH.balanceOf(VAULT);

            assertLt(debtAfter, debtBefore, "debt did not strictly decrease");
            assertLt(collatAfter, collatBefore, "collateral did not strictly decrease");
            assertApproxEqAbs(debtBefore - debtAfter, chunk, 5, "debt delta != chunk");
            assertApproxEqAbs(repaid, chunk, 5, "repayWithATokens return != chunk");
            assertLe(vaultAEthWETH, 10, "residual vault aEthWETH above rounding tolerance");

            uint256 hfNow = _healthFactor();
            console2.log("iter", i);
            console2.log("  debtDelta =", debtBefore - debtAfter);
            console2.log("  hfNow     =", hfNow);
            assertGe(hfNow, HF_SAFETY_THRESHOLD, "HF dropped below safety threshold - chunk too aggressive");

            totalRepaid += (debtBefore - debtAfter);
        }

        uint256 debtEnd = variableDebtEthWETH.balanceOf(VAULT);
        uint256 collatEnd = aEthwstETH.balanceOf(VAULT);
        uint256 hfEnd = _healthFactor();

        console2.log("=== Solvency unwind: end ===");
        console2.log("  debtEnd     =", debtEnd);
        console2.log("  collatEnd   =", collatEnd);
        console2.log("  totalRepaid =", totalRepaid);
        console2.log("  hfEnd       =", hfEnd);

        assertLt(debtEnd, (debtStart * 95) / 100, "unwind did not reduce debt by >=5%");
        assertLt(collatEnd, collatStart, "collateral did not monotonically reduce");
        assertApproxEqRel(totalRepaid, chunk * ITERATIONS, 0.02e18);
        assertGe(hfEnd, HF_SAFETY_THRESHOLD, "final HF below safety threshold");
    }
}
