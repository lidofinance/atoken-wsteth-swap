# ATokenWstETHSwap

A single-purpose swap contract that enables users to exchange `aEthWETH` for
`aEthwstETH` at the oracle-derived wstETH→stETH rate with a configurable
premium. The contract acts as a de-leveraging rail for a vault that holds a
leveraged wstETH-collateral / WETH-debt position on Aave V3 Ethereum.

## Origin

This contract is based on Fluid's `FluidATokenSwap`, deployed at
[`0x4f8f03cad7512e4f6d1050fb9b2f8b91ae4bc901`](https://etherscan.io/address/0x4f8f03cad7512e4f6d1050fb9b2f8b91ae4bc901).
The original supported two output aTokens (aEthwstETH and aEthweETH) against
a Fluid liteVault; this version drops weETH support and adapts the counterparty
to a Mellow Core Vaults subvault.

## Motivation

A vault running a looped wstETH strategy on Aave V3 accumulates `aEthwstETH`
collateral against `variableDebtEthWETH`. To reduce leverage without routing
wstETH through a DEX (which would drive depeg and eat into the position's
net value on stress events), the vault pre-approves this contract to move
its `aEthwstETH`. End users holding `aEthWETH` in Aave V3 can then:

1. Transfer `aEthWETH` directly to the vault (increasing its WETH supply).
2. Receive `aEthwstETH` from the vault at the oracle rate, minus a premium.

The net effect on the vault is `+amountIn aEthWETH, −fullAmount aEthwstETH`,
and the additional `aEthWETH` is used by the vault operator to call
`Pool.repay(WETH, …)`, burning an equivalent amount of `variableDebtEthWETH`
and reducing the position's WETH short.

From the user's perspective, this is an atomic aToken-to-aToken swap that
preserves their Aave V3 health factor and avoids DEX slippage on wstETH.

## Architecture

```
┌────────────┐  aEthWETH.transferFrom(user, vault, amountIn)
│    User    ├──────────────────────────────────────────────────────┐
└────────────┘                                                      │
       ▲         aEthwstETH.transferFrom(vault, user, amountOut)    │
       │                                                            ▼
       │                                              ┌──────────────────────┐
       │                                              │         vault        │
       │                                              │   (Aave V3 position: │
       │                                              │   aEthwstETH collat, │
       │                                              │   variableDebtEth-   │
       │                                              │   WETH debt)         │
       │                                              └──────────────────────┘
       │      aEthwstETH.transferFrom(vault, profitReceiver, profit)
       └──────────────────────────────────────────────────────────────▲
                                                                      │
                                                            ┌─────────┴──────────┐
                                                            │   profitReceiver   │
                                                            └────────────────────┘
```

`vault` here refers to the address that holds the leveraged Aave V3 position.
In a Mellow Core Vaults deployment this is typically the **Subvault** address,
not the user-facing Vault contract. Use the `CheckMellowBalances` script to
identify the correct address before deployment.

### Invariants

1. **Debt-ceiling invariant** (`_checkDebtCeiling`): after every swap, the
   vault's `variableDebtEthWETH` balance must remain strictly greater than
   its `aEthWETH` balance. Once parity is reached, swaps automatically
   revert with `DebtCeilingBreached` — the contract is, by design, a
   one-shot de-leveraging tool and disables itself when the vault is no
   longer net-short WETH.

2. **Oracle pricing** is derived from `wstETH.stEthPerToken()` — the protocol
   redemption rate, not a market price. Users are exposed to the basis
   between market wstETH/stETH and the NAV rate; the premium is intended to
   cover the vault's de-leveraging margin.

3. **Premium accounting** uses a 6-decimal precision (`PREMIUM_PRECISION =
   1e6`, so `20000 = 2%`). Premium is enforced at `< PREMIUM_PRECISION` (no
   lower cap). Premium profit `fullAmount − amountOut` is paid in
   `aEthwstETH` to `profitReceiver`.

### Roles

| Role               | Address holder   | Capabilities                                              |
|--------------------|------------------|-----------------------------------------------------------|
| `owner`            | immutable        | `setPremium`, `pause`, `unpause`, `spell`                 |
| `vault`            | immutable        | Source of `aEthwstETH` liquidity; recipient of user `aEthWETH` |
| `profitReceiver`   | immutable        | Receives premium in `aEthwstETH` on every swap            |

All three are set once in the constructor (with zero-address validation) and
cannot be changed.

> **Note on `spell()`**: the `owner` retains an unrestricted `delegatecall`
> capability via `spell(target_, data_)`. This is intended as an emergency
> escape hatch (e.g., to rescue mis-sent tokens, execute one-off corrective
> actions). It effectively trusts `owner` with full control over the
> contract's storage and any `approve`d balances of `vault`. See security
> notes below.

## State

Non-upgradeable storage:

```solidity
uint256 public premium;  // 6-decimal, 0 ≤ premium < PREMIUM_PRECISION
bool    public paused;
```

All other configuration is in `immutable`s baked into the bytecode.

## Deployment

Single-step deploy: no proxy, no initializer.

```solidity
new ATokenWstETHSwap(
    owner,          // admin EOA or multisig
    vault,          // vault address holding the Aave position
    profitReceiver, // premium recipient
    premium         // initial premium in 6-decimal format (e.g. 20000 = 2%)
);
```

Post-deploy setup:

1. The `vault` operator grants `aEthwstETH.approve(<swap>, type(uint256).max)`.
2. Users grant `aEthWETH.approve(<swap>, amountIn)` and call `swapToWstETH`.

By default the contract is **not paused**. If a gated rollout is desired,
`owner` should call `pause()` immediately after deployment, then `unpause()`
when allowance has been set up and the vault is operationally ready.

## Usage

### For users

```solidity
// 1. Approve the swap contract to pull aEthWETH
aEthWETH.approve(swap, amountIn);

// 2. Compute expected output off-chain or via view function
uint256 expected = swap.getWstETHAmountOut(amountIn);
uint256 minOut   = expected * 99 / 100; // 1% slippage tolerance

// 3. Swap (basic)
uint256 out = swap.swapToWstETH(amountIn, minOut);

// 3b. Swap with a referral tag (pass-through event only, no on-chain effect)
uint256 out = swap.swapToWstETHWithReferral(amountIn, minOut, referralAddr);
```

### Events

| Event                                           | When                                               |
|-------------------------------------------------|----------------------------------------------------|
| `SwapWstETH(user, amountIn, amountOut, profit)` | On every successful swap                           |
| `ReferralRecorded(user, referral)`              | On `swapToWstETHWithReferral` only, after the swap |
| `PremiumUpdated(oldPremium, newPremium)`        | On `setPremium`                                    |
| `Paused(account)` / `Unpaused(account)`         | On `pause` / `unpause`                             |

`ReferralRecorded` has both `user` and `referral` as `indexed` parameters, so
off-chain indexers can filter on either. A swap with referral emits both
`SwapWstETH` and `ReferralRecorded` in the same transaction — join them by
`(blockNumber, transactionHash)` for full attribution.

### View helpers

| Function                          | Returns                                                  |
|-----------------------------------|----------------------------------------------------------|
| `getWstETHAmountOut(amountIn)`    | Expected `aEthwstETH` output for given `aEthWETH` input  |
| `getWstETHProfit(amountIn)`       | Premium profit, denominated in `aEthwstETH`              |
| `getWstETHRate()`                 | Current raw `wstETH.stEthPerToken()`                     |
| `getWstETHRateWithPremium()`      | Effective rate user pays (rate × PP / (PP − premium))    |
| `availableWstETHLiquidity()`      | `min(balance, allowance)` of vault's `aEthwstETH`        |
| `maxSwapFromDebtCeiling()`        | Upper bound on `amountIn` from debt-ceiling invariant    |
| `maxSwapToWstETH()`               | True max swap, accounting for both liquidity and ceiling |

**Important**: use `maxSwapToWstETH()` for UI display, not
`availableWstETHLiquidity()`. The latter does not account for the
debt-ceiling invariant and can mislead users into submitting swaps that
revert with `DebtCeilingBreached`.

## Addresses (Ethereum mainnet)

| Token                 | Address                                      |
|-----------------------|----------------------------------------------|
| `aEthWETH`            | `0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8` |
| `aEthwstETH`          | `0x0B925eD163218f6662a35e0f0371Ac234f9E9371` |
| `variableDebtEthWETH` | `0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE` |
| `wstETH`              | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |

Constructor parameters (set at deployment):

- `_owner` — admin EOA or multisig with access to `setPremium`, `pause`/`unpause`, `spell`
- `_vault` — address holding the Aave V3 leveraged position and granting `aEthwstETH` allowance
- `_profitReceiver` — address receiving premium accrual in `aEthwstETH`
- `_premium` — initial premium in 6-decimal format

## Security notes

- **Premium changes are instant**: `setPremium` takes effect in the next
  block. Users relying on `getWstETHAmountOut` for slippage calculation must
  use `amountOutMin` to protect against owner-side premium bumps within
  their slippage tolerance.
- **`spell()` is unrestricted**: any `target`+`calldata` combination is
  delegatecalled from the contract's context. Because `vault` has
  pre-approved this contract for its `aEthwstETH`, a compromised or
  malicious `owner` can drain the entire approved allowance via `spell`.
  This is a trust assumption, not a bug. Do not rely on this contract as
  trust-minimized custody for the `vault` operator.
- **No reentrancy guard**: the contract relies on Aave V3's
  `finalizeTransfer` hook semantics (which themselves do not re-enter into
  arbitrary user code) to prevent reentrancy. Aave V3 aToken `transferFrom`
  does call into `Pool` for health factor validation but does not invoke
  recipient hooks.
- **`profitReceiver` transfer only occurs if `profit > 0`**: when
  `premium == 0` there can still be a 1-wei discrepancy due to independent
  rounding of `fullAmount` and `amountOut`; if non-zero, a third
  `transferFrom` to `profitReceiver` will be executed. This is expected.
- **Stable debt not tracked**: `_checkDebtCeiling` only reads
  `variableDebtEthWETH`. Aave V3 stable borrow was disabled
  governance-side in 2023. If the `vault` was bootstrapped before that and
  still holds stable debt, the invariant is understated. Pre-deployment
  check: run `CheckMellowBalances` script against the chosen vault address.

## Known design constraints

- **Single-pair**: hardcoded to `aEthWETH ↔ aEthwstETH`. A separate
  deployment is required for any other Aave V3 market or any other vault.
- **Single vault source**: `vault` is immutable. If the vault migrates
  the leveraged position to a different contract, this swap contract must
  be redeployed.
- **Non-upgradeable**: no proxy. Any logic change requires a fresh
  deployment and a re-approval from `vault`.

## Testing

```bash
forge test -vvv
forge test --fork-url $MAINNET_RPC -vvv    # integration tests against live Aave state
```

Suggested test coverage at minimum:

- Premium computation edge cases (`premium = 0`, `premium = PREMIUM_PRECISION − 1`, `premium ≥ PREMIUM_PRECISION` reverts)
- Debt-ceiling invariant (swap succeeds when `debt > supply`, reverts when equal or less)
- Slippage protection (`amountOut < amountOutMin` reverts)
- Pause/unpause gating
- Zero-address construction reverts
- `swapToWstETHWithReferral` emits `ReferralRecorded` with correct `user` and `referral`, and forwards to `swapToWstETH`
- `spell()` executes delegatecall and propagates revert data
