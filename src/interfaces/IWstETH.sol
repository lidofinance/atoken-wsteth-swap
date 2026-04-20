// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWstETH {
    /// @notice Returns the amount of stETH for 1 wstETH (18 decimals).
    function stEthPerToken() external view returns (uint256);
}
