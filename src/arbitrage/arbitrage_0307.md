**This EA implements a classic pairs‑trading / statistical‑arbitrage mean‑reversion on two gold instruments: it builds a smoothed reference for the price *spread* (mid B − mid A), enters two‑leg hedged trades when the spread deviates beyond absolute thresholds, and manages risk with time, profit and adverse‑move cutoffs. It is *not* a true z‑score strategy because it uses a smoothed mean but no rolling standard‑deviation normalization — you can improve it by adding a volatility standardizer (z‑score) or a cointegration hedge ratio.**   [BJF Trading Group Inc.](https://bjftradinggroup.com/optimizing-pair-trading-using-the-z-index-technique/)  [FasterCapital](https://fastercapital.com/content/Z-Score--Z-Score--Decoding-Market-Signals-in-Pairs-Trading.html)

### How the code forms the trading signal
- **Spread definition:** the EA computes the instantaneous spread as the mid price of leg B minus the mid price of leg A.  
- **Smoothed reference (mean):** it updates a running exponential‑style reference `g_ref` using a time‑based smoothing factor `SmoothSecs` (`g_ref+=k*(v-g_ref);`). This is the EA’s estimate of the long‑run mean of the spread (code: `UpdateRef`).  
- **Entry math:** it computes two directional deviations `d1 = bBid - aAsk` and `d2 = bAsk - aBid` and then compares them to the smoothed reference via `e1 = d1 - g_ref` and `e2 = g_ref - d2`. If `d1 >= MinLevel && e1 >= EntryThresh` it opens the *main* direction; if reversed and allowed it uses `e2`. The code shows these exact calculations: **`double d1=bBid-aAsk, d2=bAsk-aBid; double e1=d1-g_ref, e2=g_ref-d2;`**.  
  These are **absolute** deviations in price units, not standardized z‑scores.

### Position construction and sizing
- **Two‑leg execution:** leg B is placed first, then leg A; if A fails the EA attempts to unwind B. This reduces one‑leg orphan risk but still relies on cleanup logic.  
- **Sizing:** tiered lot sizing (`BaseLot`, `Tier2Lot`, `Tier3Lot`) is chosen by the magnitude of deviation (`LotFor(e)`), and an optional **tick‑value scaling** (`ScaleSecondLeg`) converts lot sizes between instruments using tick values to keep P&L exposure balanced.

### Risk controls and operational guards
- **Liquidity & freshness checks:** rejects entries if spreads exceed `MaxSpreadA/B` or if ticks are stale (`StaleTickSec`).  
- **Concurrency & timing:** limits concurrent pairs (`MaxConcurrent`) and enforces `MinSecsBetween` between new entries.  
- **Exit rules:** profit target (`TargetClose`), max adverse (`MaxAdverse`), max hold hours (`MaxHoldH`), and a cleanup timer for orphan legs. These are explicit, deterministic exits rather than probabilistic stop rules.

### Statistical critique and recommended improvements
- **Not a z‑score:** the EA uses a smoothed mean but **does not divide by a rolling standard deviation**, so thresholds are in price units and will misbehave when volatility changes. For robust signals compute a rolling or EWMA standard deviation and use  
  \(\textbf{z} = \dfrac{\text{spread} - \mu}{\sigma}\) and trigger on \(|z|>\) threshold.   [Github](https://github.com/gregkitz/PairsBot/blob/main/docs/technical/strategies/zscore_strategy_implementation.md)  [FasterCapital](https://fastercapital.com/content/Z-Score--Z-Score--Decoding-Market-Signals-in-Pairs-Trading.html)  
- **Hedge ratio:** use OLS or cointegration (Engle‑Granger / Johansen) to estimate the optimal hedge ratio rather than 1:1 or tick‑value scaling; Kalman filtering can adapt intraday.   [Github](https://github.com/gregkitz/PairsBot/blob/main/docs/technical/strategies/zscore_strategy_implementation.md)
- **Execution & model risks:** watch for contract expiry (the EA already has `ExpiryB`), liquidity gaps, one‑leg fills, and regime shifts — add regime detection or volatility‑adjusted thresholds.   [BJF Trading Group Inc.](https://bjftradinggroup.com/optimizing-pair-trading-using-the-z-index-technique/)

### Practical takeaway
- **This is a mean‑reversion pairs EA that needs a volatility normalizer (z‑score) and a statistically estimated hedge ratio to be a true, robust statistical‑arbitrage system.** Implement rolling std, cointegration/OLS hedge, and slippage‑aware backtests before live deployment.