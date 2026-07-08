**Your EA is already a profitable mean‑reversion pairs system; to *increase edge and reduce losses* focus on (1) converting absolute thresholds into volatility‑normalized z‑scores, (2) estimating an adaptive hedge ratio (cointegration/Kalman), and (3) optimizing exits and execution with walk‑forward/Bayesian search — these three changes typically give the largest lift in Sharpe and lower drawdowns.**  

### Quick comparison of high‑impact improvements
| **Improvement** | **Primary benefit** | **Tradeoff / cost** | **Implementation complexity** | **Priority** |
|---|---:|---|---:|---:|
| **Z‑score (volatility normalize)** | Stable thresholds across regimes | Needs rolling/EWMA σ; more params | Medium | **High** |
| **Adaptive hedge ratio (OLS/cointegration/Kalman)** | Better hedge, fewer false signals | More computation; model risk | Medium‑High | **High** |
| **Execution & slippage model** | Fewer orphan legs, better fills | Requires tick/backfill data | Medium | **High** |
| **Dynamic sizing (volatility/edge scaled)** | Higher returns per unit risk | More parameter tuning | Medium | Medium |
| **Bayesian / genetic optimization + walk‑forward** | Robust parameter selection | Compute heavy; needs cross‑validation | High | **High** |

---

### Why these matter (technical rationale)
- **Normalize by volatility:** your EA currently uses absolute deviations (`double d1=bBid-aAsk, d2=bAsk-aBid;`) and an EWMA mean (`g_ref+=k*(v-g_ref);`) which gives *price‑unit* signals that break when volatility shifts. Convert to  
  \(\;z_t=(\text{spread}_t-\mu_t)/\sigma_t\;\) and trigger on \(|z|>\) threshold to keep false‑positive rate stable across regimes. **This is the single biggest robustness fix.**   [Amberdata Blog](https://blog.amberdata.io/constructing-your-strategy-with-logs-hedge-ratios-and-z-scores)  
  The EA code shows the raw spread and EWMA update: **`double d1=bBid-aAsk, d2=bAsk-aBid;`** and **`g_ref+=k*(v-g_ref);`** (from your EA).
- **Estimate hedge ratio, not 1:1:** use OLS on log prices or Engle‑Granger cointegration to compute \( \beta\) so spread = \(p_B - \beta p_A\). For intraday adaptivity use a Kalman filter to track \(\beta_t\). This reduces structural bias and improves mean‑reversion validity.   [arXiv.org](https://arxiv.org/html/2412.12555v1)  [Amberdata Blog](https://blog.amberdata.io/constructing-your-strategy-with-logs-hedge-ratios-and-z-scores)
- **Execution & orphan‑leg handling:** place smaller limit/IOC slices, simulate realistic slippage, and add a pre‑trade liquidity filter (tick depth or volume). Model transient retcodes and add retry/backoff logic; your code already unwinds failed legs but can be improved with staged limit orders and simulated fill models.   [Github](https://github.com/rishavsofer/Dynamic-Pair-Trading-Strategy-Optimization-Using-Bayesian-Methods)

---

### Optimization framework (practical recipe)
1. **Define objective(s):** maximize **Sharpe** or **Sortino**, constrain **max drawdown** and **max adverse per trade**.  
2. **Parameterize:** z‑entry, z‑exit, EWMA half‑life for μ and σ, hedge ratio window/Kalman noise, sizing rules, min liquidity, slippage model.  
3. **Search method:** use **Bayesian optimization** for global search + **genetic** for discrete choices; always validate with **rolling walk‑forward** (e.g., 6m train / 1m test) to avoid overfitting.   [Github](https://github.com/rishavsofer/Dynamic-Pair-Trading-Strategy-Optimization-Using-Bayesian-Methods)  [arXiv.org](https://arxiv.org/html/2412.12555v1)  
4. **Metrics to monitor:** **win rate, average win/loss, expectancy, Sharpe, max drawdown, orphan‑leg frequency**.  
5. **Live controls:** add volatility‑based dynamic thresholds, kill‑switch on unusual fills, and continuous re‑estimation of cointegration.

---

### Risks and final notes
- **Model risk:** cointegration can break; monitor stationarity tests (ADF) and stop trading when p‑value rises.   [Amberdata Blog](https://blog.amberdata.io/constructing-your-strategy-with-logs-hedge-ratios-and-z-scores)  
- **Execution risk:** one‑leg fills and expiry mismatches remain primary operational hazards — simulate tick‑level fills before increasing size.  
- **Next step:** I can draft a prioritized implementation plan and a walk‑forward test matrix (train/test windows, objective function) if you want — tell me your backtest data horizon and compute budget.