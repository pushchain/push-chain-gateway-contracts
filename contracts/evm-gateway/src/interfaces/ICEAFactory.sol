// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev Interface for CEA factory
 */
interface ICEAFactory {
    /**
     * @notice Deploys a new CEA for the given UEA on Push Chain, if not already deployed.
     *
     * @dev
     *  - Only callable by the Vault contract.
     *  - If a CEA already exists and has code, SHOULD revert to avoid ambiguity.
     *  - If the mapping exists but the code at the address is missing (e.g. selfdestruct),
     *    the factory MAY re-deploy at the same address using the same salt.
     *
     * @param _uea  Address of the UEA on Push Chain.
     * @return cea       Address of the deployed CEA on the external chain.
     */
    function deployCEA(address _uea) external returns (address cea);
    /**
     * @notice Returns the CEA address and deployment status for a given Push Chain account.
     *
     * @dev
     *  - If the CEA has been deployed, returns (cea, true).
     *  - If the CEA has not been deployed, returns (predictedAddress, false).
     *
     * @param _pushAccount  Address of the Push Chain account (UEA).
     * @return cea          Address of the CEA (deployed or predicted via CREATE2).
     * @return isDeployed   True if the CEA has code deployed at that address.
     */
    function getCEAForPushAccount(address _pushAccount) external view returns (address cea, bool isDeployed);

    /**
     * @notice Returns true if the given address is a CEA deployed by this factory.
     * @param _cea  Address to check.
     * @return      True if `_cea` was deployed by this factory.
     */
    function isCEA(address _cea) external view returns (bool);

    /**
     * @notice Returns the UEA on Push Chain that maps to the given CEA.
     * @param _cea  CEA address on this chain.
     * @return uea  Mapped UEA address (address(0) if no mapping exists).
     */
    function getUEAForCEA(address _cea) external view returns (address uea);
}