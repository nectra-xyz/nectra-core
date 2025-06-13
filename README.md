# Nectra Core

Nectra is a decentralized borrowing protocol allowing users to borrow nUSD (Nectra USD) against [Citrea](https://citrea.xyz) BTC (cBTC). 

The nUSD token is a soft-pegged USD stablecoin, over-collateralized with cBTC deposits. The Bitcoin collateral supports the floor price of the stablecoin through the ability to redeem nUSD for \$1 equivalent of cBTC directly. Protocol arbitrage enforces a ceiling on the nUSD price.

When creating a loan, termed a "position", users select their preferred annual interest rate. The position's interest rate determines whether it is redeemed against during a redemption, with positions paying a lower interest rate being redeemed first. 

The protocol implements partial and full liquidations to ensure that nUSD remains overcollateralized.

Nectra’s core lending and stablecoin protocol is immutable once deployed and entirely permissionless. 

# Table of Contents

- [Borrowing](#borrowing)
  - [User-Defined Interest Rate](#user-defined-interest-rate)
  - [Opening Fee](#opening-fee)
  - [ERC-721 Positions](#erc-721-positions)
  - [Delegable Permissions](#delegable-permissions)
- [Leverage](#leverage)
- [Redemptions](#redemptions)
  - [Ordering and Risk](#ordering-and-risk)
  - [Profitability](#profitability)
  - [Redemption Fee](#redemption-fee)
- [Flash Functionality](#flash-functionality)
  - [Flash Mint](#flash-mint)
  - [Flash Borrow](#flash-borrow)
- [Liquidations](#liquidations)
  - [Partial Liquidations](#partial-liquidations)
  - [Liquidation Functions](#liquidation-functions)
  - [Socialized Liquidations](#socialized-liquidations)
- [Stability Mechanisms](#stability-mechanisms)
  - [nUSD < \$1](#nusd--1)
  - [nUSD > \$1](#nusd--1)
- [Contract Architecture](#contract-architecture)
  - [Core Contracts](#core-contracts)
  - [Supporting Contracts](#supporting-contracts)
- [Interacting with the Protocol](#interacting-with-the-protocol)
  - [Creating a Position](#creating-a-position)
  - [Modifying a Position](#modifying-a-position)
  - [Closing a Position](#closing-a-position)
  - [Liquidating Positions](#liquidating-positions)
  - [Redeeming nUSD for Collateral](#redeeming-nusd-for-collateral)


# Borrowing

Users can deposit cBTC into Nectra as collateral to borrow nUSD through over-collateralized loans. 

The maximum Loan-to-Value (LTV) of a position is 83.3% when opening a position. The liquidation LTV is 90.9%.

To close a position, users must repay the initial position debt amount in full, in addition to any accrued interest.

## User-Defined Interest Rate

When opening a position, users must specify the annual interest rate they prefer to pay.

Interest rates are specified in increments of 10 bips. Positions that share the same interest rate in the system are put into a “bucket”. Positions in the bucket can have varying collateralization ratios (c-ratios), reflecting the individual position’s level of collateral-to-debt ratio. The c-ratio is an indication of the health of the position. 

Once a position has been opened, users can adjust the position's interest rate based on their personal strategies or market conditions.

Interest accrues on a per-second basis on the debt amount within each position. The system charges the accumulated interest of an entire bucket (i.e., all the positions in the bucket) whenever an action is performed on the bucket. Accruing interest at a bucket level improves the efficiency of the system and ensures a more continuous collection of fees.

## Opening Fee

When creating a new position, an "opening fee" of 0.2% is allocated as part of a position's debt, although it is not immediately charged. As interest accrues in the position, the fee is gradually paid off and is considered fully settled once the position's interest exceeds the fee amount. If a user reduces their interest rate, they will be charged the remaining fee amount, and a new opening fee will be applied to their outstanding debt. Increasing the interest rate of a position does not realize the fee, but it will cause the opening fee to be paid off faster due to the higher interest rate.

Repaying debt will trigger a pro-rata portion of the outstanding fee, calculated based on the amount being repaid. Increasing a position's debt will result in a 0.2% charge on the increase, which will be added to the outstanding fee amount.

This mechanism is designed to discourage users from temporarily increasing their interest rates to avoid redemptions, which target lower interest rate buckets.

## ERC-721 Positions

Each position is represented as an ERC-721 non-fungible token, making positions easily transferable between addresses. Each position's collateral and debt are isolated, so transferring a position does not impact the recipient’s other open positions.

## Delegable Permissions

**Interest Rate Management**

Position owners can delegate the management of their position's [interest rate](#user-defined-interest-rate) to another address. The permitted address can increase or decrease the position's interest rate, but cannot make any other changes to the position.

**Position Management**

Position owners can also delegate the authority to manage their position's collateral and debt amounts to a designated address, enabling proactive risk management against liquidation. 

**Note: Any collateral or debt withdrawn by the manager is transferred to the manager's address to enable the use of [flash borrow](#flash-borrow) to create leverage.**

# Leverage

Users can create leveraged cBTC exposure through Nectra. After creating a position, the issued nUSD is used to acquire cBTC, which is then used as additional collateral for the position. The loop can be performed several times to increase leverage. 

Nectra's system maximum LTV of 83.3% caps the maximum obtainable leverage at 5.68X. 

Using the [flash borrow](#flash-borrow) functionality to borrow cBTC allows users to create leverage fairly simply 

For example, a user with \$100 of cBTC who wants 3x leverage could:

1. **Flash borrow** \$200 of cBTC.
2. **Deposit** the original \$100 cBTC + the \$200 borrowed cBTC (\$300 total collateral).
3. **Withdraw** \$202 nUSD (\$2 nUSD will be used to pay the swap and flash borrow fees).
4. **Swap** the \$202 nUSD for approximately \$201 cBTC (after ~0.5% fees).
5. **Repay** the \$200 cBTC flash borrow using their newly acquired \$201 cBTC (with ~ 0.5% fees).

The result is approximately \$300 worth of cBTC exposure with a debt of \$202 nUSD, resulting in an LTV of roughly 67.33% (\$202 / \$300).

**Warning: Using leverage increases your exposure to the price movement of cBTC and, thus, the likelihood of being [liquidated](#liquidating-positions). Use with caution.**

# Redemptions

To maintain nUSD’s peg, redemptions allow any user to redeem 1 nUSD for \$1 of cBTC.

If the price of nUSD falls below \$1, arbitrageurs can buy nUSD on the open market to redeem the underlying collateral from Nectra for a profit. 

## Ordering and Risk

When redemptions occur, buckets are redeemed in order of the buckets with the lowest interest rate to the highest interest rate. Collateral is redeemed at 1:1, thereby paying off the associated debt. If a bucket no longer has any remaining collateral, the next lowest bucket will be redeemed against.

Within a bucket, redemptions are applied proportionally across all outstanding positions. The distribution of redemptions ensures that they are distributed fairly among borrowers offering the same interest rate.

## Profitability

The potential profit from redemption arbitrage can be calculated as follows:

$$
\text{Profit} = \text{RedemptionAmount} \times (1 - \text{nUSDPrice} - \text{RedemptionFee})
$$

Where:

- $\text{Profit}$ represents the potential earnings from a single redemption arbitrage transaction.
- $\text{RedemptionAmount}$ is the amount of nUSD being used for the redemption.
- $\text{1}$ is the target peg price of nUSD.
- $\text{nUSDPrice}$ is the current market price of nUSD (which would be below \$1 to make arbitrage profitable).
- $\text{RedemptionFee}$ is the fee charged by the Nectra protocol for performing a redemption.

This calculation shows that a profit can be made when the cost of acquiring nUSD (at the market price) plus the redemption fee is less than the value of the cBTC received (\$1 per nUSD redeemed). 

The larger the trade size and the greater the difference between \$1 and the sum of the nUSD price and redemption fee, the higher the potential profit.

## Redemption Fee

To manage the pace of redemptions, a dynamic redemption fee is applied on top of a 0.5% base fee and is paid to the Savings Account module. This fee scales upwards with increasing redemption volume, acting as a temporary deterrent, and then gradually decreases over 6 hours to help the system return to equilibrium. 

The redemption fee comprises 3 components: the base fee ($f_{min}$) of 0.5%, a linearly decaying buffer based on time, and the proportion between the current redemption amount and the nUSD total supply. The linearly decaying factor at time $t_i$ is calculated as:

$$
\beta_{(t_i)} = \beta_{(t_{i-1})}\times(1 - \frac{\Delta t}{P})
$$

Where:

- $\beta_{t_i}$ represents the current value for the linearly decaying buffer.
- $\beta_{(t_{i-1})}$ represents the previous value for the linearly decaying buffer.
- $\Delta t$ represents the time since the buffers' last update time, measured in seconds.
- $P$ represents the configured period that resets the buffer to 0

By combining all 3 components, the redemption fee rate can be calculated for time $t_i$ using:

$$
f(t_i) = f_{min} + \frac{K \times [(\beta_{(t_i)} + T) \times \ln(\frac{T}{T - a}) - a]}{a}
$$

Where:

- $f_{min}$ is being used to represent the base redemption fee rate of 0.5%.
- $K$ represents a constant spike scaler, currently set to 1.
- $a$ is used to represent the amount of nUSD being redeemed.
- $T$ represents the total supply of nUSD.

After $\beta_{t_i}$ is used to calculate the redemption fee, the buffer is increased by the redemption amount, and the buffer's last update time is set to the current time.

# Flash Functionality

## Flash Mint

Nectra offers a "flash mint" feature that allows anyone to borrow unlimited nUSD without providing collateral. The borrowed amount and a fee of 0.25% (paid to the Savings Account module) must be returned within the same transaction. To ensure system stability during a flash mint, redemptions, Savings Account deposits (to avoid JIT attacks), and liquidations are temporarily blocked. 

A key benefit for borrowers is the ability to repay debt and withdraw cBTC collateral in a single transaction without needing the upfront nUSD required. For example, a user can flash mint nUSD, repay their loan, withdraw cBTC, and then sell that cBTC for nUSD within the same transaction to settle the flash mint and its fee, allowing efficient debt and collateral management. 

## Flash Borrow

Nectra also offers a “flash borrow” function, allowing users to atomically borrow the underlying cBTC collateral for a 0.25% fee (paid to the Savings Account module), provided it's repaid within the same transaction. As highlighted in the [leverage](#leverage) section, this feature allows positions to increase their cBTC exposure without the need for a nUSD-to-cBTC swap loop, making it more efficient by saving on gas and potentially DEX fees.

# Liquidations

## Partial Liquidations

Nectra employs partial liquidations to safeguard the system when a borrowing position's LTV reaches 90.9%. During such an event, nUSD is repaid to the system to reduce the outstanding debt, and a liquidation penalty is applied.

The liquidator earns a share of this penalty, capped at $10 worth of cBTC, while the remainder of the fee is paid to the Savings Account module. 

**Calculating nUSD Required to Fix LTV**

The nUSD required to pay for the liquidation can be provided from several sources and is calculated using the following formulas:

$$
\text{nUSDtoFixLTV} = \frac{\text{Debt} \times \text{IR} - \text{Collateral} \times \text{Price}}{\text{IR} - 1}
$$

Where:

- $\text{nUSDtoFixLTV}$ represents the nUSD required to adjust the position's LTV to the maximum LTV.
- $\text{Debt}$ is the current amount of nUSD borrowed by the user.
- $\text{IR}$ denotes the issuance ratio, the target LTV expressed as a percentage, for example, 83.3%.
- $\text{Collateral}$ refers to the amount of cBTC that has been deposited as collateral.
- $\text{Price}$ indicates the current market price of cBTC.

**Calculating Liquidation Penalty in nUSD**

$$
\text{PenaltynUSD} = \text{nUSDtoFixLTV} \times \text{Penalty}
$$

Where:

- $\text{PenaltynUSD}$ represents the additional debt that will be burned from the account to cover the liquidation penalty.
- $\text{Penalty}$ refers to the liquidation penalty, currently set to 15%.

**Calculating Total Liquidation Cost**

$$
\text{LiquidationCost} = \text{nUSDtoFixLTV + PenaltynUSD}
$$

**Liquidation Cost** represents the total nUSD required by a liquidator. The total collateral reward for a given liquidation is calculated as:

$$
\text{PenaltycBTC} = \frac{\text{PenaltynUSD} \times \text{IR}}{\text{Price}}
$$

The resulting cBTC penalty is divided into two parts when a liquidation occurs. 10% of the penalty is directed to the Savings Account module, and up to $10 worth of the 90% share is allocated to the liquidator. Any amount exceeding $10 will be sent to the Savings Account module.

## Liquidation Functions

Nectra offers several options for partial liquidations.

**Savings Account Module Liquidations**

The Savings Account module can source nUSD from:

- Flash minting
- Idle nUSD deposited into the Savings Account
- Temporarily withdrawing nUSD from Savings Account yield generation strategies

After the liquidation, the underlying collateral is sold to return the system to its original state, in addition to the fees received. The liquidation penalty is earned by the Savings Account Module. The cBTC reward received by the liquidator can be calculated as:

**Public Liquidations**

Individuals can use their nUSD (or nUSD acquired through other sources) to perform liquidations. Users receive an equivalent amount of cBTC and a share of the liquidation penalty. The amount of cBTC received from a self-funded liquidation can be calculated using: 

$$
\text{cBTCReceived} = \frac{ \text{nUSDtoFixLTV}}{\text{Price}} + \text{PenaltycBTC} \times 0.9
$$

While the liquidator will be fully reimbursed for their nUSD in the form of cBTC, the value of the cBTC reward they receive from the penalty cBTC is capped at $10.

**Flash and Liquidate**

The "flash mint" function allows users to perform public liquidations without having the required nUSD. The acquired cBTC is then swapped for nUSD through a DEX to repay the borrowed amount. The liquidator's reward is a portion of the liquidation penalty, minus any DEX fees, slippage incurred during the cBTC-to-nUSD swap, and the flash mint fee. The remaining portion of the penalty is allocated to the Savings Account module. The liquidator's reward is calculated as:

$$
\text{cBTCReceived} = \text{PenaltycBTC}\times 0.9-\text{SwapLoss}-\text{FlashFee}
$$

## Socialized Liquidations

As a last resort, if a position approaches the point of going underwater (95.2% LTV), its debt and collateral can be proportionally distributed to other positions in the system based on their existing debt. 

This debt-share distribution helps prevent cascading liquidation issues. Before redistribution, a fixed value reward of 10 nUSD is added to the liquidated positions’ debt and rewarded to the caller.

# Stability Mechanisms

## nUSD < $1

Nectra's primary mechanism for supporting the nUSD price when it falls below $1 is redemptions. Redemptions create a price floor, as market participants can profitably arbitrage the difference by purchasing undervalued nUSD and redeeming it for $1 worth of cBTC from the system, thus increasing the nUSD price back towards its peg.

A period of high demand for redemptions also creates a second-order effect. Borrowers are incentivized to temporarily increase their interest rates to reduce their risk of redemption, and the redemption fees themselves rise with volume. Since the interest and redemption fees are streamed to the Savings Account module, users are further incentivized to acquire discounted nUSD on the market and deposit it into the treasury pool to capture a portion of these earnings. Doing so reduces the circulating supply of nUSD.

## nUSD > $1

If the market price of nUSD exceeds $1, Nectra incentivizes cBTC holders to deposit their assets as collateral and mint new nUSD at the prevailing cBTC:USD oracle price.

Newly minted nUSD can then be sold on the open market for a value greater than $1, increasing the circulating supply and exerting downward pressure on the price, thereby diminishing the arbitrage opportunity for further price increases. Once the price stabilizes back down to the $1 peg, arbitrageurs can repurchase the nUSD at its intended price to repay their initial position.

# Contract Architecture

The protocol consists of several core contracts that work together to provide lending functionality:

## Core Contracts

1. **Nectra.sol**
  - The main contract that inherits from all other functionality contracts
  - Handles position creation, modification, and management
  - Key functions:
    - `modifyPosition`: Create, modify, or close a position
    - `quoteModifyPosition`: Get a quote for position modification
    - `updatePosition`: Update position state with the latest interest

2. **NectraLiquidate.sol**
  - Handles position liquidation
  - Implements:
    - Partial liquidation
    - Full liquidation
    - Liquidator rewards
  - Key functions:
    - `liquidate`: Partially liquidate an undercollateralized position
    - `fullLiquidate`: Fully liquidate a severely undercollateralized position

3. **NectraRedeem.sol**
  - Handles redemption of nUSD for collateral
  - Implements:
    - Dynamic redemption fees
    - Bucket-based redemption
    - Redemption buffer management
  - Key functions:
    - `redeem`: Redeem nUSD for collateral
    - `_redeemFromBuckets`: Internal redemption logic
    - `_calculateRedemptionFeeAndUpdateBuffer`: Fee calculation

4. **NectraFlash.sol**
  - Handles flash loans and flash mints
  - Implements:
    - Flash loan cBTC functionality
    - Flash mint nUSD functionality
    - Circuit breaker protection
  - Key functions:
    - `flashLoan`: Execute a flash loan
    - `flashMint`: Execute a flash mint
    - `_requireFlashBorrowUnlocked`: Circuit breaker check

5. **NectraNFT.sol**
  - ERC721 token representing positions
  - Handles position ownership and permissions
  - Key functions:
    - `mint`: Create a new position
    - `authorize`: Grant permission to manage the position
    - `revoke`: Revoke position management permission

6. **NUSDToken.sol**
  - ERC20 token representing borrowed nUSD
  - Implements minting and burning with access control
  - Key functions:
    - `mint`: Create new nUSD tokens
    - `burn`: Destroy nUSD tokens
    - `permit`: Gasless approvals

7. **OracleAggregator.sol**
  - Price feed aggregation
  - Provides:
    - Collateral price updates
    - Price staleness checks
    - Fallback oracle support
  - Key functions:
    - `getLatestPrice`: Get the most recent valid price
    - `_tryGetPrice`: Internal price fetching with staleness check
    - `_normalize`: Normalize price to 18 decimals

## Supporting Contracts

1. **NectraBase.sol**
  - Base contract containing shared state and constants
  - Defines core data structures:
    - `Globals`: System-wide state
    - `Bucket`: Interest rate bucket state
    - `Position`: Individual position state

2. **NectraLib.sol**
  - Core library for state management and calculations
  - Handles:
    - Position and bucket state updates
    - Interest calculations
    - Debt share conversions
    - Liquidation calculations

3. **NectraMathLib.sol**
  - Mathematical operations library
  - Provides:
    - Share/asset conversions
    - Safe math operations
    - Bit searching utilities

4. **NectraViews.sol**
  - Read-only functions for querying protocol state
  - Key functions:
    - `getPosition`: Get position collateral and debt
    - `getBucketState`: Get bucket state
    - `getGlobalState`: Get system-wide state
    - `canLiquidate`: Check liquidation eligibility

# Interacting with the Protocol

## Creating a Position

1. Approve NUSD token for the Nectra contract
2. Call `modifyPosition` with:
    - `tokenId`: 0 (for new position)
    - `depositOrWithdraw`: Amount of collateral to deposit (positive)
    - `borrowOrRepay`: Amount of nUSD to borrow (positive)
    - `interestRate`: Desired interest rate bucket
    - `permit`: Optional permit data for NUSD token approval

```solidity
function modifyPosition(
    uint256 tokenId,
    int256 depositOrWithdraw,
    int256 borrowOrRepay,
    uint256 interestRate,
    bytes calldata permit
) external payable returns (
    uint256 tokenId, 
    int256 depositOrWithdraw, 
    int256 borrowOrRepay,
    uint256 collateral,
    uint256 effectiveDebt);
```

**Returns:**
- `tokenId`: ID of the newly created position
- `depositOrWithdraw`: Actual amount of collateral deposited
- `borrowOrRepay`: Actual amount of nUSD borrowed
- `collateral`: The total collateral in the position after modification
- `effectiveDebt`: The total effective debt of the position after modification

## Modifying a Position

1. Ensure you have permission (owner or authorized)
2. Call `modifyPosition` with:
    - Position token ID
    - Collateral change (positive for deposit, negative for withdrawal)
    - Debt change (positive for borrow, negative for repay)
    - New desired interest rate

## Closing a Position
1. Ensure you have permission (owner or authorized)
2. Call `modifyPosition` with:
   - Position token ID
   - Collateral change `type(int256).min`
   - Debt change `type(int256).min`
   - New desired interest rate

**NOTE:** All collateral deposits require the deposit amount of cBTC to be passed as `msg.value`. All repayments require the repayment amount of nUSD to be approved to the `Nectra` contract or a valid permit to be passed.

## Liquidating Positions

**Check liquidation eligibility:**
Call the views `canLiquidate` or `canLiquidateFull` with:
- `tokenId`: ID of the position to liquidate

```solidity
// Returns true when the positions c-ratio < LIQUIDATION_THRESHOLD
function canLiquidate(uint256 tokenId) external view returns (bool);

// Returns true when the positions c-ration < FULL_LIQUIDATION_THRESHOL
function canLiquidateFull(uint256 tokenId) external view returns (bool);
```
The functions return:
- `true` if the position is liquidatable.


**Call liquidation function:**

For partial liquidation, call `liquidate` with:
- `tokenId`: ID of the position to liquidate

```solidity
function liquidate(uint256 tokenId) external;
```

**Token flow:**
  - The contract must be approved to burn nUSD from the liquidator
  - The liquidator will receive cBTC to repay for the burnt nUSD, plus a reward amount

**NOTE:** The actual amount of collateral received depends on:
- Current collateral price
- Liquidation penalty
- Position's collateralization ratio
- Amount of debt repaid

For full liquidation, call `fullLiquidate` with:
- `tokenId`: ID of the position to liquidate

```solidity
function fullLiquidate(
    uint256 tokenId,
    uint256 maxDebtToRepay,
    uint256 minCollateralToReceive
) external;
```
**Token flow:**
  - The liquidator will receive a fixed amount of nUSD as a reward


## Redeeming nUSD for Collateral

The redeem function allows users to exchange nUSD for cBTC collateral at a discount. The redemption process follows a bucket-based approach, starting from the lowest interest rate bucket.

Call `redeem()` with:
- `nusdAmount`: Amount of nUSD to redeem
- `minCollateralToReceive`: Minimum amount of cBTC expected in return

```solidity
function redeem(
    uint256 nusdAmount,
    uint256 minAmountOut
) external returns (uint256 collateralRedeemed);
```

**Returns:**
- `collateralRedeemed`: The amount of collateral received by the redeemer

**Token Flow:**
  - The contract must be approved to burn nUSD from the redeemer
  - Redeemer will receive cBTC to repay for the burnt nUSD, less the redemption fee

**NOTE:** The actual amount of collateral received depends on:
- Current collateral price
- Redemption fee rate
