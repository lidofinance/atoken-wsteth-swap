// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";

/// @title LidoATokenSwap
/// @notice Enables swapping aEthWETH for aEthwstETH at an oracle-derived rate with a configurable fee.
/// @dev The Mellow Vault pre-approves this contract to spend aEthwstETH.
///      Users approve this contract to spend their aEthWETH, then call swap functions.
///      Fee profit is sent to FEE_RECIPIENT in the output aToken.
contract LidoATokenSwap {
    // ─── Constants ───────────────────────────────────────────────────────
    uint256 public constant FEE_BASIS = 100_00; // bps denominator: 10000 = 100%
    uint256 public constant MAX_FEE = 10_00; // 10% hard cap

    IERC20 public constant aEthWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);
    IERC20 public constant aEthwstETH = IERC20(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);
    IWstETH public constant wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 public constant variableDebtEthWETH = IERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    // ─── Immutables ──────────────────────────────────────────────────────
    address public immutable OWNER;
    address public immutable MELLOW_VAULT;
    address public immutable FEE_RECIPIENT;

    // ─── ERC-7201 Storage ────────────────────────────────────────────────
    /// @custom:storage-location erc7201:Lido.LidoATokenSwap
    struct LidoATokenSwapStorage {
        uint256 fee;
        bool isPaused;
        uint256 version;
    }

    // keccak256(abi.encode(uint256(keccak256("Lido.LidoATokenSwap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0xebcea56cf5334166150c8a0fd8364b175dd114e01ddd7e3eb539173d07fdb300; // TODO

    // ─── Events ──────────────────────────────────────────────────────────
    event SwapWstETH(
        address indexed user, address indexed referral, uint256 amountIn, uint256 amountOut, uint256 fee, uint256 rate
    );
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event Paused(address account);
    event Unpaused(address account);
    event Initialized(uint256 version);

    // ─── Errors ──────────────────────────────────────────────────────────
    error OnlyOwner();
    error ContractPaused();
    error ZeroAmount();
    error ZeroAddress();
    error FeeTooHigh();
    error InsufficientLiquidity(uint256 available, uint256 required);
    error TransferFailed();
    error DebtCeilingBreached(uint256 aEthWETHBalance, uint256 debtBalance);
    error SlippageExceeded(uint256 amountOut, uint256 amountOutMin);
    error UnexpectedVersion(uint256 currentVersion);

    // ─── Modifiers ───────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != OWNER) revert OnlyOwner();
        _;
    }

    modifier whenNotPaused() {
        if (_getStorage().isPaused) revert ContractPaused();
        _;
    }

    // ─── Constructor / Initializer ───────────────────────────────────────
    constructor(address owner_, address mellowVault_, address feeRecipient_) {
        if (owner_ == address(0) || mellowVault_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        OWNER = owner_;
        MELLOW_VAULT = mellowVault_;
        FEE_RECIPIENT = feeRecipient_;

        // Disable initializer on the implementation contract (proxy-safety).
        _getStorage().version = type(uint256).max;
    }

    function initialize() external onlyOwner {
        LidoATokenSwapStorage storage $ = _getStorage();
        if ($.version != 0) revert UnexpectedVersion($.version);

        $.version = 1;
        $.isPaused = true;

        emit Initialized(1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWAP FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function swapToWstETH(uint256 amountIn, uint256 amountOutMin, address referral)
        public
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        LidoATokenSwapStorage storage $ = _getStorage();

        uint256 rate = wstETH.stEthPerToken();
        uint256 feeInInput = (amountIn * $.fee) / FEE_BASIS;
        uint256 effectiveInput = amountIn - feeInInput;
        amountOut = (effectiveInput * 1e18) / rate;
        if (amountOut < amountOutMin) revert SlippageExceeded(amountOut, amountOutMin);

        uint256 feeInOutput = (feeInInput * 1e18) / rate;
        uint256 fullAmount = amountOut + feeInOutput;

        uint256 available = aEthwstETH.allowance(MELLOW_VAULT, address(this));
        if (available < fullAmount) revert InsufficientLiquidity(available, fullAmount);
        uint256 vaultBalance = aEthwstETH.balanceOf(MELLOW_VAULT);
        if (vaultBalance < fullAmount) revert InsufficientLiquidity(vaultBalance, fullAmount);

        if (!aEthWETH.transferFrom(msg.sender, MELLOW_VAULT, amountIn)) revert TransferFailed();
        if (!aEthwstETH.transferFrom(MELLOW_VAULT, msg.sender, amountOut)) revert TransferFailed();
        if (feeInOutput > 0) {
            if (!aEthwstETH.transferFrom(MELLOW_VAULT, FEE_RECIPIENT, feeInOutput)) revert TransferFailed();
        }

        _checkDebtCeiling();

        emit SwapWstETH(msg.sender, referral, amountIn, amountOut, feeInOutput, rate);
    }

    function swapToWstETH(uint256 amountIn, uint256 amountOutMin) external returns (uint256 amountOut) {
        amountOut = swapToWstETH(amountIn, amountOutMin, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW / READ FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function getFee() external view returns (uint256) {
        return _getStorage().fee;
    }

    function isPaused() external view returns (bool) {
        return _getStorage().isPaused;
    }

    function getWstETHAmountOut(uint256 amountIn) public view returns (uint256) {
        uint256 rate = wstETH.stEthPerToken();
        uint256 feeInInput = (amountIn * _getStorage().fee) / FEE_BASIS;
        return ((amountIn - feeInInput) * 1e18) / rate;
    }

    function getWstETHFeeInOutput(uint256 amountIn) public view returns (uint256) {
        uint256 feeInInput = (amountIn * _getStorage().fee) / FEE_BASIS;
        return (feeInInput * 1e18) / wstETH.stEthPerToken();
    }

    function getWstETHRate() external view returns (uint256) {
        return wstETH.stEthPerToken();
    }

    /// @notice Effective wstETH rate after fee: how much aEthWETH per 1 aEthwstETH a user pays.
    function getWstETHRateWithFee() external view returns (uint256) {
        uint256 rate = wstETH.stEthPerToken();
        return (rate * FEE_BASIS) / (FEE_BASIS - _getStorage().fee);
    }

    function availableWstETHLiquidity() external view returns (uint256) {
        uint256 balance = aEthwstETH.balanceOf(MELLOW_VAULT);
        uint256 allowance = aEthwstETH.allowance(MELLOW_VAULT, address(this));
        return balance < allowance ? balance : allowance;
    }

    /// @notice Upper bound on aEthWETH input permitted by the debt-ceiling invariant.
    /// @dev Revert condition of _checkDebtCeiling is `supply >= debt` after swap.
    ///      Both balances accrue interest between calls — treat as UI upper bound only,
    ///      leave a small buffer.
    function maxSwapFromDebtCeiling() public view returns (uint256) {
        uint256 supply = aEthWETH.balanceOf(MELLOW_VAULT);
        uint256 debt = variableDebtEthWETH.balanceOf(MELLOW_VAULT);
        if (debt <= supply) return 0;
        unchecked {
            return debt - supply - 1;
        }
    }

    function maxSwapToWstETH() external view returns (uint256) {
        uint256 liquidity =
            _minOf(aEthwstETH.balanceOf(MELLOW_VAULT), aEthwstETH.allowance(MELLOW_VAULT, address(this)));
        if (liquidity == 0) return 0;
        uint256 rate = wstETH.stEthPerToken();
        uint256 maxByLiquidity = (liquidity * rate) / 1e18;
        return _minOf(maxByLiquidity, maxSwapFromDebtCeiling());
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Update the fee charged on swaps. bps: 200 = 2%.
    function setFee(uint256 fee) external onlyOwner {
        if (fee > MAX_FEE) revert FeeTooHigh();
        LidoATokenSwapStorage storage $ = _getStorage();
        emit FeeUpdated($.fee, fee);
        $.fee = fee;
    }

    function pause() external onlyOwner {
        _getStorage().isPaused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        _getStorage().isPaused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Internal helpers ────────────────────────────────────────────────

    function _checkDebtCeiling() internal view {
        uint256 supply = aEthWETH.balanceOf(MELLOW_VAULT);
        uint256 debt = variableDebtEthWETH.balanceOf(MELLOW_VAULT);
        if (supply >= debt) revert DebtCeilingBreached(supply, debt);
    }

    function _minOf(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _getStorage() internal pure returns (LidoATokenSwapStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }
}
