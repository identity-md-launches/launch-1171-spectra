// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @title DeploySpectra
/// @notice Reviewable deployment entry point. The token takes no constructor arguments, so there is
///         no configuration to read: whoever broadcasts `run()` receives the whole supply.
/// @dev The IdentityMD launch does not use this script. The factory deploys the token from its
///      bytecode and receives the supply itself. The script exists for local checks and for anyone
///      deploying the token outside the launch. `deploy()` is what the tests call.
contract DeploySpectra is Script {
    /// @notice Deploys the token. The caller of this function is the deployer and receives the supply.
    function deploy() public returns (SpectraToken token) {
        token = new SpectraToken();
    }

    /// @notice Broadcasts the deployment with the configured sender (`--sender` / `--private-key`).
    function run() external returns (SpectraToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
