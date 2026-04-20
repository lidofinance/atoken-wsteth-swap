// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";

/// @title ATokenWstETHSwap
/// @notice Enables swapping aEthWETH for aEthwstETH at the current WstETH.stEthPerToken() rate
///         with a configurable premium.
/// @dev The `vault` pre-approves this contract to spend its aEthwstETH. Users approve
///      this contract to spend their aEthWETH, then call swap functions. Premium profit
///      is paid in aEthwstETH to `profitReceiver`.
///
///      `vault` here refers to the address that holds the leveraged Aave V3 position
///      (aEthwstETH collateral + variableDebtEthWETH debt). In a Mellow Core Vaults
///      deployment this is typically the Subvault address.
///
///      Based on Fluid's FluidATokenSwap contract deployed at
///      0x4f8f03cad7512e4f6d1050fb9b2f8b91ae4bc901.
contract ATokenWstETHSwap {
    // ─── Constants ───────────────────────────────────────────────────────
    uint256 public constant MAX_PREMIUM = 1e5; // 1e5 = 10%
    uint256 public constant PREMIUM_PRECISION = 1e6; // 1e6 = 100%

    IERC20 public constant aEthWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);
    IERC20 public constant aEthwstETH = IERC20(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);

    IWstETH public constant wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    IERC20 public constant variableDebtEthWETH = IERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    address public immutable owner;
    address public immutable vault;
    address public immutable profitReceiver;

    // ─── State ───────────────────────────────────────────────────────────
    uint256 public premium; // 6 decimals: 20000 = 2%
    bool public paused;

    // ─── Events ──────────────────────────────────────────────────────────
    event SwapWstETH(address indexed user, uint256 aEthWETHIn, uint256 aEthwstETHOut, uint256 profit);
    event PremiumUpdated(uint256 oldPremium, uint256 newPremium);
    event Paused(address account);
    event Unpaused(address account);
    event ReferralRecorded(address indexed user, address indexed referral, uint256 aEthWETHIn, uint256 aEthwstETHOut);

    // ─── Errors ──────────────────────────────────────────────────────────
    error OnlyOwner();
    error ContractPaused();
    error ZeroAmount();
    error ZeroAddress();
    error PremiumTooHigh();
    error InsufficientLiquidity(uint256 available, uint256 required);
    error TransferFailed();
    error DebtCeilingBreached(uint256 aEthWETHBalance, uint256 debtBalance);
    error SlippageExceeded(uint256 amountOut, uint256 amountOutMin);

    // ─── Modifiers ───────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────
    constructor(address _owner, address _vault, address _profitReceiver, uint256 _premium) {
        if (_owner == address(0) || _vault == address(0) || _profitReceiver == address(0)) {
            revert ZeroAddress();
        }
        owner = _owner;
        vault = _vault;
        profitReceiver = _profitReceiver;

        if (_premium > MAX_PREMIUM) revert PremiumTooHigh();
        premium = _premium;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Same as `swapToWstETH`, plus emits a `ReferralRecorded` event tying the
    ///         swap to the given referral address. The referral has no on-chain effect;
    ///         it is emitted purely for off-chain attribution.
    /// @param amountIn Amount of aEthWETH to swap (18 decimals).
    /// @param amountOutMin Minimum aEthwstETH to receive; reverts if output is less.
    /// @param referral Referral tag, emitted in `ReferralRecorded` for tracking.
    /// @return amountOut Amount of aEthwstETH received by user.
    function swapToWstETHWithReferral(uint256 amountIn, uint256 amountOutMin, address referral)
        external
        returns (uint256 amountOut)
    {
        amountOut = swapToWstETH(amountIn, amountOutMin);
        emit ReferralRecorded(msg.sender, referral, amountIn, amountOut);
    }

    /// @notice Swap aEthWETH for aEthwstETH. Premium profit is sent to profitReceiver.
    /// @param amountIn Amount of aEthWETH to swap (18 decimals).
    /// @param amountOutMin Minimum aEthwstETH to receive; reverts if output is less (slippage protection).
    /// @return amountOut Amount of aEthwstETH received by user.
    function swapToWstETH(uint256 amountIn, uint256 amountOutMin) public whenNotPaused returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        uint256 rate = wstETH.stEthPerToken();
        uint256 fullAmount = (amountIn * 1e18) / rate;
        uint256 effectiveInput = (amountIn * (PREMIUM_PRECISION - premium)) / PREMIUM_PRECISION;
        amountOut = (effectiveInput * 1e18) / rate;
        if (amountOut < amountOutMin) revert SlippageExceeded(amountOut, amountOutMin);
        uint256 profit = fullAmount - amountOut;

        uint256 available = aEthwstETH.allowance(vault, address(this));
        if (available < fullAmount) revert InsufficientLiquidity(available, fullAmount);

        uint256 vaultBalance = aEthwstETH.balanceOf(vault);
        if (vaultBalance < fullAmount) revert InsufficientLiquidity(vaultBalance, fullAmount);

        if (!aEthWETH.transferFrom(msg.sender, vault, amountIn)) revert TransferFailed();
        if (!aEthwstETH.transferFrom(vault, msg.sender, amountOut)) revert TransferFailed();
        if (profit > 0) {
            if (!aEthwstETH.transferFrom(vault, profitReceiver, profit)) revert TransferFailed();
        }

        _checkDebtCeiling();

        emit SwapWstETH(msg.sender, amountIn, amountOut, profit);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW / READ FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Calculate how much aEthwstETH a user receives for a given aEthWETH input.
    function getWstETHAmountOut(uint256 amountIn) public view returns (uint256) {
        uint256 rate = wstETH.stEthPerToken();
        uint256 effectiveInput = (amountIn * (PREMIUM_PRECISION - premium)) / PREMIUM_PRECISION;
        return (effectiveInput * 1e18) / rate;
    }

    /// @notice Premium profit in aEthwstETH for a given aEthWETH input.
    function getWstETHProfit(uint256 amountIn) public view returns (uint256) {
        uint256 rate = wstETH.stEthPerToken();
        uint256 fullAmount = (amountIn * 1e18) / rate;
        return fullAmount - getWstETHAmountOut(amountIn);
    }

    /// @notice Current wstETH.stEthPerToken() rate (stETH per 1 wstETH, 18 decimals).
    function getWstETHRate() external view returns (uint256) {
        return wstETH.stEthPerToken();
    }

    /// @notice Effective wstETH rate after premium: how much aEthWETH per 1 aEthwstETH a user pays.
    /// @dev rate * PREMIUM_PRECISION / (PREMIUM_PRECISION - premium). Higher than the raw oracle
    ///      rate due to the premium charged on top.
    function getWstETHRateWithPremium() external view returns (uint256) {
        uint256 rate = wstETH.stEthPerToken();
        return (rate * PREMIUM_PRECISION) / (PREMIUM_PRECISION - premium);
    }

    /// @notice Available aEthwstETH liquidity in the vault (minimum of balance and allowance).
    /// @dev Does NOT account for the debt-ceiling invariant. For a max swap value that reflects
    ///      ALL constraints, use `maxSwapToWstETH`.
    function availableWstETHLiquidity() external view returns (uint256) {
        uint256 balance = aEthwstETH.balanceOf(vault);
        uint256 allowance = aEthwstETH.allowance(vault, address(this));
        return balance < allowance ? balance : allowance;
    }

    /// @notice Maximum aEthWETH input permitted by the debt-ceiling invariant.
    /// @dev `_checkDebtCeiling` reverts if, after the swap, the vault's aEthWETH balance is
    ///      greater than or equal to its WETH variable debt. The cap is therefore
    ///      `debt - supply - 1`, or 0 if the vault is already at/over the ceiling.
    ///      Note: both `balanceOf` values accrue interest between calls, so this should be treated
    ///      as an upper bound only; leave a small buffer when using as a UI input.
    function maxSwapFromDebtCeiling() public view returns (uint256) {
        uint256 supply = aEthWETH.balanceOf(vault);
        uint256 debt = variableDebtEthWETH.balanceOf(vault);
        if (debt <= supply) return 0;
        unchecked {
            return debt - supply - 1;
        }
    }

    /// @notice Maximum aEthWETH a user can swap for aEthwstETH, considering both vault liquidity
    ///         and the debt-ceiling invariant enforced by `_checkDebtCeiling`.
    function maxSwapToWstETH() external view returns (uint256) {
        uint256 liquidity = _minOf(aEthwstETH.balanceOf(vault), aEthwstETH.allowance(vault, address(this)));
        if (liquidity == 0) return 0;
        uint256 rate = wstETH.stEthPerToken();
        uint256 maxByLiquidity = (liquidity * rate) / 1e18;
        return _minOf(maxByLiquidity, maxSwapFromDebtCeiling());
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update the premium charged on swaps.
    /// @param _premium New premium in 6-decimal format (e.g. 20000 = 2%).
    function setPremium(uint256 _premium) external onlyOwner {
        if (_premium > MAX_PREMIUM) revert PremiumTooHigh();
        emit PremiumUpdated(premium, _premium);
        premium = _premium;
    }

    /// @notice Pause all swaps.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause swaps.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Owner-only escape hatch via delegatecall. Emergency use only — not part of
    ///         normal operation.
    ///
    /// @dev Owner has god-mode privileges via this function: can drain the vault's approved
    ///      allowance, overwrite any storage, bypass every invariant. Owning this contract
    ///      is equivalent to custody of the vault's approved aEthwstETH allowance.
    ///
    ///      Intended strictly for emergency corrective actions (e.g., rescuing mis-sent
    ///      tokens, recovering from unforeseen state). Must not be used in routine flows;
    ///      every call should be publicly justified and auditable.
    ///
    ///      Choose the owner accordingly: multisig or timelock-gated governance, should never be an EOA
    ///      in production.
    /// @param target_ Address to delegatecall.
    /// @param data_   Calldata to forward.
    function spell(address target_, bytes memory data_) public onlyOwner returns (bytes memory response_) {
        assembly {
            let succeeded := delegatecall(gas(), target_, add(data_, 0x20), mload(data_), 0, 0)
            let size := returndatasize()

            response_ := mload(0x40)
            mstore(0x40, add(response_, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            mstore(response_, size)
            returndatacopy(add(response_, 0x20), 0, size)

            switch iszero(succeeded)
            case 1 {
                returndatacopy(0x00, 0x00, size)
                revert(0x00, size)
            }
        }
    }

    // ─── Internal helpers ────────────────────────────────────────────────

    /// @dev Reverts if vault's aEthWETH balance >= its WETH debt.
    function _checkDebtCeiling() internal view {
        uint256 supply = aEthWETH.balanceOf(vault);
        uint256 debt = variableDebtEthWETH.balanceOf(vault);
        if (supply >= debt) revert DebtCeilingBreached(supply, debt);
    }

    function _minOf(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
