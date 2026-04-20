# LidoATokenSwap

A single-purpose swap contract that enables users to exchange `aEthWETH` for
`aEthwstETH` at the oracle-derived wstETH→stETH rate with a configurable fee.
The contract acts as a de-leveraging rail for a specific Mellow Core Vaults
subvault that holds a leveraged wstETH-collateral / WETH-debt position on
Aave V3 Ethereum.

## Motivation

A Mellow subvault running a looped wstETH strategy on Aave V3 accumulates
`aEthwstETH` collateral against `variableDebtEthWETH`. To reduce leverage
without routing wstETH through a DEX (which would drive depeg and eat into
the position's net value on stress events), the subvault pre-approves this
contract to move `aEthwstETH` on its behalf. End users holding `aEthWETH` in
Aave V3 can then:

1. Transfer `aEthWETH` directly to the subvault (increasing its WETH supply).
2. Receive `aEthwstETH` from the subvault at the oracle rate, minus a fee.

The net effect on the subvault is `+amountIn aEthWETH, −fullAmount aEthwstETH`,
and the additional `aEthWETH` is subsequently used by the subvault curator
to call `Pool.repay(WETH, …)`, burning an equivalent amount of
`variableDebtEthWETH` and reducing the position's WETH short.

From the user's perspective, this is an atomic aToken-to-aToken swap that
preserves their Aave V3 health factor and avoids DEX slippage on wstETH.

## Architecture

```
┌────────────┐  aEthWETH.transferFrom(user, subvault, amountIn)
│    User    ├──────────────────────────────────────────────────────┐
└────────────┘                                                      │
       ▲         aEthwstETH.transferFrom(subvault, user, amountOut) │
       │                                                            ▼
       │                                              ┌──────────────────────┐
       │                                              │  Mellow Subvault     │
       │                                              │  (Aave V3 position:  │
       │                                              │   aEthwstETH collat, │
       │                                              │   variableDebtEth-   │
       │                                              │   WETH debt)         │
       │                                              └──────────────────────┘
       │      aEthwstETH.transferFrom(subvault, FEE_RECIPIENT, fee)
       └──────────────────────────────────────────────────────────────▲
                                                                      │
                                                            ┌─────────┴─────────┐
                                                            │   FEE_RECIPIENT   │
                                                            └───────────────────┘
```

### Invariants

1. **Debt-ceiling invariant** (`_checkDebtCeiling`): after every swap, the
   subvault's `variableDebtEthWETH` balance must remain strictly greater than
   its `aEthWETH` balance. Once parity is reached, swaps automatically revert
   with `DebtCeilingBreached` — the contract is, by design, a one-shot
   de-leveraging tool and disables itself when the subvault is no longer
   net-short WETH.

2. **Oracle pricing** is derived from `wstETH.stEthPerToken()` — the protocol
   redemption rate, not a market price. Users are exposed to the basis
   between market wstETH/stETH and the NAV rate; the fee is intended to
   cover both the subvault's de-leveraging premium and, indirectly, any
   small NAV/market drift.

3. **Fee accounting** uses basis points (`FEE_BASIS = 10000`, `MAX_FEE = 1000`
   — a 10% hard cap). Fee is computed in input-token terms first, then
   converted to output-token terms at the current oracle rate, so the
   invariant `fee = 0 ⇒ profit = 0` holds exactly.

### Roles

| Role            | Address holder         | Capabilities                                         |
|-----------------|------------------------|------------------------------------------------------|
| `OWNER`         | immutable              | `setFee`, `pause`, `unpause`, `initialize`           |
| `MELLOW_SUBVAULT` | immutable            | Source of `aEthwstETH` liquidity; recipient of user `aEthWETH` |
| `FEE_RECIPIENT` | immutable              | Receives fee in `aEthwstETH` on every swap           |

All three are set once in the constructor and cannot be changed. Zero-address
checks are enforced at construction.

## Storage

ERC-7201 namespaced storage is used to support upgradeable proxy deployments:

```
namespace: "Lido.LidoATokenSwap"
slot:      keccak256(abi.encode(uint256(keccak256("Lido.LidoATokenSwap")) - 1)) & ~bytes32(uint256(0xff))
```

Storage struct:

```solidity
struct LidoATokenSwapStorage {
    uint256 fee;       // current fee in bps, 0 ≤ fee ≤ MAX_FEE
    bool    isPaused;  // swap circuit-breaker
    uint256 version;   // initializer guard; type(uint256).max on direct-deploy
}
```

The implementation contract's constructor sets `version = type(uint256).max`
to disable `initialize()` on the implementation itself (proxy-safety pattern).

## Deployment

The contract is designed to be deployed behind an `OssifiableProxy`
(ERC-1967-based). The deployment flow:

1. Deploy `LidoATokenSwap` as implementation. Constructor sets immutables
   (`OWNER`, `MELLOW_SUBVAULT`, `FEE_RECIPIENT`) and disables the initializer
   on the implementation storage.
2. Deploy `OssifiableProxy` pointing at the implementation.
3. Call `initialize()` on the proxy — only possible once, only callable by
   `OWNER`, which sets `version = 1` and `isPaused = true`.
4. `OWNER` calls `setFee(<bps>)` to configure the fee.
5. Mellow curator, via the subvault's `CallModule` + `VerifierModule` flow,
   calls `aEthwstETH.approve(<swapContractProxy>, type(uint256).max)` from
   the subvault address.
6. `OWNER` calls `unpause()` to open the swap.

## Usage

### For users

```solidity
// 1. Approve the swap contract to pull aEthWETH
aEthWETH.approve(swapContract, amountIn);

// 2. Compute expected output off-chain or via view function
uint256 expected = swapContract.getWstETHAmountOut(amountIn);
uint256 minOut   = expected * 99 / 100; // 1% slippage tolerance

// 3. Swap
uint256 out = swapContract.swapToWstETH(amountIn, minOut);
// or with referral tag:
uint256 out = swapContract.swapToWstETH(amountIn, minOut, referralAddr);
```

### View helpers

| Function                          | Returns                                                  |
|-----------------------------------|----------------------------------------------------------|
| `getWstETHAmountOut(amountIn)`    | Expected `aEthwstETH` output for given `aEthWETH` input  |
| `getWstETHFeeInOutput(amountIn)`  | Fee portion, denominated in `aEthwstETH`                 |
| `getWstETHRate()`                 | Current raw `wstETH.stEthPerToken()`                     |
| `getWstETHRateWithFee()`          | Effective rate user pays (rate × BASIS / (BASIS − fee))  |
| `availableWstETHLiquidity()`      | `min(balance, allowance)` of subvault's `aEthwstETH`     |
| `maxSwapFromDebtCeiling()`        | Upper bound on `amountIn` from debt-ceiling invariant    |
| `maxSwapToWstETH()`               | True max swap, accounting for both liquidity and ceiling |
| `isPaused()` / `getFee()`         | Current state                                            |

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

- `owner_` — admin multisig
- `mellowVault_` — Mellow subvault address holding the Aave position
  (**not** the user-facing Vault contract; see
  [docs.mellow.finance](https://docs.mellow.finance/core-vaults/architecture))
- `feeRecipient_` — address receiving fee accrual in `aEthwstETH`

## Known design constraints

- **Single-pair**: hardcoded to `aEthWETH ↔ aEthwstETH`. A separate deployment
  is required for any other Aave V3 market or any other subvault.
- **Single subvault source**: `MELLOW_SUBVAULT` is immutable. If Mellow migrates
  the leveraged position to a different subvault contract, this swap contract
  must be redeployed.
- **Fee changes are instant**: `setFee` takes effect in the next block. Users
  relying on `getWstETHAmountOut` for slippage calculation must use
  `amountOutMin` to protect against fee bumps inside slippage tolerance.
- **Stable-debt not tracked**: `_checkDebtCeiling` only reads
  `variableDebtEthWETH`. Aave V3 stable borrow was disabled governance-side
  in 2023, so this is expected to match reality; but if the subvault was
  bootstrapped before that disable and still holds stable debt, the invariant
  is inaccurate. Pre-deployment check: run `CheckMellowBalances` script against
  the chosen subvault.

## Testing

```bash
forge test -vvv
forge test --fork-url $MAINNET_RPC -vvv    # integration tests against live Aave state
```

Unit tests should at minimum cover:

- Fee computation edge cases (`fee = 0`, `fee = MAX_FEE`, `fee > MAX_FEE` reverts)
- Debt-ceiling invariant (swap succeeds when `debt > supply`, reverts when equal or less)
- Slippage protection (`amountOut < amountOutMin` reverts)
- Pause/unpause gating
- Initializer (cannot be called twice, cannot be called on implementation directly)
- Referral parameter is forwarded into event payload

## License

MIT.