// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ATokenWstETHSwap} from "../src/ATokenWstETHSwap.sol";

/// @notice Deploys ATokenWstETHSwap. The contract is self-contained (no proxy),
///         so this script only needs the four constructor parameters.
/// @dev Reads the deployment parameters from environment variables. The
///      deployer key is provided by the usual `forge script --private-key`
///      flag; `vm.startBroadcast()` here broadcasts under that key.
///
///      ┌─────────────────┬────────────────────────────────────────────────┐
///      │ Variable        │ Meaning                                        │
///      ├─────────────────┼────────────────────────────────────────────────┤
///      │ OWNER           │ Admin address (setPremium, pause, spell)       │
///      │ VAULT           │ Counterparty holding aEthwstETH liquidity      │
///      │ PROFIT_RECEIVER │ Address that receives the premium profit       │
///      │ PREMIUM         │ Initial premium (6-decimal, e.g. 20000 = 2%)   │
///      └─────────────────┴────────────────────────────────────────────────┘
///
///      Example:
///          OWNER=0x... VAULT=0x... PROFIT_RECEIVER=0x... PREMIUM=20000 \
///              forge script script/DeployATokenWstETHSwap.s.sol:DeployATokenWstETHSwap \
///              --rpc-url $MAINNET_RPC_URL --private-key $DEPLOYER_PK --broadcast
contract DeployATokenWstETHSwap is Script {
    /// @notice CLI entrypoint. Deploys and returns the contract instance.
    function run() external returns (ATokenWstETHSwap swap) {
        address owner = vm.envAddress("OWNER");
        address vault = vm.envAddress("VAULT");
        address profitReceiver = vm.envAddress("PROFIT_RECEIVER");
        uint256 premium = vm.envUint("PREMIUM");

        swap = _deploy(owner, vault, profitReceiver, premium);
    }

    /// @notice Test-callable entrypoint. Skips env reads so fork tests can
    ///         build their own deployment fixtures.
    function deploy(address owner, address vault, address profitReceiver, uint256 premium)
        external
        returns (ATokenWstETHSwap)
    {
        return _deploy(owner, vault, profitReceiver, premium);
    }

    function _deploy(address owner, address vault, address profitReceiver, uint256 premium)
        internal
        returns (ATokenWstETHSwap swap)
    {
        require(owner != address(0), "OWNER is zero");
        require(vault != address(0), "VAULT is zero");
        require(profitReceiver != address(0), "PROFIT_RECEIVER is zero");
        require(premium < 1e6, "PREMIUM must be < 1e6 (100%)");

        console2.log("Deploying ATokenWstETHSwap with:");
        console2.log("  owner          =", owner);
        console2.log("  vault          =", vault);
        console2.log("  profitReceiver =", profitReceiver);
        console2.log("  premium        =", premium);

        vm.startBroadcast();
        swap = new ATokenWstETHSwap(owner, vault, profitReceiver, premium);
        vm.stopBroadcast();

        console2.log("ATokenWstETHSwap deployed at:", address(swap));
        console2.log("WARNING: contract is NOT paused on deploy; owner must call pause() if a cool-down period is required.");
    }
}
