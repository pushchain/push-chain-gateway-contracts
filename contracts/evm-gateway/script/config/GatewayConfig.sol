// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  GatewayConfig
/// @notice Per-chain deployment parameters for UniversalGateway.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract GatewayConfig {
    struct Config {
        address deployer;
        address vault;
        address uniswapV3Factory;
        address uniswapV3Router;
        address weth;
        address ethUsdFeed;
        address gatewayProxy; // Set for upgrades, address(0) for fresh deploys
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 11155111) return _ethSepolia();
        if (id == 421614) return _arbitrumSepolia();
        if (id == 97) return _bscTestnet();
        if (id == 84532) return _baseSepolia();

        revert("GatewayConfig: unsupported chain");
    }

    // =====================================================================
    //  Ethereum Sepolia (Chain ID: 11155111)
    // =====================================================================

    function _ethSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6,
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: 0x0227628f3F023bb0B980b67D528571c95c6DaC1c,
            uniswapV3Router: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E,
            weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            ethUsdFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            gatewayProxy: address(0) // TODO: Set for upgrades
        });
    }

    // =====================================================================
    //  Arbitrum Sepolia (Chain ID: 421614)
    // =====================================================================

    function _arbitrumSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xD854DDe7C58eC1B405E6577F48a7cC5b5E6EF317,
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: address(0), // TODO: Set before deployment
            uniswapV3Router: address(0), // TODO: Set before deployment
            weth: address(0), // TODO: Set before deployment
            ethUsdFeed: address(0), // TODO: Set before deployment
            gatewayProxy: address(0) // TODO: Set for upgrades
        });
    }

    // =====================================================================
    //  BSC Testnet (Chain ID: 97)
    // =====================================================================

    function _bscTestnet() private pure returns (Config memory) {
        return Config({
            deployer: 0x6dD2cA20ec82E819541EB43e1925DbE46a441970,
            vault: 0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881,
            uniswapV3Factory: address(0), // TODO: Set before deployment
            uniswapV3Router: address(0), // TODO: Set before deployment
            weth: address(0), // TODO: Set before deployment
            ethUsdFeed: address(0), // TODO: Set before deployment
            gatewayProxy: 0x44aFFC61983F4348DdddB886349eb992C061EaC0
        });
    }

    // =====================================================================
    //  Base Sepolia (Chain ID: 84532)
    // =====================================================================

    function _baseSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0x52DEA34AfAaD33Bb16675ED527b1ed80E83ffb09,
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: address(0), // TODO: Set before deployment
            uniswapV3Router: address(0), // TODO: Set before deployment
            weth: address(0), // TODO: Set before deployment
            ethUsdFeed: address(0), // TODO: Set before deployment
            gatewayProxy: address(0) // TODO: Set for upgrades
        });
    }
}
