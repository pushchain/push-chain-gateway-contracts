# Push Chain Overview (for Smart Contract Repos)

## What is Push Chain? (≈200 words)

Push Chain is a 100% EVM-compatible Proof-of-Stake Layer 1 designed to make applications universal: deploy a Solidity contract once on Push Chain, and let users from many chains interact with it using their existing wallets. A user signs a request from their origin chain (for example, Ethereum Sepolia or Solana Devnet). 

Push Chain deterministically maps that origin wallet to a smart account on Push Chain called a Universal Executor Account (UEA). The UEA verifies the origin signature and executes the encoded payload on Push Chain.

Cross-chain requests are routed through Universal Gateway contracts deployed on origin chains and verified by a Universal Validator set that forms consensus on transaction validity before relay and execution. 

Push Chain also supports fee abstraction: users can initiate actions without holding $PC up front, because fees can be locked on the origin chain while execution happens on Push Chain.

In short, Push Chain is a shared EVM execution layer that preserves origin identity, reduces multi-chain UX friction, and lets builders reach multi-chain users with one deployed contract. Each UEA also maps back to a Universal Origin Account (UOA) in a chain-agnostic address format.

---

## Core Technical Components

### 1) Push Chain (EVM L1)
- Runs Solidity contracts as-is (EVM compatibility).
- Shared execution environment for “universal” apps.

### 2) Universal Gateway (UG) Contracts
- Deployed on *origin chains* ( EVMs or SVMs ).
- Routes funds or payloads from origin chains and Push Chain.
- In standard flow, locks/escrows the required gas fee on the origin chain before relaying.

### 3) Universal Validators
- A validator set that verifies cross-chain requests produced on origin chains.
- Forms consensus on the request’s validity (e.g., payload integrity, origin context, and protocol rules) before it is relayed for execution on Push Chain.
- Produces an attestation / approval signal that downstream components (relayers and Push Chain execution) can rely on.
- Helps the system tolerate faulty relayers and reduces the trust assumptions of cross-chain message passing.

### 4) Universal Executor Account (UEA)
- Deterministic smart account on Push Chain representing an origin wallet.
- For ex: Bob ( 0xabc ) on ETH chain gets a 0xXYZ smart account determinitically deployed for him on PUSH CHAIN. 
This UEA acts as BOB's representation on Push Chain and handles everything for BOB on Push Chain, based on Bob's sign verification
- Holds balances/state on Push Chain and executes payloads (single call or multicall).
- Receives payload + signature bundle (post-validation), runs UVL verification, then executes.

### 5) Chain Executor Account (CEA)
- Deterministic smart account deployed on *origin chains* (external chains).
- Represents a specific UEA on Push Chain on a specific origin chain, enabling vault-driven execution on that origin chain when needed.
- Typically controlled by protocol components on the origin chain (e.g., Vault / Universal Gateway flow), rather than by end-user signatures directly.

### 6) Universal Origin Account (UOA) + Chain-Agnostic Addressing
- UOA is the user’s original wallet identity in a chain-agnostic format (CAIP-10 style identifiers).
- Lets apps attribute actions back to the user’s true origin chain identity.

### 7) UEAFactory + System Contracts (Push Chain Core)
- UEAFactory: creates/derives UEAs and maintains origin↔UEA mapping.
- UniversalCore: core system contract(s) used by the protocol stack.

### 8) PRC-20 Tokens (Mapped Assets on Push Chain)
- Token contracts on Push Chain that map to assets from external origin chains.
- Used to represent supported origin assets inside Push Chain’s EVM environment (see “Smart Contract Address Book” in docs for the authoritative list).

---

## Transaction Flows ( Inbound vs Outbound )

### Inbound (Origin Chain → Push Chain Execution)
1. BOB signs on the origin chain wallet (EVM or non-EVM).
2. Universal Gateway on the origin chain locks required fee/funds and emits/relays the payload.
3. Universal Validators verify the transaction and form consensus on validity.
4. BOB's deterministic UEA on Push Chain receives the payload + signature bundle.
5. BOB's UEA verifies his signature.
6. UEA executes the payload on Push Chain (single call or batched multicall).

```text
Origin chain                                          Push Chain
────────────                                          ─────────
[BOB(OriginWallet)]
      |
      | 1) Sign Payload ( with FUNDS or GAS)
      v
[UniversalGateway]
      |
      | 2) Lock fee / escrow and publish payload
      v
[UniversalValidators]
      |
      | 3) Reach consensus + produce attestation
      v
[Relayer]
      |
      | 4) Deliver (payload + signature bundle + attestation)
      v
[UEA]
      |
      | 5) UVL verifies origin signature
      v
[Execute payload on Push Chain (single call or multicall)]
```

**Optimization: “Already funded” path**
- If the UEA already has sufficient fee balance on Push Chain, the SDK can bypass Gateway + Validators and send directly to the UEA for faster execution.

**Confirmation modes (conceptual)**
- “Fast mode” may relay after minimal origin confirmations for small value transactions.
- “Standard mode” waits more confirmations based on reorg risk.

### Outbound (Push Chain → Origin Chain Action)

1. Bob calls UniversalGatewayPC contract on Push Chain.
2. Bob burns 10 pETH and a payload to execute it on Ethereum.
3. UniversalGateway calculates gas estimates > Locks the Gas Fees and > burns the 10 pETH on PC.
4. UniversalValidators relay this info to source chain.
5. TSS on source chains validate the burn and release the funds or execute payload on Push Chain using Bob's very own CEA.

```text
Push Chain                                             Origin chain
─────────                                             ───────────
[Bob]
  |
  | 1) Call UniversalGatewayPC
  v
[UniversalGatewayPC]
  |
  | 2) Burn pETH + submit outbound payload
  | 3) Estimate gas + lock gas fees + finalize burn
  v
[UniversalValidators]
  |
  | 4) Relay attested burn + payload to origin chain
  v
[TSS / Origin validators]
  |
  | 5) Validate burn and then:
  |    - Release funds, or
  |    - Execute origin-chain payload via Bob's CEA
  v
[Bob's CEA (Origin chain execution)]
```