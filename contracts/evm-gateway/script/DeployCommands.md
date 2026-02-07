# Deployment Commands

## Gateway Deployment

### 1. Deploy Gateway with Proxy
```bash
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

### 2. Upgrade Gateway Implementation
```bash
forge script script/3_UpgradeGatewayNewImpl.sol:UpgradeGatewayNewImpl \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

### Gateway Verification Commands

**Gateway Implementation:**
```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor()") \
  <IMPLEMENTATION_ADDR> src/UniversalGatewayV0.sol:UniversalGatewayV0
```

**TransparentUpgradeableProxy:**
```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <IMPLEMENTATION_ADDR> <PROXY_ADMIN_ADDR> 0x) \
  <PROXY_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy
```

**ProxyAdmin:**
```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDR>) \
  <PROXY_ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin
```

### Deployed Gateway Contracts
```
Implementation: 0x0b9fC64DD358D9A7b5B1Af93cfdA69E743b31392
Proxy (Gateway): 0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A
Proxy Admin: 0x756C0bEa91F5692384AEe147C10409BB062Bf39b
```

---

## Vault Deployment

### Prerequisites
Before deploying the Vault, ensure you have:
1. **Gateway Address**: The deployed UniversalGateway proxy address
2. **CEAFactory Address**: The deployed CEAFactory contract address

Update these addresses in `script/4_DeployVaultWithProxy.sol`:
```solidity
address constant GATEWAY_ADDRESS = 0x...; // Set Gateway proxy address
address constant CEA_FACTORY_ADDRESS = 0x...; // Set CEAFactory address
```

### 1. Deploy Vault with Proxy
```bash
forge script script/4_DeployVaultWithProxy.sol:DeployVaultWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

### 2. Upgrade Vault Implementation
First, update the addresses in `script/5_UpgradeVaultNewImpl.sol`:
```solidity
address constant EXISTING_VAULT_PROXY = 0x...; // Set Vault proxy address
address constant EXISTING_PROXY_ADMIN = 0x...; // Set ProxyAdmin address
```

Then run:
```bash
forge script script/5_UpgradeVaultNewImpl.sol:UpgradeVaultNewImpl \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

### Vault Verification Commands

**Vault Implementation:**
```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor()") \
  <VAULT_IMPL_ADDR> src/Vault.sol:Vault
```

**TransparentUpgradeableProxy:**
```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <VAULT_IMPL_ADDR> <PROXY_ADMIN_ADDR> 0x) \
  <VAULT_PROXY_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy
```

**ProxyAdmin:**
```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDR>) \
  <PROXY_ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin
```

---

## Deployment Order

For a complete system deployment, follow this order:

1. **Deploy Gateway** (script 1)
   - Deploys UniversalGateway with proxy pattern
   - Sets up oracle feeds and Uniswap integration

2. **Deploy CEAFactory** (separate deployment)
   - Deploys the CEA (Chain Execution Account) factory
   - Required for Vault to create CEAs

3. **Deploy Vault** (script 4)
   - Update `GATEWAY_ADDRESS` and `CEA_FACTORY_ADDRESS` in script
   - Deploys Vault with proxy pattern
   - Links to Gateway and CEAFactory

4. **Configure Integration**
   - Grant necessary roles
   - Update Gateway to reference Vault if needed
   - Test integration between all components

---

## Notes

- All deployment scripts use the TransparentUpgradeableProxy pattern
- Default role assignments use the deployer address (can be changed post-deployment)
- Always verify contracts on Etherscan after deployment
- Test thoroughly on testnet before mainnet deployment