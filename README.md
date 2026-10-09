# Spectra (SPECTRA)

A fixed-supply ERC-20 token for the IdentityMD custom token launch on Ethereum (chain id 1).

| Field | Value |
| --- | --- |
| Solidity contract | `SpectraToken` (`src/SpectraToken.sol`) |
| `name()` | `Spectra` |
| `symbol()` | `SPECTRA` |
| `decimals()` | `18` |
| `totalSupply()` at deployment | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |
| Owner / admin | none |

## Behaviour

- The constructor mints the whole supply once to `msg.sender`. In the launch that is the
  ProjectFactory, which then forwards the swarm's share, seeds the pool and sends the remainder.
- There is no `mint`, no owner, no minter role, no pause, no blacklist, no freeze and no fee. The
  supply can never grow after deployment.
- Every `transfer` and `transferFrom` moves exactly the amount requested, for every caller. Nothing is
  exempted because nothing needs to be: the factory, the PoolManager, the MerkleDistributor and
  ordinary traders are all treated the same.
- Holders may `burn` their own tokens, and `burnFrom` works only against an allowance the holder
  granted. Burning only ever shrinks the supply. Without an allowance, `burnFrom` reverts and moves
  nothing, so no privileged hand can burn a holder's balance.
- An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
- Transfers and approvals to the zero address revert. The contract has no `receive` or `fallback`,
  so it rejects ETH.
- The contract inherits nothing and calls no library, so the bytecode has no link placeholders and
  contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## Errors

| Error | When |
| --- | --- |
| `ZeroAddress()` | transfer to, or approval of, the zero address |
| `InsufficientBalance(account, available, needed)` | a transfer or burn exceeds the account's balance |
| `InsufficientAllowance(owner, spender, available, needed)` | a `transferFrom` or `burnFrom` exceeds the allowance |

## Deployment parameters

The token takes no constructor arguments. The address that runs the constructor receives the
entire supply, so the deployer is the only deployment parameter and it is implied by who deploys.

For the IdentityMD launch, the manifest step (not this repository) writes `launch.json` with:

- token: contract `SpectraToken`, name `Spectra`, symbol `SPECTRA`, decimals `18`,
  `constructorArgs` `[]`, `totalSupply` `1000000000000000000000000000`;
- contracts: none (this launch has no application contracts);
- pool: paired currency IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee `12500`,
  tick spacing `60`, initial price `79228162514264337593543950336` (provenance only; the deployer
  derives the opening price from the market cap);
- economics as given by the requester: `poolBps` 8800, `initialMarketCapWei`
  `2500000000000000000000` (2,500 IMD), `remainderTo` `0x6bf192ebef135e0f645e99d59d9bf44e7711606c`.

Distribution the launch performs, in minor units of the 1,000,000,000 × 10^18 supply:

| Share | Recipient | Set by |
| --- | --- | --- |
| 10% | the launch's MerkleDistributor (swarm) | the factory, by construction |
| 88% | single-sided liquidity in the IMD/SPECTRA Uniswap v4 pool | `economics.poolBps` |
| 2% | `0x6bf192ebef135e0f645e99d59d9bf44e7711606c` | `economics.remainderTo` |

Nothing in this repository is allocated, reserved or sent any of the supply.

### Outside the launch

`script/DeploySpectra.s.sol` is a reviewable, argument-free deployment. Its `deploy()` function is
what the tests exercise; `run()` wraps it in a broadcast and takes its sender from the forge command
line (`--sender`, `--private-key`, or a keystore). Whoever broadcasts it receives the whole supply.
This repository does not hold keys and does not broadcast anything.

```sh
forge script script/DeploySpectra.s.sol --rpc-url <RPC> --sender <DEPLOYER> --broadcast
```

## After launch

There is nothing to configure. The token has no owner and no settable values.

## Operational responsibilities

- **Nobody can intervene.** There is no admin. A lost or stolen holder key cannot be recovered or
  frozen by anyone, and the supply can never be changed except by holders burning their own tokens.
  This is intentional and is the trust assumption the token offers.
- **Holders manage their own allowances.** An unlimited allowance to a compromised contract can drain
  the holder's balance; approve only what is needed.
- **The deployer's privilege is one-off.** Holding the supply at deployment is the only thing the
  deployer ever gets. In the launch the deployer is the factory and it pays everything out.
- **Verification on the explorer** (`forge verify-contract` with `bytecode_hash = "none"` and
  solc 0.8.26) belongs to the network's deployer after the launch records the address.

## Assumptions

- The launch factory deploys the token with CREATE2 and is `msg.sender` of the constructor, so it
  receives the supply directly. No other address is needed at construction time.
- No fee, tax, burn-on-transfer or reflection was requested, so none is implemented and the launch
  flows (distributor transfer, pool seed, claims, swaps) move exactly their stated amounts.
- EIP-2612 `permit` was not requested and is not included, keeping the contract minimal and free of
  signature-handling surface.

## Project layout

```
foundry.toml              solc 0.8.26, optimizer on, bytecode_hash = "none", ffi off
remappings.txt            forge-std/ -> lib/forge-std/src/
src/SpectraToken.sol      the token
script/DeploySpectra.s.sol  argument-free deployment, deploy() tested directly
test/SpectraToken.t.sol   unit, failure and fuzz tests
lib/forge-std             forge-std v1.9.6 vendored as plain files (tests and scripts removed)
```

## Checks

```sh
forge build
forge test
forge fmt --check
```

The tests read no environment variables, depend on no caller identity and pass in any order and in
parallel. Tests passing are not a security audit; the token holds no user funds itself, but any
contract that will hold SPECTRA on behalf of users should get an independent adversarial review.
