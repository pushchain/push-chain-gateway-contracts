# BSC Testnet (Chain ID: 97)

---

## Gateway System

| Contract                                   | Address                                      |
| ------------------------------------------ | -------------------------------------------- |
| UniversalGatewayV0 Proxy                   | `0x44aFFC61983F4348DdddB886349eb992C061EaC0` |
| UniversalGatewayV0 ProxyAdmin              | `0x5Cef317D8392dF9F8C8E8a696c6893FD4112542C` |
| UniversalGatewayV0 Impl 1 (superseded)     | `0x94B4849dFCCAb024daD29eEbCEe9c2372938596C` |
| UniversalGatewayV0 Impl 2 (current, clean) | `0x4C4186282842BE1a4c85BA4105E56A7781B5D926` |

## Vault System

| Contract                         | Address                                      |
| -------------------------------- | -------------------------------------------- |
| Vault Proxy                      | `0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881` |
| Vault ProxyAdmin                 | `0xc34eF3cA76d1C18c35AbF5C3664d183B57382AbC` |
| Vault Implementation 1 (current) | `0xb8A0ee314E3F986f162C5071bf9A8d0C4b723Bd4` |
| CEAFactory                       | `0xf882C49A3E3d90640bFbAAf992a04c0712A9Af5C` |

## External / Token Addresses

| Contract           | Address                                      |
| ------------------ | -------------------------------------------- |
| USDT (BSC Testnet) | `0xBC14F348BC9667be46b35Edc9B68653d86013DC5` |

## Deployer / Admin

| Role                          | Address                                      |
| ----------------------------- | -------------------------------------------- |
| Deployer / DEFAULT_ADMIN_ROLE | `0x6dD2cA20ec82E819541EB43e1925DbE46a441970` |


Next Task:

- Based on the OutbounTx_Flow doc, I want you to plan a new document specifically designed for our SDK Dev Team.
- The core focus of this doc should be for the SDK team to get a complete guide on how to create the Multicall payload for each of the specific cases we have specified in the OutboundTx_Flow doc. this includes every single case ( and their sub-cases ) like withdrawal, self-calls, executeUniversalTx, revert and even migration as a special case of CEA Migration etc.
- Idea is to provide a complete knowlegde for SDK team to build the SDK in a way that it allows them to create the right payload for each case to test out all the flows by creating the right multicall.
- Your job is to first go through each of the cases in the 4_OutbounTx_Flow.md file > Then read the contracts needed ( specfically Vault + CEA_Temp ) and then write a detailed Doc called 5_SDK_OutboundTx_Guide.md with all the details as mentioned above.
