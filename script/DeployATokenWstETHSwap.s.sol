// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ATokenWstETHSwap} from "../src/ATokenWstETHSwap.sol";

/// @notice Deploys ATokenWstETHSwap. The contract is self-contained (no proxy),
///         so this script only needs the four constructor parameters.
/// @dev Deployment parameters are hardcoded as constants below. Update them
///      before broadcasting. The deployer key is provided by the usual
///      `forge script --private-key` flag; `vm.startBroadcast()` here
///      broadcasts under that key.
///
///      ┌─────────────────┬────────────────────────────────────────────────┐
///      │ Constant        │ Meaning                                        │
///      ├─────────────────┼────────────────────────────────────────────────┤
///      │ OWNER           │ Admin address (setPremium, pause, spell)       │
///      │ MELLOW_SUBVAULT1│ Counterparty holding aEthwstETH liquidity      │
///      │ EARN_TREASURY   │ Address that receives the premium profit       │
///      │ SWAP_FEE        │ Initial premium (6-decimal, e.g. 20000 = 2%)   │
///      └─────────────────┴────────────────────────────────────────────────┘
///
///      Example:
///          forge script script/DeployATokenWstETHSwap.s.sol:DeployATokenWstETHSwap \
///              --rpc-url $MAINNET_RPC_URL --private-key $DEPLOYER_PK --broadcast
contract DeployATokenWstETHSwap is Script {
    // TBD: admin address (setPremium, pause, spell). Deploy will revert until this is set.
    address public constant OWNER = address(0);
    address public constant EARN_TREASURY = 0xcCf2daba8Bb04a232a2fDA0D01010D4EF6C69B85;
    // Mellow Subvault holding the leveraged Aave V3 position (aEthwstETH + variableDebtEthWETH).
    address public constant MELLOW_SUBVAULT1 = 0x893aa69FBAA1ee81B536f0FbE3A3453e86290080;
    uint256 public constant SWAP_FEE = 2_0000; // 2% (6-decimal precision)

    /// @notice CLI entrypoint. Deploys and returns the contract instance.
    function run() external returns (ATokenWstETHSwap swap) {
        address owner = OWNER;
        address vault = MELLOW_SUBVAULT1;
        address profitReceiver = EARN_TREASURY;
        uint256 premium = SWAP_FEE;

        swap = _deploy(owner, vault, profitReceiver, premium);
    }

    /// @notice Test-callable entrypoint. Bypasses the hardcoded constants so
    ///         fork tests can build their own deployment fixtures.
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

        console2.log("Deploying ATokenWstETHSwap with:");
        console2.log("  owner          =", owner);
        console2.log("  vault          =", vault);
        console2.log("  profitReceiver =", profitReceiver);
        console2.log("  premium        =", premium);

        vm.startBroadcast();
        swap = new ATokenWstETHSwap(owner, vault, profitReceiver, premium);
        vm.stopBroadcast();

        _verifyDeployment(swap, owner, vault, profitReceiver, premium);

        console2.log("ATokenWstETHSwap deployed at:", address(swap));
        console2.log("WARNING: contract is NOT paused on deploy; owner must call pause() if a cool-down period is required.");
    }

    /// @notice Post-deploy sanity check. Reverts the script if any constructor
    ///         parameter or derived state on the deployed contract doesn't
    ///         match what we asked for — catches misconfiguration before the
    ///         deployer walks away thinking everything is fine.
    function _verifyDeployment(
        ATokenWstETHSwap swap,
        address expectedOwner,
        address expectedVault,
        address expectedProfitReceiver,
        uint256 expectedPremium
    ) internal view {
        require(swap.owner() == expectedOwner, "post-deploy: owner mismatch");
        require(swap.vault() == expectedVault, "post-deploy: vault mismatch");
        require(swap.profitReceiver() == expectedProfitReceiver, "post-deploy: profitReceiver mismatch");
        require(swap.premium() == expectedPremium, "post-deploy: premium mismatch");
        require(swap.premium() <= swap.MAX_PREMIUM(), "post-deploy: premium above MAX_PREMIUM");
        require(!swap.paused(), "post-deploy: should not be paused");

        console2.log("Post-deploy checks passed.");
    }
}
