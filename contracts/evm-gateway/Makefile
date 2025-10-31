.PHONY: help deploy-gateway deploy-gateway-v0 deploy-gateway-pc verify-gateway verify-gateway-v0 verify-gateway-pc upgrade-gateway upgrade-gateway-v0 upgrade-vault upgrade-gateway-pc upgrade-vault-pc

# Default network
network ?= sepolia

# Map network names to foundry chain names
ifeq ($(network),sepolia)
	CHAIN = sepolia
else ifeq ($(network),base_sepolia)
	CHAIN = base_sepolia
else ifeq ($(network),arb_sepolia)
	CHAIN = arb_sepolia
else ifeq ($(network),bsc_testnet)
	CHAIN = bsc_testnet
else ifeq ($(network),push_chain)
	CHAIN = push_chain
else
	$(error Unknown network: $(network). Supported: sepolia, base_sepolia, arb_sepolia, bsc_testnet, push_chain)
endif

help:
	@echo "════════════════════════════════════════════════════════════════"
	@echo "  DEPLOYMENT COMMANDS"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  make deploy-gateway network=<network>"
	@echo "    Deploy UniversalGateway + Vault (new, no USDT)"
	@echo ""
	@echo "  make deploy-gateway-v0 network=<network>"
	@echo "    Deploy UniversalGatewayV0 (legacy with USDT)"
	@echo ""
	@echo "  make deploy-gateway-pc network=<network>"
	@echo "    Deploy UniversalGatewayPC + VaultPC (Push Chain)"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════"
	@echo "  VERIFICATION COMMANDS"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  make verify-gateway network=<network>"
	@echo "  make verify-gateway-v0 network=<network>"
	@echo "  make verify-gateway-pc network=<network>"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════"
	@echo "  UPGRADE COMMANDS"
	@echo "════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  make upgrade-gateway network=<network> PROXY_ADDRESS=0x... PROXY_ADMIN_ADDRESS=0x..."
	@echo "    Upgrade UniversalGateway"
	@echo ""
	@echo "  make upgrade-gateway-v0 network=<network> PROXY_ADDRESS=0x... PROXY_ADMIN_ADDRESS=0x..."
	@echo "    Upgrade UniversalGatewayV0"
	@echo ""
	@echo "  make upgrade-vault network=<network> PROXY_ADDRESS=0x... PROXY_ADMIN_ADDRESS=0x..."
	@echo "    Upgrade Vault"
	@echo ""
	@echo "  make upgrade-gateway-pc network=<network> PROXY_ADDRESS=0x... PROXY_ADMIN_ADDRESS=0x..."
	@echo "    Upgrade UniversalGatewayPC"
	@echo ""
	@echo "  make upgrade-vault-pc network=<network> PROXY_ADDRESS=0x... PROXY_ADMIN_ADDRESS=0x..."
	@echo "    Upgrade VaultPC"
	@echo ""
	@echo "════════════════════════════════════════════════════════════════"
	@echo "  NETWORKS: sepolia, base_sepolia, arb_sepolia, bsc_testnet, push_chain"
	@echo "════════════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════
#  DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════

deploy-gateway:
	@echo "Deploying UniversalGateway + Vault to $(network)..."
	@NETWORK=$(network) forge script script/deployment/DeployUniversalGateway.sol:DeployUniversalGateway \
		--rpc-url $(CHAIN) \
		--broadcast \
		--via-ir
	@echo "✅ Deployment complete! Run 'make verify-gateway network=$(network)' to verify contracts."

deploy-gateway-v0:
	@echo "Deploying UniversalGatewayV0 to $(network)..."
	@NETWORK=$(network) forge script script/deployment/DeployUniversalGatewayV0.sol:DeployUniversalGatewayV0 \
		--rpc-url $(CHAIN) \
		--broadcast \
		--via-ir
	@echo "✅ Deployment complete! Run 'make verify-gateway-v0 network=$(network)' to verify contracts."

deploy-gateway-pc:
	@echo "Deploying UniversalGatewayPC + VaultPC to $(network)..."
	@NETWORK=$(network) forge script script/deployment/DeployUniversalGatewayPC.sol:DeployUniversalGatewayPC \
		--rpc-url $(CHAIN) \
		--broadcast \
		--slow \
		--via-ir
	@echo "✅ Deployment complete! Verify manually if needed."

# ═══════════════════════════════════════════════════════════════════════
#  VERIFICATION
# ═══════════════════════════════════════════════════════════════════════

verify-gateway:
	@echo "Use broadcast receipts to verify contracts manually:"
	@echo "Check: broadcast/DeployUniversalGateway.sol/*/run-latest.json"
	@echo ""
	@echo "Example: forge verify-contract <PROXY_ADDRESS> src/UniversalGateway.sol:UniversalGateway --chain $(CHAIN)"

verify-gateway-v0:
	@echo "Use broadcast receipts to verify contracts manually:"
	@echo "Check: broadcast/DeployUniversalGatewayV0.sol/*/run-latest.json"
	@echo ""
	@echo "Example: forge verify-contract <PROXY_ADDRESS> src/UniversalGatewayV0.sol:UniversalGatewayV0 --chain $(CHAIN)"

verify-gateway-pc:
	@echo "Use broadcast receipts to verify contracts manually:"
	@echo "Check: broadcast/DeployUniversalGatewayPC.sol/*/run-latest.json"
	@echo ""
	@echo "Example: forge verify-contract <PROXY_ADDRESS> src/UniversalGatewayPC.sol:UniversalGatewayPC --chain $(CHAIN)"

# ═══════════════════════════════════════════════════════════════════════
#  UPGRADE
# ═══════════════════════════════════════════════════════════════════════

upgrade-gateway:
	@echo "Upgrading UniversalGateway on $(network)..."
	@if [ -z "$(PROXY_ADDRESS)" ]; then \
		echo "Auto-detecting proxy from broadcast folder..."; \
		SCRIPT_DIR="broadcast/DeployUniversalGateway.sol"; \
		LATEST=$$(find $$SCRIPT_DIR -name "run-latest.json" ! -path "*/dry-run/*" -type f -exec ls -t {} + 2>/dev/null | head -1); \
		if [ -z "$$LATEST" ]; then echo "❌ No deployment found. Deploy first or provide PROXY_ADDRESS=0x..."; exit 1; fi; \
		if command -v jq >/dev/null 2>&1; then \
			PROXY=$$(jq -r '.transactions[] | select(.contractName == "TransparentUpgradeableProxy" and (.transaction.to == null or .transaction.to == "")) | .contractAddress' $$LATEST 2>/dev/null | head -1); \
		else \
			PROXY=$$(cat $$LATEST | grep -B2 -A5 '"contractName": "TransparentUpgradeableProxy"' | grep -B3 '"to": null' | grep '"contractAddress"' | tail -1 | cut -d'"' -f4); \
		fi; \
		if [ -z "$$PROXY" ] || [ "$$PROXY" = "null" ]; then echo "❌ Could not find Gateway proxy address in deployment"; exit 1; fi; \
		echo "Found Gateway Proxy: $$PROXY (ProxyAdmin auto-detected from storage slot)"; \
		NETWORK=$(network) PROXY_ADDRESS=$$PROXY forge script script/upgrade/UpgradeUniversalGateway.sol:UpgradeUniversalGateway --rpc-url $(CHAIN) --broadcast --via-ir; \
	else \
		echo "Using provided PROXY_ADDRESS: $(PROXY_ADDRESS)"; \
		NETWORK=$(network) PROXY_ADDRESS=$(PROXY_ADDRESS) forge script script/upgrade/UpgradeUniversalGateway.sol:UpgradeUniversalGateway --rpc-url $(CHAIN) --broadcast --via-ir; \
	fi

upgrade-gateway-v0:
	@echo "Upgrading UniversalGatewayV0 on $(network)..."
	@if [ -z "$(PROXY_ADDRESS)" ]; then \
		echo "Auto-detecting proxy from broadcast folder..."; \
		SCRIPT_DIR="broadcast/DeployUniversalGatewayV0.sol"; \
		LATEST=$$(find $$SCRIPT_DIR -name "run-latest.json" ! -path "*/dry-run/*" -type f -exec ls -t {} + 2>/dev/null | head -1); \
		if [ -z "$$LATEST" ]; then echo "❌ No deployment found. Deploy first or provide PROXY_ADDRESS=0x..."; exit 1; fi; \
		if command -v jq >/dev/null 2>&1; then \
			PROXY=$$(jq -r '.transactions[] | select(.contractName == "TransparentUpgradeableProxy" and (.transaction.to == null or .transaction.to == "")) | .contractAddress' $$LATEST 2>/dev/null | head -1); \
		else \
			PROXY=$$(cat $$LATEST | grep -B2 -A5 '"contractName": "TransparentUpgradeableProxy"' | grep -B3 '"to": null' | grep '"contractAddress"' | tail -1 | cut -d'"' -f4); \
		fi; \
		if [ -z "$$PROXY" ] || [ "$$PROXY" = "null" ]; then echo "❌ Could not find proxy address in deployment"; exit 1; fi; \
		echo "Found Gateway Proxy: $$PROXY (ProxyAdmin auto-detected from storage slot)"; \
		NETWORK=$(network) PROXY_ADDRESS=$$PROXY forge script script/upgrade/UpgradeUniversalGatewayV0.sol:UpgradeUniversalGatewayV0 --rpc-url $(CHAIN) --broadcast --via-ir; \
	else \
		echo "Using provided PROXY_ADDRESS: $(PROXY_ADDRESS)"; \
		NETWORK=$(network) PROXY_ADDRESS=$(PROXY_ADDRESS) forge script script/upgrade/UpgradeUniversalGatewayV0.sol:UpgradeUniversalGatewayV0 --rpc-url $(CHAIN) --broadcast --via-ir; \
	fi

upgrade-vault:
	@echo "Upgrading Vault on $(network)..."
	@if [ -z "$(PROXY_ADDRESS)" ]; then \
		echo "Auto-detecting proxy from broadcast folder..."; \
		SCRIPT_DIR="broadcast/DeployUniversalGateway.sol"; \
		LATEST=$$(find $$SCRIPT_DIR -name "run-latest.json" ! -path "*/dry-run/*" -type f -exec ls -t {} + 2>/dev/null | head -1); \
		if [ -z "$$LATEST" ]; then echo "❌ No deployment found. Deploy first or provide PROXY_ADDRESS=0x..."; exit 1; fi; \
		if command -v jq >/dev/null 2>&1; then \
			PROXY=$$(jq -r '.transactions[] | select((.contractName == "Vault" or (.contractName == "TransparentUpgradeableProxy" and (.transaction.to == null or .transaction.to == ""))) and .contractAddress != null) | .contractAddress' $$LATEST 2>/dev/null | grep -v "^$$" | tail -1); \
		else \
			PROXY=$$(cat $$LATEST | grep -B5 '"contractName": "Vault"' | grep '"contractAddress"' | tail -1 | cut -d'"' -f4); \
		fi; \
		if [ -z "$$PROXY" ] || [ "$$PROXY" = "null" ]; then echo "❌ Could not find Vault proxy address in deployment"; exit 1; fi; \
		echo "Found Vault Proxy: $$PROXY (ProxyAdmin auto-detected from storage slot)"; \
		NETWORK=$(network) PROXY_ADDRESS=$$PROXY forge script script/upgrade/UpgradeVault.sol:UpgradeVault --rpc-url $(CHAIN) --broadcast --via-ir; \
	else \
		echo "Using provided PROXY_ADDRESS: $(PROXY_ADDRESS)"; \
		NETWORK=$(network) PROXY_ADDRESS=$(PROXY_ADDRESS) forge script script/upgrade/UpgradeVault.sol:UpgradeVault --rpc-url $(CHAIN) --broadcast --via-ir; \
	fi

upgrade-gateway-pc:
	@echo "Upgrading UniversalGatewayPC on $(network)..."
	@if [ -z "$(PROXY_ADDRESS)" ]; then \
		echo "Auto-detecting proxy from broadcast folder..."; \
		SCRIPT_DIR="broadcast/DeployUniversalGatewayPC.sol"; \
		LATEST=$$(find $$SCRIPT_DIR -name "run-latest.json" ! -path "*/dry-run/*" -type f -exec ls -t {} + 2>/dev/null | head -1); \
		if [ -z "$$LATEST" ]; then echo "❌ No deployment found. Deploy first or provide PROXY_ADDRESS=0x..."; exit 1; fi; \
		if command -v jq >/dev/null 2>&1; then \
			PROXY=$$(jq -r '.transactions[] | select(.contractName == "TransparentUpgradeableProxy" and (.transaction.to == null or .transaction.to == "")) | .contractAddress' $$LATEST 2>/dev/null | tail -1); \
		else \
			PROXY=$$(cat $$LATEST | grep -B2 -A5 '"contractName": "TransparentUpgradeableProxy"' | grep -B3 '"to": null' | grep '"contractAddress"' | tail -1 | cut -d'"' -f4); \
		fi; \
		if [ -z "$$PROXY" ] || [ "$$PROXY" = "null" ]; then echo "❌ Could not find GatewayPC proxy address in deployment"; exit 1; fi; \
		echo "Found Gateway Proxy: $$PROXY (ProxyAdmin auto-detected from storage slot)"; \
		NETWORK=$(network) PROXY_ADDRESS=$$PROXY forge script script/upgrade/UpgradeUniversalGatewayPC.sol:UpgradeUniversalGatewayPC --rpc-url $(CHAIN) --broadcast --slow --via-ir; \
	else \
		echo "Using provided PROXY_ADDRESS: $(PROXY_ADDRESS)"; \
		NETWORK=$(network) PROXY_ADDRESS=$(PROXY_ADDRESS) forge script script/upgrade/UpgradeUniversalGatewayPC.sol:UpgradeUniversalGatewayPC --rpc-url $(CHAIN) --broadcast --slow --via-ir; \
	fi

upgrade-vault-pc:
	@echo "Upgrading VaultPC on $(network)..."
	@if [ -z "$(PROXY_ADDRESS)" ]; then \
		echo "Auto-detecting proxy from broadcast folder..."; \
		SCRIPT_DIR="broadcast/DeployUniversalGatewayPC.sol"; \
		LATEST=$$(find $$SCRIPT_DIR -name "run-latest.json" ! -path "*/dry-run/*" -type f -exec ls -t {} + 2>/dev/null | head -1); \
		if [ -z "$$LATEST" ]; then echo "❌ No deployment found. Deploy first or provide PROXY_ADDRESS=0x..."; exit 1; fi; \
		if command -v jq >/dev/null 2>&1; then \
			PROXY=$$(jq -r '.transactions[] | select(.contractName == "TransparentUpgradeableProxy" and (.transaction.to == null or .transaction.to == "")) | .contractAddress' $$LATEST 2>/dev/null | head -1); \
		else \
			PROXY=$$(cat $$LATEST | grep -B2 -A5 '"contractName": "TransparentUpgradeableProxy"' | grep -B3 '"to": null' | grep '"contractAddress"' | head -1 | cut -d'"' -f4); \
		fi; \
		if [ -z "$$PROXY" ] || [ "$$PROXY" = "null" ]; then echo "❌ Could not find VaultPC proxy address in deployment"; exit 1; fi; \
		echo "Found VaultPC Proxy: $$PROXY (ProxyAdmin auto-detected from storage slot)"; \
		NETWORK=$(network) PROXY_ADDRESS=$$PROXY forge script script/upgrade/UpgradeVaultPC.sol:UpgradeVaultPC --rpc-url $(CHAIN) --broadcast --slow --via-ir; \
	else \
		echo "Using provided PROXY_ADDRESS: $(PROXY_ADDRESS)"; \
		NETWORK=$(network) PROXY_ADDRESS=$(PROXY_ADDRESS) forge script script/upgrade/UpgradeVaultPC.sol:UpgradeVaultPC --rpc-url $(CHAIN) --broadcast --slow --via-ir; \
	fi
