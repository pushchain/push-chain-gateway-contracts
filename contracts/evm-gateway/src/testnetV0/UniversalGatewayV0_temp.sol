// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGatewayV0_temp
 * @notice Temporary wrapper for UniversalGatewayV0 that adds `moveFunds_temp()`.
 * @dev    Used ONLY during the upgrade migration sequence:
 *         1. Upgrade proxy to this implementation (adds moveFunds_temp)
 *         2. Register Vault + CEAFactory via setVault / setCEAFactory
 *         3. Call moveFunds_temp(token) to migrate ERC20 balances to Vault
 *         4. Upgrade proxy to clean UniversalGatewayV0 (removes moveFunds_temp)
 *
 *         No new storage variables — safe for proxy upgrade from UniversalGatewayV0.
 */

import { UniversalGatewayV0 } from "./UniversalGatewayV0.sol";
import { Errors } from "../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UniversalGatewayV0_temp is UniversalGatewayV0 {
    using SafeERC20 for IERC20;

    /// @notice Migrate the entire balance of `token` from this gateway to VAULT.
    /// @dev    - Only callable by DEFAULT_ADMIN_ROLE
    ///         - Reverts if VAULT is not set
    ///         - Reverts if gateway has zero balance
    ///         - Pass address(0) to migrate native balance
    /// @param token ERC20 token address, or address(0) for native
    function moveFunds_temp(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (VAULT == address(0)) revert Errors.ZeroAddress();

        if (token == address(0)) {
            uint256 balance = address(this).balance;
            if (balance == 0) revert Errors.InvalidAmount();
            (bool ok,) = payable(VAULT).call{ value: balance }("");
            if (!ok) revert Errors.WithdrawFailed();
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) revert Errors.InvalidAmount();
            IERC20(token).safeTransfer(VAULT, balance);
        }
    }
}
