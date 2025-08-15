# RemitX 

RemitX is a modular DeFi protocol for Bitcoin and multi-asset yield, lending, and swapping. It features a yield vault, lending pool, swap DEX, and custodian for asset conversions, all designed for composability and extensibility.

---

## Contracts Overview

### 1. YieldVault

- **Purpose:** Accepts wBTC and supported LSTs, converts them to lstBTC via a custodian, and distributes yield to depositors.
- **Features:**  
  - Multi-asset deposits (wBTC, LSTs)
  - Shares-based accounting
  - Performance & management fees
  - Flexible withdrawals (wBTC or LST)
  - Automated rebalancing
  - Emergency controls

### 2. LendingPool

- **Purpose:** Allows users to deposit wBTC/lstBTC as collateral and borrow supported tokens, with interest accrual and health factor tracking.
- **Features:**  
  - Dual collateral system (wBTC, lstBTC)
  - Compound interest model
  - Borrow/repay with multiple tokens
  - Health factor & liquidation logic
  - Owner-managed liquidity reserves

### 3. Swap

- **Purpose:** Decentralized exchange for token swaps and liquidity provision, using TCORE2 as the native token.
- **Features:**  
  - Pool-based swaps (TCORE2/ERC20, ERC20/ERC20)
  - Liquidity provider rewards
  - Fee distribution (providers, burning, platform)
  - Pool creation and management
  - Provider profile and earnings withdrawal

### 4. Custodian

- **Purpose:** Handles conversions between wBTC, LSTs, and lstBTC at fixed rates for simplicity.
- **Features:**  
  - 1:1 conversion functions for all supported pairs
  - Emits conversion events for transparency

### 5. BTCStaking

- **Purpose:** Mock staking contract for wBTC, mints lstBTC at a 1:1 ratio for testing.
- **Features:**  
  - Stake/unstake logic
  - Reward minting
  - User staking tracking

---

## How It Works

- **Deposit:** Users deposit wBTC or LSTs into the YieldVault, which converts assets to lstBTC via the Custodian.
- **Yield:** Vault participants earn yield from staking rewards, distributed periodically.
- **Borrow:** Users can use their wBTC/lstBTC as collateral in the LendingPool to borrow supported tokens.
- **Swap:** The Swap contract enables token swaps and liquidity provision, rewarding providers.
- **Conversion:** The Custodian contract handles all asset conversions between wBTC, LSTs, and lstBTC.

---

## Key Events

- Deposits, withdrawals, swaps, liquidity provision/removal, yield distribution, fee collection, and conversions are all tracked via events for transparency.

---

## Security

- Uses OpenZeppelin’s `Ownable`, `ReentrancyGuard`, and `Pausable` for access control and safety.
- Emergency withdrawal and pause functions are available.

---

## Getting Started

1. **Deploy contracts in order:**  
   - Deploy BTCStaking, Custodian, and TestPriceFeed.
   - Deploy YieldVault, LendingPool, and Swap, passing addresses of dependencies.
2. **Add supported tokens and pools as needed.**
3. **Interact via deposit, borrow, swap, and liquidity functions.**

---

## License

MIT (YieldVault, LendingPool, BTCStaking, Custodian)  
GPL-3.0 (Swap)

---

For details, see the respective contract files in core.  
Interfaces and price feeds are in interfaces and feeds.
