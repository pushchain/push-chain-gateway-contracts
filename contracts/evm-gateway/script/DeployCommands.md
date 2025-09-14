## VERIFICATION COMMAND: 
1. For TransparentUpgradeableProxy: 

```
forge verify-contract --chain sepolia --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <IMPLEMENTATION_ADDR> <PROXY_ADMIN_ADDR 0x) <PROXY_ADDR lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProx
```

2. For Gateway: 
```
forge verify-contract --chain sepolia --constructor-args $(cast abi-encode "constructor()" ) <IMPLEMENTATION_ADDR> src/UniversalGatewayV0.sol:UniversalGatewayV0
```

3. For ProxyAdmin: 
```
forge verify-contract --chain sepolia --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDR>) <PROXY_ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin
```
---

## DEPLOYMENT COMMAND:
1. For Deployment ( Proxy, Implementation, ProxyAdmin ): 
```
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

2. For Upgrade ( Proxy, Implementation, ProxyAdmin ): 
```
forge script script/3_UpgradeGatewayNewImpl.sol:UpgradeGatewayNewImpl --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```