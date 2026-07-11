//+------------------------------------------------------------------+
//|                                          ZX_PP_M5_v3.mq5         |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "5.12"

//+------------------------------------------------------------------+
//| ZX_PP_M5_v3 — built from ZX_PP_M5_v2, adding two targeted trailing- |
//| stop improvements. Everything else (ATR-relative momentum SL,        |
//| fixed 0.27 lot sizing, breakeven, QuickStop, continuation re-entry,  |
//| mean-reversion SL/TP) carries over completely unchanged.             |
//|                                                                        |
//| V3-A - THIRD PROFIT-LOCK TIER:                                       |
//|   The existing progressive trail had two tiers (1xATR->0.5, 2xATR-> |
//|   0.3) then held flat at that tightest multiplier no matter how far   |
//|   a trend extended beyond 2xATR. A trade that runs to 4-5x ATR in     |
//|   profit was still only protected by the same 0.3xATR cushion as one  |
//|   sitting at exactly 2xATR - giving back proportionally more of a     |
//|   big winner than a small one. New Tier 3 (default: profit >=         |
//|   3.5xATR -> mult=0.2) tightens further once a trend is clearly       |
//|   extended. Same ratchet-forward-only mechanics as Tiers 1-2; set     |
//|   UseProgressiveProfitLock=false to disable all three tiers exactly   |
//|   as before.                                                          |
//|                                                                         |
//| V3-B - GIVEBACK GUARD (NEW):                                          |
//|   The ATR trail's distance is a function of CURRENT ATR - if a trade   |
//|   spikes hard in its favor on one or two bars (e.g. a news candle)     |
//|   and then reverses just as fast, the ATR-based trail can still give   |
//|   back a large fraction of that spike before it catches up, because    |
//|   ATR itself is a lagging, averaged measure and doesn't jump as fast    |
//|   as a single-bar price extreme does. New UseGivebackGuard (default    |
//|   true) adds a THIRD candidate stop, independent of ATR: it looks at   |
//|   the highest favorable price actually reached since the position      |
//|   opened (via iHighest/iLowest over the position's own lifetime bars   |
//|   on the current timeframe - no persistent per-ticket state needed,    |
//|   so it's exact even across EA restarts) and locks in AT LEAST         |
//|   (100 - Giveback_Max_Pct)% of that peak favorable excursion, once      |
//|   peak profit has reached Trail_StartPoints:                           |
//|      peakPts = (peak favorable price - open price) in points           |
//|      guardSL = open price + peakPts * (1 - Giveback_Max_Pct/100)       |
//|   Default Giveback_Max_Pct=35 means a trade can give back at most 35%  |
//|   of its best-ever open profit before the guard's candidate stop       |
//|   overtakes the ATR trail candidate. Both candidates are computed      |
//|   every tick and the SL still only ever moves to whichever is MOST     |
//|   protective and strictly better than the current SL - same ratchet-   |
//|   forward-only rule as Stage 1/Stage 2 already use, so this can only    |
//|   tighten protection, never loosen it, and never fires before          |
//|   Trail_StartPoints regardless of how fast price moved. Set             |
//|   UseGivebackGuard=false to disable and trail on ATR alone exactly as   |
//|   v2 did.                                                              |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ZX_PP_M5_v2 — built from ZX_PP_M5_v1, replacing the static          |
//| Fixed_SL_Points momentum SL with an ATR-relative SL. Everything      |
//| from v1 (fixed 0.27 lot sizing) and everything from PP/v1-v4 below   |
//| (ATR-relative breakeven, MeanRev_Mode direction gating, dedicated    |
//| mean-reversion SL/TP, gated legacy secondary TP, RR-linked TP,       |
//| quick-stop loss cutting, progressive profit-lock trail, continuation |
//| re-entry) carries over completely unchanged EXCEPT for momentum SL.  |
//|                                                                        |
//| MOMENTUM SL NOW ATR-RELATIVE (V2-A):                                  |
//|   Every other exit mechanism in this EA already scales with live M5   |
//|   ATR - mean-reversion SL/TP (MeanRev_SL_ATR_Mult/MeanRev_TP_ATR_Mult),|
//|   breakeven (BreakEven_TriggerATR_Mult/BreakEven_LockATR_Mult), the    |
//|   Stage-2 trail (Trail_ATR_Mult and the PP-A progressive tiers), and   |
//|   QuickStop (QuickStop_ATR_Mult) - except the momentum trade's own     |
//|   broker-side backstop SL, which was still a static Fixed_SL_Points    |
//|   (1503pts) regardless of what ATR was doing that session.            |
//|                                                                         |
//|   New UseATR_RelativeSL (default true) makes the momentum SL follow    |
//|   the same pattern as everything else:                                |
//|      sl_pts = clamp(ATR_pts * Momentum_SL_ATR_Mult(1.2),               |
//|                      Momentum_Min_SL_Points(80), Momentum_Max_SL_Points(250)) |
//|   On a quiet session both the momentum SL and the mean-reversion SL    |
//|   (ATR*0.7) now shrink together; on a volatile session both widen      |
//|   together; the ratio between them (~1.2/0.7 = 1.7x) stays roughly     |
//|   constant regardless of what ATR is doing. Set UseATR_RelativeSL =    |
//|   false to fall back to the exact old static Fixed_SL_Points behavior  |
//|   for A/B comparison - that input is left in place, untouched, and is  |
//|   still what's used when the toggle is off.                            |
//|                                                                         |
//|   RR-LINKED TP FOLLOWS THE NEW SL: TP_MODE_RR previously computed      |
//|   tp_points = Fixed_SL_Points * TP_RiskReward_Ratio, i.e. always off    |
//|   the static 1503pt value even when UseATR_RelativeSL made the actual  |
//|   SL something else entirely. GetSLTP() now computes TP_MODE_RR's TP   |
//|   off whichever SL distance (in points) is actually in effect that     |
//|   trade - static or ATR-relative - so the RR ratio stays honest to the |
//|   real risk being taken, not to a fixed number that may no longer      |
//|   reflect it. TP_MODE_ATR and the mean-reversion branch are untouched. |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ZX_PP_M5_v1 — built from FX_M5_Scalp_PP, renamed and with lot       |
//| sizing locked back to a fixed value. Everything from v1-v4 and PP    |
//| (ATR-relative breakeven, MeanRev_Mode direction gating, dedicated    |
//| mean-reversion SL/TP, gated legacy secondary TP, RR-linked TP,       |
//| quick-stop loss cutting, progressive profit-lock trail, continuation |
//| re-entry) carries over completely unchanged EXCEPT for lot sizing.   |
//|                                                                        |
//| LOT SIZE LOCKED TO Fixed_Entry_Lot (ALWAYS 0.27):                     |
//|   FX_M5_Scalp_v2 introduced risk-based lot sizing (sizing each trade  |
//|   off its own sl_dist and RiskPercent, controllable via UseRiskSizing)|
//|   so mean-reversion and momentum trades - which can have very         |
//|   different SL distances - would risk a comparable DOLLAR amount      |
//|   instead of a comparable LOT size. Per explicit request, that is     |
//|   bypassed here: CalcLot() now unconditionally returns Fixed_Entry_Lot|
//|   (0.27) for every single entry, regardless of UseRiskSizing or       |
//|   sl_dist - momentum or mean-reversion, BUY or SELL, always the same  |
//|   0.27 lots (still bounded by MinLot/MaxLot for broker safety).       |
//|   UseRiskSizing/RiskPercent inputs are left in the file, now unused,  |
//|   purely so restoring risk-based sizing later is a one-function       |
//|   change rather than a rewrite.                                       |
//|                                                                         |
//|   WORTH KNOWING: this reintroduces the exact dollar-risk inconsistency |
//|   v2 was built to fix - a mean-reversion trade's tight ATR-relative SL |
//|   (~20-100pts) and a momentum trade's wide 1503pt Fixed_SL_Points SL   |
//|   now once again risk very different dollar amounts at the identical   |
//|   0.27 lots, since dollar risk = lot size x SL distance x point value, |
//|   and only lot size is held constant now. This is a deliberate,        |
//|   explicitly requested tradeoff, not an oversight.                     |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| FX_M5_Scalp_PP — built from FX_M5_Scalp_v4, addressing profit       |
//| give-back on volatile pullbacks (e.g. Gold). Everything from v1-v4   |
//| (ATR-relative breakeven, MeanRev_Mode direction gating, dedicated    |
//| mean-reversion SL/TP, risk-based lot sizing, gated legacy secondary  |
//| TP, RR-linked TP, quick-stop loss cutting) carries over completely   |
//| unchanged. A third proposed item (partial scale-out - closing part   |
//| of the position at a profit milestone) was intentionally NOT         |
//| included in this version; it was flagged as a bigger, separate       |
//| change worth validating PP-A/PP-B first before adding.               |
//|                                                                        |
//| PP-A - PROGRESSIVE PROFIT-LOCK TRAIL:                                 |
//|   Trail_ATR_Mult was previously a single FLAT ratio applied           |
//|   regardless of how much profit had already built up - a trade up     |
//|   500pts on Gold gave back the exact same proportional cushion as a   |
//|   trade up 50pts. New UseProgressiveProfitLock (default true) tiers   |
//|   the Stage-2 trail multiplier tighter as profit grows relative to    |
//|   ATR:                                                                 |
//|      profit >= ProfitLock_Tier2_ATR_Trigger(2.0)*ATR -> mult=ProfitLock_Tier2_Mult(0.3) |
//|      profit >= ProfitLock_Tier1_ATR_Trigger(1.0)*ATR -> mult=ProfitLock_Tier1_Mult(0.5) |
//|      otherwise                                        -> mult=Trail_ATR_Mult(0.8, unchanged) |
//|   New helper GetProgressiveTrailMult() computes this per-position,    |
//|   per-tick, inside ManageTrailing() - trailDist is no longer computed |
//|   once at the top of the function, it's now computed per-position     |
//|   using each position's own live profitPts. Still layered onto the    |
//|   exact same "most protective, ratchet forward only, never loosens"   |
//|   logic. Breakeven (Stage 1) and the broker-side SL from GetSLTP()    |
//|   are untouched. Set UseProgressiveProfitLock=false to revert to the  |
//|   old flat Trail_ATR_Mult behavior for every trade regardless of      |
//|   profit size.                                                        |
//|                                                                         |
//| PP-B - CONTINUATION RE-ENTRY:                                          |
//|   When PP-A tightens the SL and price pulls back onto it, the broker   |
//|   closes the position asynchronously, between ticks - outside any      |
//|   function this EA calls directly. Previously the EA just sat out the  |
//|   rest of the candle even if the underlying trend was still intact.    |
//|   New UseContinuationReentry (default true): OnTick() now captures     |
//|   HasPosition() at the very start of every tick and compares it        |
//|   against the previous tick's end-of-tick state (new global            |
//|   PrevHadPosition). If a position was open last tick and is gone now,  |
//|   AND the deal that closed it (via new helper GetLastDealProfit(),     |
//|   which reads the most recent DEAL_ENTRY_OUT deal from history) was    |
//|   profitable, the EA immediately re-evaluates DecideDirection() and    |
//|   resets the M1-confirmation counters (M1BarsElapsed/LastM1Time) so    |
//|   CheckM1Confirmation() can fire again in the SAME candle rather than   |
//|   waiting for the next M5 rollover. A losing broker-side close does    |
//|   NOT trigger this - deliberately different from PP-A itself, which    |
//|   only tightens stops (never closes), and from QuickStop (v4), which   |
//|   still closes losers itself and still waits for the next candle.      |
//|   Explicit closes by this EA's own code (QuickStop, CheckProfitTarget, |
//|   HandleCandleEndClose) are naturally excluded from this mechanism -   |
//|   HasPosition() is still true at the point in the tick where the       |
//|   detection check runs, before those functions get a chance to close   |
//|   anything. Set UseContinuationReentry=false to disable this check     |
//|   entirely and always wait for the next M5 candle, regardless of how   |
//|   a position closed - the exact v4 behavior.                           |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| FX_M5_Scalp_v4 — built from FX_M5_Scalp_v3, adding a quick-stop     |
//| loss-cutting check. Everything from v1-v3 (ATR-relative breakeven,   |
//| MeanRev_Mode direction gating, dedicated mean-reversion SL/TP,       |
//| risk-based lot sizing, gated legacy secondary TP, RR-linked TP)      |
//| carries over completely unchanged.                                    |
//|                                                                        |
//| V4-A - QUICK-STOP LOSS CUTTING:                                       |
//|   Prior to v4, only the WIN side of a trade was actively monitored     |
//|   every tick (CheckProfitTarget/ManageTrailing). A losing trade was    |
//|   left alone until it hit the broker-side SL (1503pts for momentum,    |
//|   the tighter ATR-relative SL for mean-reversion) - HandleCandleEndClose|
//|   only force-closes trades that are flat-to-winning (profit >= -$1),   |
//|   so a trade losing more than that keeps running. New ManageQuickStop()|
//|   adds a second, EA-managed, tighter loss threshold checked every tick:|
//|      quickStopPts = MAX(QuickStop_Min_Points, ATR_pts * QuickStop_ATR_Mult) |
//|   Once a position's floating loss reaches this distance, it is closed  |
//|   immediately - no hedge order, no averaging order, no basket. This    |
//|   is NOT a replacement for the broker-side SL from GetSLTP(), which    |
//|   is completely untouched and still exists as the catastrophic         |
//|   backstop. A grace period (QuickStop_GraceM1Bars, measured from each  |
//|   position's own POSITION_TIME) delays evaluation briefly after entry  |
//|   so normal spread/entry noise doesn't trigger an instant close.       |
//|   Deliberately does NOT reset TradeOpenThisCandle on close (unlike     |
//|   CheckProfitTarget()'s early-profit exit) - a quick-stopped trade     |
//|   means this candle's setup didn't work, so re-entry waits for the     |
//|   next M5 candle rather than immediately retrying same-candle          |
//|   conditions, avoiding a chase/revenge-entry pattern. Set              |
//|   UseQuickStop=false to disable this check entirely and revert to      |
//|   the exact old v3 behavior (losing trades run to SL/candle-end only). |
//|   Nothing else - breakeven, trailing, RR-linked TP, risk-based lot     |
//|   sizing, mean-reversion logic - was touched by this change.           |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| FX_M5_Scalp_v3 — built from FX_M5_Scalp_v2, adding the             |
//| risk:reward-linked TP for momentum trades. Everything from v2       |
//| (risk-based lot sizing, gated legacy secondary TP) and everything    |
//| from v1 (ATR-relative breakeven, MeanRev_Mode direction gating,      |
//| dedicated mean-reversion SL/TP) carries over completely unchanged.   |
//|                                                                       |
//| V3-A - RISK:REWARD-LINKED TP:                                        |
//|   Momentum-trade TP previously came only from ATR (ATR_TP_Mult),     |
//|   capped at Max_TP_Points=150 - vs a Fixed_SL_Points of 1503, a      |
//|   ~1:10 reward:risk ratio on paper. New TP_Mode input defaults to    |
//|   TP_MODE_RR, which ties TP directly to the SL distance instead:     |
//|      tp_points = Fixed_SL_Points * TP_RiskReward_Ratio               |
//|   Default TP_RiskReward_Ratio=0.5 -> TP ~= 751pts (5x the old 150pt  |
//|   cap), bounded by RR_Min_TP_Points/RR_Max_TP_Points. Set            |
//|   TP_Mode=TP_MODE_ATR to revert to the exact old ATR-based behavior  |
//|   with zero other changes - both code paths live side by side in    |
//|   GetSLTP(). This only changes where the TP price level is set for   |
//|   MOMENTUM trades (isMeanRev=false); the mean-reversion branch's own |
//|   dedicated ATR-relative SL/TP (MeanRev_TP_ATR_Mult etc., from v1)   |
//|   is completely untouched and still computed separately. It also     |
//|   does not touch breakeven, trailing, risk-based lot sizing, or the  |
//|   legacy-TP gating from v2 - all of which still manage/gate exits    |
//|   independently and will usually close trades well before either SL  |
//|   or the new RR-linked TP is reached.                                |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| FX_M5_Scalp_v2 — built from FX_M5_Scalp_v1, adding 2 fixes that     |
//| directly interact with (and were partially undermined by) v1's      |
//| mean-reversion changes. Nothing else from v1 was touched - the      |
//| ATR-relative breakeven, MeanRev_Mode direction gating, and          |
//| dedicated mean-reversion SL/TP all carry over unchanged.            |
//|                                                                       |
//| V2-A - RISK-BASED LOT SIZING:                                        |
//|   v1 gave mean-reversion trades their own tighter ATR-relative SL    |
//|   (as low as a 15pt floor) while momentum trades kept the wide       |
//|   1503pt Fixed_SL_Points backstop - but CalcLot() ignored sl_dist    |
//|   entirely and always returned the same fixed lot for both, so the   |
//|   two trade types ended up risking wildly different dollar amounts   |
//|   per trade purely by accident. CalcLot() now sizes off the ACTUAL   |
//|   sl_dist passed in for that specific trade and RiskPercent (the     |
//|   existing UseRiskSizing/RiskPercent inputs, previously dead code,   |
//|   are now live), so every trade risks a comparable share of account  |
//|   balance regardless of which branch opened it. Set                  |
//|   UseRiskSizing=false to revert to the old fixed Fixed_Entry_Lot     |
//|   behavior (still bounded by MinLot/MaxLot) for comparison.          |
//|                                                                        |
//| V2-B - LEGACY SECONDARY TP GATING:                                    |
//|   CheckProfitTarget() ran a hardcoded $12.03 fixed-dollar close AND   |
//|   an ATR*2.0 points-based close, unconditionally, on every trade -    |
//|   on top of whatever TP GetSLTP() actually set on the order. Since    |
//|   v1's mean-reversion trades carry a deliberately small ATR-relative  |
//|   TP (as low as a 20pt floor), these legacy checks could silently     |
//|   override that intended target. Both checks are now gated behind    |
//|   UseLegacySecondaryTP (default false), so GetSLTP()'s price-level    |
//|   TP is the EA's sole active target. Set UseLegacySecondaryTP = true  |
//|   to restore the exact old always-on behavior for side-by-side        |
//|   comparison - nothing else in CheckProfitTarget() changed, and       |
//|   HandleCandleEndClose(), ManageTrailing(), and the mean-reversion     |
//|   entry logic are all completely untouched by this change.            |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| FX_M5_Scalp_v1 — built from YX_M5_scalper_v7_breakeven_stop,       |
//| porting 3 specific fixes forward from the YX_M5_scalper_v12/v13    |
//| line (which diverged from v7 earlier). Nothing else from v7 was    |
//| touched - no ladder, no loss-recovery, no legacy-TP gating, no     |
//| EMA-extension filter, no RR TP mode - those all stay exactly as    |
//| they were in v7, or are simply absent, by design (not requested).  |
//|                                                                     |
//| CHANGE #1 - ATR-RELATIVE BREAKEVEN:                                 |
//|   v7's breakeven stage used flat point values                      |
//|   (BreakEven_TriggerPoints=15, BreakEven_LockPoints=5) regardless   |
//|   of volatility - tight on a volatile session (stopped out by      |
//|   normal noise/spread), loose on a quiet one (gave up more of the  |
//|   available move than necessary). New UseATR_BreakEven (default    |
//|   true) scales both distances with live M5 ATR, same as the        |
//|   existing ATR trail (Stage 2) already does:                       |
//|      effTrigger = MAX(BreakEven_TriggerPoints, ATR_pts * BreakEven_TriggerATR_Mult) |
//|      effLock    = MAX(BreakEven_LockPoints,    ATR_pts * BreakEven_LockATR_Mult)    |
//|   BreakEven_TriggerPoints/BreakEven_LockPoints are kept as FLOORS - |
//|   quiet-day behavior is never tighter than v7 was, it only widens   |
//|   when ATR justifies it. Set UseATR_BreakEven=false to revert to    |
//|   the exact old fixed-point-only behavior. Only ManageTrailing()'s  |
//|   Stage 1 candidate calculation changed - Stage 2 (ATR trail), the  |
//|   "most protective, ratchet forward only" logic, HandleCandleEndClose(), |
//|   and CheckProfitTarget() are all untouched.                        |
//|                                                                      |
//| CHANGE #2 - MEAN-REVERSION DIRECTION FIX:                           |
//|   In v7, the mean-reversion branch inside CheckM1Confirmation() ran  |
//|   on every candle where DecideDirection() had ALREADY picked a       |
//|   trend-following bias (CandleDirection = BUY/SELL), and could fire  |
//|   in the OPPOSITE direction of that bias with no check at all - e.g. |
//|   trend says BUY, mean-reversion RSI reads overbought and fires a    |
//|   contradicting SELL on the same candle. True range/no-trend         |
//|   candles (CandleDirection = SKIP), the natural home for a           |
//|   reversion trade, never got evaluated for mean reversion at all.    |
//|   New MeanRev_Mode input (default MEANREV_SKIP_ONLY) only allows     |
//|   mean reversion to fire on candles where DecideDirection() found no |
//|   trend - a genuine contrarian/range regime that no longer fights    |
//|   the trend engine for the same entry slot. The OnTick() gate that   |
//|   used to skip CheckM1Confirmation() entirely on SKIP candles now    |
//|   still calls it in this mode, purely so the mean-reversion branch   |
//|   gets evaluated; the momentum-confirmation branch further down is   |
//|   unaffected since it explicitly requires CandleDirection=="BUY"/"SELL". |
//|   MEANREV_AGREE_WITH_TREND and MEANREV_INDEPENDENT (the exact old    |
//|   v7 behavior) are also available for comparison testing.            |
//|                                                                       |
//| CHANGE #4 - DEDICATED MEAN-REVERSION SL/TP:                          |
//|   v7 routed every trade - mean-reversion or momentum - through the   |
//|   same GetSLTP(): the wide Fixed_SL_Points backstop (1503pts) and    |
//|   the ATR*3-based TP built for trend-continuation trades. A          |
//|   reversion trade is a different bet (a fast snap back toward the    |
//|   mean, with quick invalidation if wrong), so it now gets its own    |
//|   ATR-relative SL/TP:                                                |
//|      MeanRev TP = clamp(ATR_pts * MeanRev_TP_ATR_Mult, MeanRev_Min_TP_Points, MeanRev_Max_TP_Points) |
//|      MeanRev SL = clamp(ATR_pts * MeanRev_SL_ATR_Mult, MeanRev_Min_SL_Points, MeanRev_Max_SL_Points) |
//|   GetSLTP() gained an isMeanRev parameter (default false = 100%      |
//|   unchanged trend-engine path). ExecuteBuy()/ExecuteSell() gained    |
//|   the same isMeanRev parameter (default false) and pass it straight  |
//|   through; only the two mean-reversion entry calls inside            |
//|   CheckM1Confirmation() now pass true - the momentum-confirmation    |
//|   branch is untouched and still defaults to false, so its SL/TP is   |
//|   byte-for-byte identical to v7. Mean-reversion trades are tagged    |
//|   with a distinct order comment ("M5v4 BUY MR"/"M5v4 SELL MR") for   |
//|   identification in trade history; this has no effect on management  |
//|   since v7 has no comment-based exclusion logic to begin with.       |
//|   Set UseMeanRev_DedicatedExits=false to fall back to sharing        |
//|   GetSLTP() with momentum trades exactly like v7 did.                |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| YX M5 Scalper v7 — FIXED LOT + BREAKEVEN STOP edition              |
//| Quant Only Closed Candle M1 RSI + Mean Reversion                  |
//| Lower entry thresholds for more trades on both sides              |
//| Same optimized exit logic as v3                                   |
//|                                                                    |
//| CHANGES IN THIS VERSION (vs YX_M5_scalper_v7_fixedlot_0.27):      |
//|  3. Added a BREAKEVEN STOP stage ahead of the existing ATR trail. |
//|     - New inputs: UseBreakEven, BreakEven_TriggerPoints (15),      |
//|       BreakEven_LockPoints (5).                                   |
//|     - As soon as a trade is up BreakEven_TriggerPoints, its SL is  |
//|       moved to entry price (+/- BreakEven_LockPoints), locking in |
//|       a small guaranteed profit well before the ATR trail (which   |
//|       only starts at the wider Trail_StartPoints) would engage.   |
//|     - ManageTrailing() now computes BOTH the breakeven candidate   |
//|       and the ATR-trail candidate every tick, and only ever moves  |
//|       the SL to whichever is MOST protective and strictly better   |
//|       than the current SL - so the stop always ratchets forward,  |
//|       never back, and Stage 2 (ATR trail) naturally overtakes      |
//|       Stage 1 (breakeven) once the trade runs far enough.          |
//|     - See the "*** BREAKEVEN + ATR TRAIL CHANGE ***" comment block |
//|       above ManageTrailing() for full details.                    |
//|                                                                    |
//|  Carried over from YX_M5_scalper_v7_fixedlot_0.27:                |
//|  1. Entry lot is hard-coded to 0.27 for BUY and SELL (CalcLot()).  |
//|  2. Fixed_SL_Points default = 1503.                                |
//|     NOTE: with the breakeven stop now active, most winning trades  |
//|     will have their risk cut to near-zero long before this wide    |
//|     initial SL would ever be hit - but the 1503-vs-150(TP) risk:   |
//|     reward skew on trades that go straight against you still       |
//|     applies and is worth revisiting separately.                   |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
// NOTE: LotSize is kept here only for reference / backward compatibility with
// the rest of the code base. It is NOT used for sizing - see the note above
// CalcLot() for what actually sizes trades in ZX_PP_M5_v1 (always
// Fixed_Entry_Lot, unconditionally).
input double LotSize = 0.10;              // (unused for sizing — see CalcLot())
input long MagicNumber = 20260607;

//=== FIXED LOT SIZE (ALWAYS APPLIED TO EVERY ENTRY) ===
// ZX_PP_M5_v1: CalcLot() always returns this value for every entry -
// momentum or mean-reversion, BUY or SELL - regardless of UseRiskSizing or
// sl_dist. This is the single source of truth for trade volume in this EA
// version. See the note above CalcLot() for the full rationale.
input double Fixed_Entry_Lot = 0.27;      // Fixed lot size used for ALL entries, always

//=== SL/TP SETTINGS ===
input double Fixed_SL_Points = 1503;      // Fixed SL distance in points (e.g. price 4060 → SL 2557) - used only when UseATR_RelativeSL=false
input double ATR_TP_Mult = 3.0;           // TP multiplier based on ATR (only used when TP_Mode = TP_MODE_ATR)
input double Max_TP_Points = 150;         // Cap TP at this many points in ATR mode (avoid too high)
input double Min_TP_Points = 40;          // Minimum TP in ATR mode to ensure worthwhile trades

//=== V2-A: ATR-RELATIVE MOMENTUM SL (NEW, ZX_PP_M5_v2) ===
// Replaces the static Fixed_SL_Points momentum backstop with an ATR-relative
// one, consistent with mean-reversion SL (MeanRev_SL_ATR_Mult), breakeven
// (BreakEven_TriggerATR_Mult/BreakEven_LockATR_Mult), the Stage-2 trail
// (Trail_ATR_Mult), and QuickStop (QuickStop_ATR_Mult) - all of which already
// scale with live ATR. See the V2-A header note above for the full rationale.
// Set UseATR_RelativeSL=false to revert to the exact old static
// Fixed_SL_Points behavior for A/B comparison.
input bool   UseATR_RelativeSL      = true;  // Scale momentum SL with live ATR instead of a static Fixed_SL_Points value
input double Momentum_SL_ATR_Mult   = 1.2;   // Momentum SL = ATR_pts * this (clamped by the two lines below)
input double Momentum_Min_SL_Points = 80;    // Safety floor for ATR-relative momentum SL
input double Momentum_Max_SL_Points = 250;   // Safety ceiling for ATR-relative momentum SL

//=== V3-A: RISK:REWARD-LINKED TP (NEW, FX_M5_Scalp_v3) ===
// Previously TP came only from ATR (ATR_TP_Mult), capped at Max_TP_Points=150
// - vs a Fixed_SL_Points of 1503, a ~1:10 reward:risk ratio on paper. New
// TP_Mode input defaults to TP_MODE_RR, which ties TP directly to the SL
// distance instead:
//    tp_points = Fixed_SL_Points * TP_RiskReward_Ratio
// Default TP_RiskReward_Ratio=0.5 -> TP ~= 751pts (5x the old 150pt cap),
// bounded by RR_Min_TP_Points/RR_Max_TP_Points. Set TP_Mode = TP_MODE_ATR to
// revert to the exact old ATR-based behavior with zero other changes - both
// code paths live side by side in GetSLTP(). This only changes where the TP
// price level is set for MOMENTUM trades; it does not touch breakeven,
// trailing, or the mean-reversion branch's own dedicated ATR-relative
// SL/TP (MeanRev_TP_ATR_Mult etc.), which is untouched and still computed
// separately in GetSLTP()'s isMeanRev branch.
enum ENUM_TP_MODE
{
   TP_MODE_ATR,   // Old behavior: TP = ATR_pts * ATR_TP_Mult, clamped by Min_TP_Points/Max_TP_Points
   TP_MODE_RR     // (default) New behavior: TP = Fixed_SL_Points * TP_RiskReward_Ratio, clamped by RR_Min_TP_Points/RR_Max_TP_Points
};
input ENUM_TP_MODE TP_Mode              = TP_MODE_RR; // How momentum-trade TP is calculated
input double       TP_RiskReward_Ratio  = 0.5;        // tp_points = Fixed_SL_Points * this (only used when TP_Mode = TP_MODE_RR)
input double       RR_Min_TP_Points     = 40;         // Safety floor for TP in RR mode
input double       RR_Max_TP_Points     = 900;        // Safety ceiling for TP in RR mode (0 = no cap)

//=== #3 HOLD WINNERS PAST CANDLE (IMPROVED) ===
input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;    // REDUCED from 30 - catch smaller trends
input double HoldTrailBuffer = 10;        // Keep trail buffer this far behind price

//=== #4 TRAILING STOP (OPTIMIZED) ===
input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 0.8;        // REDUCED from 1.0 - tighter trail
input int Trail_StartPoints = 25;         // REDUCED from 40 - trail earlier
input int Trail_StepPoints = 15;          // Move SL by this much when trailing

//=== PP-A: PROGRESSIVE PROFIT-LOCK TRAIL (NEW, FX_M5_Scalp_PP) ===
// Trail_ATR_Mult above was a single FLAT ratio applied no matter how much
// profit had already built up - a trade up 500pts on Gold gave back the
// exact same proportional cushion as a trade up 50pts on a pullback. On a
// volatile instrument like Gold, that fixed cushion can hand back a large
// share of an already-good move on a sharp snapback. This adds tiers that
// TIGHTEN the trail distance as profit grows relative to ATR - once
// UseProgressiveProfitLock is on, the Stage-2 ATR-trail multiplier
// (otherwise Trail_ATR_Mult) is replaced by a smaller multiplier once
// profit crosses each ATR-relative milestone:
//    profit >= ProfitLock_Tier2_ATR_Trigger * ATR  -> mult = ProfitLock_Tier2_Mult (tightest)
//    profit >= ProfitLock_Tier1_ATR_Trigger * ATR  -> mult = ProfitLock_Tier1_Mult
//    otherwise                                      -> mult = Trail_ATR_Mult (unchanged Stage-2 default)
// This only ever produces a TIGHTER trail than before at a given profit
// level, layered onto the exact same "most protective, ratchet forward
// only, never loosens" logic ManageTrailing() already used. Breakeven
// (Stage 1) and the broker-side SL from GetSLTP() are completely
// untouched. Set UseProgressiveProfitLock=false to revert to the old flat
// Trail_ATR_Mult behavior for every trade regardless of profit size.
input bool   UseProgressiveProfitLock     = true;
input double ProfitLock_Tier1_ATR_Trigger = 1.0;  // Profit (in ATR multiples) needed to enter Tier 1
input double ProfitLock_Tier1_Mult        = 0.5;  // Trail multiplier once Tier 1 is reached (tighter than Trail_ATR_Mult)
input double ProfitLock_Tier2_ATR_Trigger = 2.0;  // Profit (in ATR multiples) needed to enter Tier 2
input double ProfitLock_Tier2_Mult        = 0.3;  // Trail multiplier once Tier 2 is reached (tightest, pre-v3)

//=== V3-A: THIRD PROFIT-LOCK TIER (NEW, ZX_PP_M5_v3) ===
// Extends the same progressive tiering one step further for trades that run
// well beyond Tier 2 - previously they stayed at ProfitLock_Tier2_Mult (0.3)
// forever, no matter how extended the move got. See V3-A header note above
// for the full rationale. Only takes effect when UseProgressiveProfitLock=true.
input double ProfitLock_Tier3_ATR_Trigger = 3.5;  // Profit (in ATR multiples) needed to enter Tier 3
input double ProfitLock_Tier3_Mult        = 0.2;  // Trail multiplier once Tier 3 is reached (tightest overall)

//=== V3-B: GIVEBACK GUARD (NEW, ZX_PP_M5_v3) ===
// Adds a THIRD trailing candidate, independent of ATR: locks in at least
// (100 - Giveback_Max_Pct)% of the best favorable excursion the trade has
// ever reached (found via iHighest/iLowest over the position's own lifetime
// - no persistent per-ticket state needed). Protects against a sharp spike-
// then-reverse move giving back more than intended before the ATR-based
// trail (which lags, since ATR is itself an average) catches up. See the
// V3-B header note above for the full rationale. Set UseGivebackGuard=false
// to trail on ATR alone exactly as v2 did.
input bool   UseGivebackGuard   = true;
input double Giveback_Max_Pct   = 35;   // Max % of peak favorable profit allowed to be given back before the guard tightens the stop

//=== PP-B: CONTINUATION RE-ENTRY (NEW, FX_M5_Scalp_PP) ===
// When the progressive profit-lock trail above tightens the SL and price
// then pulls back onto it, the broker closes the position via that SL -
// asynchronously, outside this EA's direct control (unlike QuickStop or
// CheckProfitTarget, which call trade.PositionClose() themselves and can
// react immediately). Previously this meant the EA just sat out the rest
// of the candle even if the underlying trend was still fully intact after
// the pullback. When UseContinuationReentry is on, OnTick() detects this
// specific case (a position that was open on the previous tick is gone on
// this tick, AND the deal that closed it made money) and, ONLY then,
// re-evaluates DecideDirection() and resets the M1-confirmation counters
// so the EA can immediately re-scan for a fresh entry in the SAME candle -
// deliberately different from QuickStop's "wait for next candle" design,
// since a profit-lock stop-out (unlike a loss) means the trade worked and
// the setup may still be valid, not that it failed. A losing broker-SL
// stop-out (profit <= 0) does NOT trigger this - it behaves exactly as
// before (wait for next candle), same as QuickStop already does.
input bool UseContinuationReentry = true;

//=== #4b BREAKEVEN STOP (NEW) ===
// Moves the SL to "entry + a small locked buffer" as soon as a trade has
// moved BreakEven_TriggerPoints in profit — BEFORE the ATR trail (which only
// starts at the wider Trail_StartPoints) ever gets a chance to engage.
// This closes the gap where a trade can run to a small profit, stall, and
// reverse all the way back to the original (often wide) Fixed_SL_Points
// stop without ever having its risk reduced along the way.
input bool UseBreakEven = true;
input double BreakEven_TriggerPoints = 15;  // FLOOR: minimum profit (pts) needed to arm breakeven (used as-is if UseATR_BreakEven=false)
input double BreakEven_LockPoints = 5;      // FLOOR: minimum buffer locked in beyond entry (covers spread/commission)

//=== CHANGE #1: ATR-RELATIVE BREAKEVEN (NEW, FX_M5_Scalp_v1) ===
// Scales the breakeven trigger/lock distances with live M5 ATR instead of
// staying fixed. BreakEven_TriggerPoints/BreakEven_LockPoints above are kept
// as FLOORS - the effective distance is never tighter than those values, it
// only widens when ATR justifies it. Set UseATR_BreakEven = false to fall
// back to the exact old fixed-point-only v7 behavior.
input bool   UseATR_BreakEven          = true;  // Scale breakeven trigger/lock with ATR (floors above still apply)
input double BreakEven_TriggerATR_Mult = 0.5;   // effTrigger = MAX(BreakEven_TriggerPoints, ATR_pts * this)
input double BreakEven_LockATR_Mult    = 0.15;  // effLock    = MAX(BreakEven_LockPoints,    ATR_pts * this)

//=== V4-A: QUICK-STOP LOSS CUTTING (NEW, FX_M5_Scalp_v4) ===
// Prior to v4, the only things actively monitored every tick were the WIN
// side of a trade (CheckProfitTarget/ManageTrailing tighten stops or take
// profit as a trade moves favorably) - a losing trade was left completely
// alone until it either hit the broker-side SL (Fixed_SL_Points=1503 for
// momentum, the tighter ATR-relative SL for mean-reversion) or candle-end
// close caught it (HandleCandleEndClose only force-closes trades that are
// flat-to-winning, profit >= -$1; a trade losing more than that is left
// running). This adds a second, EA-managed, tighter loss threshold checked
// every tick - NOT a hedge, NOT an averaging order, just an early exit that
// cuts a losing trade fast so the EA is flat and ready for the next clean
// signal. The broker-side SL from GetSLTP() is untouched and still exists
// as the catastrophic backstop if this check is ever disabled or somehow
// missed (e.g. a fast gap).
input bool   UseQuickStop          = true;  // Master switch for the quick-stop loss-cutting check
input double QuickStop_ATR_Mult    = 0.5;   // Quick-stop distance = ATR_pts * this (floor below still applies)
input double QuickStop_Min_Points  = 40;    // Safety floor - quick-stop distance is never tighter than this (protects against near-zero ATR)
input int    QuickStop_GraceM1Bars = 2;     // Grace period (in ~M1-bar-equivalent minutes) after entry before the quick-stop starts being evaluated, so normal entry noise/spread doesn't trigger an instant close

//=== #5 MTF SCORING ===
input bool UseMTF_Scoring = true;
input int MTF_MinScore = 2;

//=== #6 DAILY LIMITS + RISK SIZING ===
// ZX_PP_M5_v1: UseRiskSizing/RiskPercent are DEAD CODE again in this
// version - CalcLot() now always returns Fixed_Entry_Lot (0.27) regardless
// of what these are set to. Left here unused only so restoring risk-based
// sizing later is a one-function change. See the note above CalcLot() for
// the full rationale and the tradeoff this reintroduces. MinLot/MaxLot are
// still used as safety bounds on the fixed lot.
input bool UseRiskSizing = false;         // Unused by CalcLot() in this version - see note above CalcLot()
input double RiskPercent = 0.5;           // Unused by CalcLot() in this version - see note above CalcLot()
input double MaxLot = 1.0;
input double MinLot = 0.01;

//=== V2-B: LEGACY SECONDARY TP GATING (NEW, FX_M5_Scalp_v2) ===
// CheckProfitTarget() historically ran TWO extra exits unconditionally on
// every trade, on top of whatever TP GetSLTP() actually set on the order:
// a hardcoded $12.03 fixed-dollar close, and an ATR*2.0 points-based close.
// Since FX_M5_Scalp_v1 gave mean-reversion trades their own deliberately
// small ATR-relative TP (as low as the 20pt floor), these legacy checks can
// fire before - or instead of - the intended TP, silently overriding it.
// UseLegacySecondaryTP defaults to false here, so GetSLTP()'s price-level TP
// (set directly on the order via trade.Buy()/trade.Sell()) is the sole
// active target for every trade. Set this to true to restore the exact old
// always-on v7/v1 behavior for side-by-side comparison. Nothing else in
// CheckProfitTarget() changed.
input bool UseLegacySecondaryTP = false;

//=== DAILY LIMITS (for safety) ===
input bool UseDailyLimits = false;        // Disabled - trades continue all day
input double DailyProfitTarget = 100.0;
input double DailyLossLimit = 50.0;

//=== CONFIRMATION ENTRY SETTINGS ===
input int ConfirmWaitBars = 1;
input double MinM1ConfirmBody = 8.0;      // Reduced to catch more confirmations
input bool RequireM1BreakHigh = true;
input bool RequireM1BreakLow = true;

//=== M1 RSI FILTER ===
input bool UseM1_RSI_Filter = true;
input double M1_RSI_Overbought = 70.0;
input double M1_RSI_Oversold = 30.0;

//=== MEAN REVERSION SETTINGS ===
input bool UseMeanReversion = true;
input double MeanRev_RSI_Overbought = 75.0;
input double MeanRev_RSI_Oversold = 25.0;
input double MeanRev_MinM1Body = 4.0; // Minimum reversal candle body in points
input bool MeanRev_UseClosedM5RSI = false; // false=current M5 RSI, true=closed M5 RSI

//=== CHANGE #2: MEAN-REVERSION DIRECTION FIX (NEW, FX_M5_Scalp_v1) ===
enum ENUM_MEANREV_MODE
{
   MEANREV_SKIP_ONLY,        // (default) Only fire when DecideDirection() found no trend (CandleDirection==SKIP) - a genuine contrarian regime, no longer fights the trend engine
   MEANREV_AGREE_WITH_TREND, // Only fire when the reversion signal direction matches CandleDirection (reinforces the trend call)
   MEANREV_INDEPENDENT       // Old v7 behavior - fires regardless of CandleDirection, including directly opposite it
};
input ENUM_MEANREV_MODE MeanRev_Mode = MEANREV_SKIP_ONLY; // How mean-reversion direction relates to the trend bias

//=== CHANGE #4: DEDICATED MEAN-REVERSION SL/TP (NEW, FX_M5_Scalp_v1) ===
// v7 routed mean-reversion trades through the same GetSLTP() as momentum
// trades (wide Fixed_SL_Points backstop + ATR*3 TP built for trend
// continuation). A reversion trade is a different bet - a fast snap back
// toward the mean, quick invalidation if wrong - so it gets its own
// ATR-relative SL/TP here. Set UseMeanRev_DedicatedExits=false to fall back
// to sharing GetSLTP() with momentum trades exactly like v7 did.
input bool   UseMeanRev_DedicatedExits = true;  // Give mean-reversion trades their own ATR-relative SL/TP instead of sharing the trend engine's
input double MeanRev_TP_ATR_Mult       = 1.2;   // Mean-reversion TP = ATR_pts * this (clamped by the two lines below)
input double MeanRev_Min_TP_Points     = 20;    // Safety floor for mean-reversion TP
input double MeanRev_Max_TP_Points     = 120;   // Safety ceiling for mean-reversion TP
input double MeanRev_SL_ATR_Mult       = 0.7;   // Mean-reversion SL = ATR_pts * this (clamped by the two lines below) - fast invalidation if the reversion thesis is wrong
input double MeanRev_Min_SL_Points     = 15;    // Safety floor for mean-reversion SL
input double MeanRev_Max_SL_Points     = 100;   // Safety ceiling for mean-reversion SL

//=== MULTI-TIMEFRAME FILTER ===
input bool UseMTF_Filter = true;
input int EMA_Fast_Period = 9;
input int EMA_Slow_Period = 21;

//=== MOMENTUM & FILTERS ===
input int MomentumCandles = 3;
input double MinAvgBody_Points = 10.0;    // REDUCED from 15.0 - catch more setups
input double MinATR_Points = 15.0;        // REDUCED from 25.0 - more entry opportunities
input double RSI_BuyAbove = 51.0;         // REDUCED from 52.0 - more BUY opportunities
input double RSI_SellBelow = 47.0;        // REDUCED from 48.0 - more SELL opportunities

//=== GLOBAL STATE ===
datetime LastM5CandleTime = 0;
bool TradeOpenThisCandle = false;
bool DirectionDecided = false;
string CandleDirection = "NONE";
int M1BarsElapsed = 0;
datetime LastM1Time = 0;
int TodayTrades = 0;
int TodayWins = 0;
int TodayLosses = 0;
int LastTradeDay = -1;
double DailyStartBalance = 0;
bool DailyLimitHit = false;

// PP-B: tracks whether a position was open on the PREVIOUS tick, so OnTick()
// can detect the specific case of a position disappearing BETWEEN ticks
// (i.e. closed by the broker via SL/TP, not by one of this EA's own
// trade.PositionClose() calls, which already handle their own state directly).
bool PrevHadPosition = false;

// Hardcoded profit target
double TakeProfit_Dollars = 12.03;

//=== INDICATOR HANDLES ===
int hEMA_Fast_M5, hEMA_Slow_M5;
int hEMA_Fast_M15, hEMA_Slow_M15;
int hRSI_M5;
int hATR_M5;
int hMA20_H1, hMA50_H1, hRSI_H1;
int hRSI_M1;
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   
   hEMA_Fast_M5 = iMA(_Symbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5 = iMA(_Symbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   hATR_M5 = iATR(_Symbol, PERIOD_M5, 14);
   
   hEMA_Fast_M15 = iMA(_Symbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15 = iMA(_Symbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   hMA20_H1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   
   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE)
      return(INIT_FAILED);
   
   Print("[INIT] ZX PP M5 v2 - ATR-relative momentum SL edition (fixed 0.27 lot)");
   Print("[INIT] Lot sizing: ALWAYS Fixed_Entry_Lot=" + DoubleToString(Fixed_Entry_Lot,2) + " lots (risk-based sizing disabled in this version)" +
         " | bounds=[" + DoubleToString(MinLot,2) + "," + DoubleToString(MaxLot,2) + "]");
   Print("[INIT] Momentum SL: UseATR_RelativeSL=" + (UseATR_RelativeSL ? "true" : "false") +
         (UseATR_RelativeSL ?
            (" | SL=" + DoubleToString(Momentum_SL_ATR_Mult,2) + "xATR (clamp " + DoubleToString(Momentum_Min_SL_Points,0) + "-" + DoubleToString(Momentum_Max_SL_Points,0) + "pts)")
            : (" | Fixed SL=" + DoubleToString(Fixed_SL_Points, 0) + "pts")));
   Print("[INIT] TP_Mode=" + EnumToString(TP_Mode) +
         (TP_Mode == TP_MODE_RR ?
            (" | TP=SL*" + DoubleToString(TP_RiskReward_Ratio,2) + " (clamp " + DoubleToString(RR_Min_TP_Points,0) + "-" + DoubleToString(RR_Max_TP_Points,0) + "pts)")
            : (" | TP=" + DoubleToString(ATR_TP_Mult, 2) + "xATR (clamp " + DoubleToString(Min_TP_Points,0) + "-" + DoubleToString(Max_TP_Points,0) + "pts)")));
   Print("[INIT] Breakeven: trigger floor=" + DoubleToString(BreakEven_TriggerPoints,0) + "pts | lock floor=" + DoubleToString(BreakEven_LockPoints,0) + "pts | enabled=" + (UseBreakEven ? "true" : "false"));
   Print("[INIT] ATR-relative Breakeven: enabled=" + (UseATR_BreakEven ? "true" : "false") +
         " | triggerMult=" + DoubleToString(BreakEven_TriggerATR_Mult,2) + "xATR" +
         " | lockMult=" + DoubleToString(BreakEven_LockATR_Mult,2) + "xATR");
   Print("[INIT] Trail start=" + IntegerToString(Trail_StartPoints) + "pts | Step=" + IntegerToString(Trail_StepPoints) + "pts");
   Print("[INIT] Progressive Profit-Lock: enabled=" + (UseProgressiveProfitLock ? "true" : "false") +
         (UseProgressiveProfitLock ?
            (" | Tier1>=" + DoubleToString(ProfitLock_Tier1_ATR_Trigger,2) + "xATR->mult=" + DoubleToString(ProfitLock_Tier1_Mult,2) +
             " | Tier2>=" + DoubleToString(ProfitLock_Tier2_ATR_Trigger,2) + "xATR->mult=" + DoubleToString(ProfitLock_Tier2_Mult,2) +
             " | Tier3>=" + DoubleToString(ProfitLock_Tier3_ATR_Trigger,2) + "xATR->mult=" + DoubleToString(ProfitLock_Tier3_Mult,2))
            : ""));
   Print("[INIT] Giveback Guard: enabled=" + (UseGivebackGuard ? "true" : "false") +
         (UseGivebackGuard ? (" | max giveback=" + DoubleToString(Giveback_Max_Pct,0) + "% of peak favorable profit (active once past Trail_StartPoints)") : ""));
   Print("[INIT] Continuation Re-entry: enabled=" + (UseContinuationReentry ? "true" : "false") +
         (UseContinuationReentry ? " (profitable broker-side closes re-scan same candle)" : " (always waits for next M5 candle)"));
   Print("[INIT] Quick-Stop: enabled=" + (UseQuickStop ? "true" : "false") +
         " | dist=" + DoubleToString(QuickStop_ATR_Mult,2) + "xATR (floor " + DoubleToString(QuickStop_Min_Points,0) + "pts)" +
         " | grace=" + IntegerToString(QuickStop_GraceM1Bars) + " M1 bar(s)");
   Print("[INIT] Mean Reversion: enabled=" + (UseMeanReversion ? "true" : "false") + " | mode=" + EnumToString(MeanRev_Mode));
   Print("[INIT] Mean Reversion dedicated exits: enabled=" + (UseMeanRev_DedicatedExits ? "true" : "false") +
         (UseMeanRev_DedicatedExits ?
            (" | TP=" + DoubleToString(MeanRev_TP_ATR_Mult,2) + "xATR (clamp " + DoubleToString(MeanRev_Min_TP_Points,0) + "-" + DoubleToString(MeanRev_Max_TP_Points,0) + "pts)" +
             " | SL=" + DoubleToString(MeanRev_SL_ATR_Mult,2) + "xATR (clamp " + DoubleToString(MeanRev_Min_SL_Points,0) + "-" + DoubleToString(MeanRev_Max_SL_Points,0) + "pts)")
            : " | mean-rev trades share the trend engine's SL/TP (same as v7)"));
   
   Print("[INIT] Legacy secondary TP (fixed $ + ATRx2): enabled=" + (UseLegacySecondaryTP ? "true" : "false") +
         (UseLegacySecondaryTP ? "" : " (GetSLTP()'s price-level TP is the sole active target)"));
   
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA_Fast_M5 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M5);
   if(hEMA_Slow_M5 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M5);
   if(hEMA_Fast_M15 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M15);
   if(hEMA_Slow_M15 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M15);
   if(hRSI_M5 != INVALID_HANDLE) IndicatorRelease(hRSI_M5);
   if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1 != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
if(hRSI_M1 != INVALID_HANDLE) IndicatorRelease(hRSI_M1);
   Print("[STATS] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // PP-B: continuation re-entry detection. Runs FIRST, before this tick's
   // own position-management calls (CheckProfitTarget/ManageTrailing/
   // ManageQuickStop), so it only ever catches a position that was ALREADY
   // closed by the broker (via the progressive-trail-tightened SL, or the
   // ordinary broker-side TP) sometime between the previous tick and this
   // one - not a position this tick's own code is about to close itself.
   // Explicit closes made by this EA's own code (QuickStop, CheckProfitTarget,
   // HandleCandleEndClose) already manage their own state directly and are
   // excluded here since HasPosition() is still true at this point in the
   // tick when those are about to run.
   bool hasPositionNow = HasPosition();
   if(UseContinuationReentry && PrevHadPosition && !hasPositionNow)
   {
      double lastDealProfit = GetLastDealProfit();
      if(lastDealProfit > 0)
      {
         CandleDirection = DecideDirection();
         DirectionDecided = true;
         TradeOpenThisCandle = false;
         M1BarsElapsed = 0;
         LastM1Time = 0;
         Print("[CONTINUATION] Broker-side profit close detected (+$", DoubleToString(lastDealProfit,2),
               "). Re-evaluating trend for same-candle re-entry: ", CandleDirection);
      }
   }

   MqlDateTime dt;
   TimeLocal(dt);
   if(dt.day != LastTradeDay)
   {
      Print("[DAILY] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses,
            " WR=", (TodayTrades>0 ? DoubleToString((double)TodayWins/TodayTrades*100,1) : "0"), "%");
      TodayTrades = 0; TodayWins = 0; TodayLosses = 0;
      LastTradeDay = dt.day;
      DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      DailyLimitHit = false;
   }
   
   // Daily limits disabled - trades continue all day
   // if(UseDailyLimits && CheckDailyLimits()) return;
   
   if(HasPosition())
   {
      CheckProfitTarget();
      if(UseTrailingStop) ManageTrailing();
      if(UseQuickStop) ManageQuickStop();
   }
   
   datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5 != LastM5CandleTime)
   {
      if(HasPosition()) HandleCandleEndClose();
      
      LastM5CandleTime = currentM5;
      TradeOpenThisCandle = HasPosition();
      DirectionDecided = false;
      CandleDirection = "NONE";
      M1BarsElapsed = 0;
      LastM1Time = 0;
      
      if(!HasPosition())
      {
         CandleDirection = DecideDirection();
         DirectionDecided = true;
         if(CandleDirection != "SKIP")
            Print("[DIRECTION] ", CandleDirection, " decided. Waiting for M1 confirmation...");
         else if(UseMeanReversion && MeanRev_Mode == MEANREV_SKIP_ONLY)
            Print("[DIRECTION] SKIP (no trend) - scanning for mean-reversion setups instead.");
      }
   }
   
   // CHANGE #2: previously this gate excluded CheckM1Confirmation() entirely
   // on SKIP candles, which meant the mean-reversion branch inside it could
   // only ever be evaluated on candles where a trend bias already existed -
   // the opposite of where a contrarian/range setup naturally belongs. When
   // MeanRev_Mode == MEANREV_SKIP_ONLY we now still call CheckM1Confirmation()
   // on SKIP candles purely so mean reversion gets a chance to fire; the
   // momentum-confirmation branch further down is unaffected since it
   // explicitly requires CandleDirection=="BUY"/"SELL" and simply does
   // nothing when CandleDirection=="SKIP".
   bool allowMeanRevOnSkip = (UseMeanReversion && MeanRev_Mode == MEANREV_SKIP_ONLY && CandleDirection == "SKIP");

   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition()
      && (CandleDirection != "SKIP" || allowMeanRevOnSkip))
   {
      CheckM1Confirmation();
   }

   // PP-B: capture final position state for next tick's continuation-reentry
   // comparison, AFTER every close/open action this tick could have taken
   // (candle-end close, CheckM1Confirmation entries, etc.) has already run.
   PrevHadPosition = HasPosition();
}

//+------------------------------------------------------------------+
string DecideDirection()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   CopyBuffer(hATR_M5, 0, 0, 1, atr);
   if(atr[0] / _Point < MinATR_Points)
      return "SKIP";
   
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   CopyRates(_Symbol, PERIOD_M5, 1, MomentumCandles, m5);
   
   int bullish = 0, bearish = 0;
   double totalBody = 0;
   for(int i = 0; i < MomentumCandles; i++)
   {
      double body = (m5[i].close - m5[i].open) / _Point;
      totalBody += MathAbs(body);
      if(m5[i].close > m5[i].open) bullish++;
      else if(m5[i].close < m5[i].open) bearish++;
   }
   
   if(totalBody / MomentumCandles < MinAvgBody_Points)
      return "SKIP";
   
   double emaF5[], emaS5[];
   ArraySetAsSeries(emaF5, true);
   ArraySetAsSeries(emaS5, true);
   CopyBuffer(hEMA_Fast_M5, 0, 0, 2, emaF5);
   CopyBuffer(hEMA_Slow_M5, 0, 0, 2, emaS5);
   
   bool m5_bullish = (emaF5[0] > emaS5[0]);
   bool m5_bearish = (emaF5[0] < emaS5[0]);
   
   double rsi5[];
   ArraySetAsSeries(rsi5, true);
   CopyBuffer(hRSI_M5, 0, 0, 2, rsi5);
   
   bool m15_bullish = true, m15_bearish = true;
   bool h1_bullish = true, h1_bearish = true;
   
   if(UseMTF_Filter)
   {
      double emaF15[], emaS15[];
      ArraySetAsSeries(emaF15, true);
      ArraySetAsSeries(emaS15, true);
      CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15);
      CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15);
      m15_bullish = (emaF15[0] > emaS15[0]);
      m15_bearish = (emaF15[0] < emaS15[0]);
      
      double ma20[], ma50[];
      ArraySetAsSeries(ma20, true);
      ArraySetAsSeries(ma50, true);
      CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
      CopyBuffer(hMA50_H1, 0, 0, 1, ma50);
      h1_bullish = (ma20[0] > ma50[0]);
      h1_bearish = (ma20[0] < ma50[0]);
   }
   
   string direction = "SKIP";
   
   if(UseMTF_Scoring)
   {
      int buyScore = 0, sellScore = 0;
      if(m5_bullish) buyScore++;   else if(m5_bearish) sellScore++;
      if(m15_bullish) buyScore++;  else if(m15_bearish) sellScore++;
      if(h1_bullish) buyScore++;   else if(h1_bearish) sellScore++;
      
      if(bullish >= 2 && rsi5[0] > RSI_BuyAbove && buyScore >= MTF_MinScore)
         direction = "BUY";
      else if(bearish >= 2 && rsi5[0] < RSI_SellBelow && sellScore >= MTF_MinScore)
         direction = "SELL";
   }
   else
   {
      if(bullish >= 2 && m5_bullish && rsi5[0] > RSI_BuyAbove && m15_bullish && h1_bullish)
         direction = "BUY";
      else if(bearish >= 2 && m5_bearish && rsi5[0] < RSI_SellBelow && m15_bearish && h1_bearish)
         direction = "SELL";
   }
   
   {
   }
   
   return direction;
}

//+------------------------------------------------------------------+
// CHANGE #2 helper: does a mean-reversion signal in direction "signalDir"
// ("BUY" or "SELL") satisfy the configured MeanRev_Mode relative to
// CandleDirection (the trend bias DecideDirection() already picked this
// candle)?
//+------------------------------------------------------------------+
bool MeanRevDirectionAllowed(string signalDir)
{
   switch(MeanRev_Mode)
   {
      case MEANREV_SKIP_ONLY:
         return (CandleDirection == "SKIP");
      case MEANREV_AGREE_WITH_TREND:
         return (CandleDirection == signalDir);
      case MEANREV_INDEPENDENT:
      default:
         return true;
   }
}

//+------------------------------------------------------------------+
void CheckM1Confirmation()
{
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 != LastM1Time)
   {
      LastM1Time = currentM1;
      M1BarsElapsed++;
   }

   if(M1BarsElapsed < ConfirmWaitBars)
      return;

   if(M1BarsElapsed > 3)
   {
      CandleDirection = "SKIP";
      Print("[SKIP] Too late in candle. M1 bars: ", M1BarsElapsed);
      return;
   }

   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, m1) <= 0)
      return;

   double m1Body = (m1[0].close - m1[0].open) / _Point;
   double m1AbsBody = MathAbs(m1Body);
   bool m1Bullish = (m1[0].close > m1[0].open);
   bool m1Bearish = (m1[0].close < m1[0].open);

   // -----------------------------------------------------------------
   // Mean-reversion branch
   // -----------------------------------------------------------------
   // This branch is evaluated before the standard momentum confirmation.
   // The idea is to detect short-term exhaustion and allow a reversal entry
   // only when BOTH timeframes are stretched in the same direction:
   // 1) closed M1 RSI is overbought/oversold
   // 2) M5 RSI is also overbought/oversold
   // 3) the latest CLOSED M1 candle shows a small reversal clue:
   //    - bearish candle for overbought SELL mean reversion
   //    - bullish candle for oversold BUY mean reversion
   // 4) the reversal candle body must still have a minimum size so that a
   //    tiny indecision candle does not trigger a reversal trade.
   //
   // This branch is separated from the existing momentum logic on purpose.
   // If mean reversion fires, the trade is executed immediately and the
   // function returns, so the normal momentum confirmation does not run.
   if(UseMeanReversion)
   {
      double rsiM1[];
      double rsiM5[];
      ArraySetAsSeries(rsiM1, true);
      ArraySetAsSeries(rsiM5, true);

      int m5Shift = (MeanRev_UseClosedM5RSI ? 1 : 0);

      // closed M1 RSI is always read with shift=1 because the user asked for
      // the closed-candle variant. M5 RSI can be taken from current candle
      // or closed candle depending on MeanRev_UseClosedM5RSI.
      if(CopyBuffer(hRSI_M1, 0, 1, 1, rsiM1) > 0 && CopyBuffer(hRSI_M5, 0, m5Shift, 1, rsiM5) > 0)
      {
         double m1RsiVal = rsiM1[0];
         double m5RsiVal = rsiM5[0];

         // SELL mean reversion:
         // If both M1 and M5 RSI are above the overbought threshold and the
         // latest closed M1 candle is bearish, treat it as an exhaustion clue
         // and allow a SELL reversal entry.
         if(m1RsiVal >= MeanRev_RSI_Overbought &&
            m5RsiVal >= MeanRev_RSI_Overbought &&
            m1Bearish &&
            m1AbsBody >= MeanRev_MinM1Body)
         {
            if(!MeanRevDirectionAllowed("SELL"))
            {
               Print("[MEAN REVERSAL] SELL signal blocked by MeanRev_Mode=", EnumToString(MeanRev_Mode),
                     " (CandleDirection=", CandleDirection, ")");
            }
            else
            {
               Print("[MEAN REVERSAL] SELL | M1 RSI=", DoubleToString(m1RsiVal, 1),
                     " | M5 RSI=", DoubleToString(m5RsiVal, 1),
                     " | M1 body=", DoubleToString(m1AbsBody, 1), "pts");
               ExecuteSell(true);  // CHANGE #4: isMeanRev=true -> dedicated ATR-relative SL/TP
               return;
            }
         }

         // BUY mean reversion:
         // If both M1 and M5 RSI are below the oversold threshold and the
         // latest closed M1 candle is bullish, treat it as a bounce clue
         // and allow a BUY reversal entry.
         if(m1RsiVal <= MeanRev_RSI_Oversold &&
            m5RsiVal <= MeanRev_RSI_Oversold &&
            m1Bullish &&
            m1AbsBody >= MeanRev_MinM1Body)
         {
            if(!MeanRevDirectionAllowed("BUY"))
            {
               Print("[MEAN REVERSAL] BUY signal blocked by MeanRev_Mode=", EnumToString(MeanRev_Mode),
                     " (CandleDirection=", CandleDirection, ")");
            }
            else
            {
               Print("[MEAN REVERSAL] BUY | M1 RSI=", DoubleToString(m1RsiVal, 1),
                     " | M5 RSI=", DoubleToString(m5RsiVal, 1),
                     " | M1 body=", DoubleToString(m1AbsBody, 1), "pts");
               ExecuteBuy(true);  // CHANGE #4: isMeanRev=true -> dedicated ATR-relative SL/TP
               return;
            }
         }
      }
   }

   // -----------------------------------------------------------------
   // Standard momentum confirmation branch
   // -----------------------------------------------------------------
   // If mean reversion did not trigger, continue with the original logic:
   // 1) use M1 RSI as a safety filter to avoid buying when M1 is too hot
   //    or selling when M1 is too stretched to the downside
   // 2) require the latest closed M1 candle to have enough body size
   // 3) require candle direction alignment with CandleDirection
   // 4) require price to be on the correct side of the current M5 open
   if(UseM1_RSI_Filter)
   {
      double rsi1[];
      ArraySetAsSeries(rsi1, true);
      if(CopyBuffer(hRSI_M1, 0, 1, 1, rsi1) > 0)
      {
         double rsiVal = rsi1[0];

         if(CandleDirection == "BUY" && rsiVal >= M1_RSI_Overbought)
         {
            Print("[FILTER] M1 RSI overbought (", DoubleToString(rsiVal, 1), "). Skipping BUY confirmation.");
            return;
         }
         if(CandleDirection == "SELL" && rsiVal <= M1_RSI_Oversold)
         {
            Print("[FILTER] M1 RSI oversold (", DoubleToString(rsiVal, 1), "). Skipping SELL confirmation.");
            return;
         }
      }
   }

   if(m1AbsBody < MinM1ConfirmBody)
      return;

   double m5Open = iOpen(_Symbol, PERIOD_M5, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(CandleDirection == "BUY")
   {
      if(!m1Bullish) return;
      if(RequireM1BreakHigh && currentBid <= m5Open) return;

      Print("[CONFIRMED] BUY after ", M1BarsElapsed, " M1 bars");
      ExecuteBuy();
   }

   if(CandleDirection == "SELL")
   {
      if(!m1Bearish) return;
      if(RequireM1BreakLow && currentAsk >= m5Open) return;

      Print("[CONFIRMED] SELL after ", M1BarsElapsed, " M1 bars");
      ExecuteSell();
   }
}

//+------------------------------------------------------------------+
// CHANGE #4: isMeanRev (default false) lets a mean-reversion entry request
// its own ATR-relative SL/TP instead of the trend engine's SL/TP_Mode-based
// TP. Momentum trades (isMeanRev=false, the default) use the V2-A
// ATR-relative SL (UseATR_RelativeSL, default true - falls back to the old
// static Fixed_SL_Points when false) and TP_Mode (V3-A, see input block) for
// TP - nothing about the mean-reversion branch above changed.
void GetSLTP(double &sl_dist, double &tp_dist, bool isMeanRev = false)
{
   if(isMeanRev && UseMeanRev_DedicatedExits)
   {
      double atrPts = GetATR() / _Point;

      double mrSlPts = atrPts * MeanRev_SL_ATR_Mult;
      if(mrSlPts < MeanRev_Min_SL_Points) mrSlPts = MeanRev_Min_SL_Points;
      if(mrSlPts > MeanRev_Max_SL_Points) mrSlPts = MeanRev_Max_SL_Points;

      double mrTpPts = atrPts * MeanRev_TP_ATR_Mult;
      if(mrTpPts < MeanRev_Min_TP_Points) mrTpPts = MeanRev_Min_TP_Points;
      if(mrTpPts > MeanRev_Max_TP_Points) mrTpPts = MeanRev_Max_TP_Points;

      sl_dist = mrSlPts * _Point;
      tp_dist = mrTpPts * _Point;

      Print("[SLTP] Mode=MEANREV | SL=", DoubleToString(mrSlPts,0),
            "pts | TP=", DoubleToString(mrTpPts,0),
            "pts | ATR=", DoubleToString(atrPts,1), "pts");
      return;
   }

   // V2-A: momentum SL is now ATR-relative by default (UseATR_RelativeSL=true),
   // consistent with mean-reversion SL, breakeven, the trail, and QuickStop -
   // all of which already scale with live ATR. Set UseATR_RelativeSL=false to
   // fall back to the exact old static Fixed_SL_Points behavior.
   double slPts;
   if(UseATR_RelativeSL)
   {
      double slAtrPts = GetATR() / _Point;
      slPts = slAtrPts * Momentum_SL_ATR_Mult;
      if(slPts < Momentum_Min_SL_Points) slPts = Momentum_Min_SL_Points;
      if(slPts > Momentum_Max_SL_Points) slPts = Momentum_Max_SL_Points;
   }
   else
   {
      slPts = Fixed_SL_Points;
   }
   sl_dist = slPts * _Point;

   // V3-A: TP now depends on TP_Mode. TP_MODE_RR (default) ties TP directly
   // to the SL distance; TP_MODE_ATR preserves the exact old ATR-based
   // calculation below with zero behavior change.
   // V2-A NOTE: TP_MODE_RR now bases tp_points on slPts (the SL distance
   // actually in effect this trade - static or ATR-relative) rather than
   // always on the static Fixed_SL_Points value, so the RR ratio stays
   // honest to the real risk being taken even when UseATR_RelativeSL=true.
   double tp_pts;

   if(TP_Mode == TP_MODE_RR)
   {
      tp_pts = slPts * TP_RiskReward_Ratio;

      if(tp_pts < RR_Min_TP_Points) tp_pts = RR_Min_TP_Points;
      if(RR_Max_TP_Points > 0 && tp_pts > RR_Max_TP_Points) tp_pts = RR_Max_TP_Points;

      tp_dist = tp_pts * _Point;

      Print("[SLTP] Mode=RR | SL=", DoubleToString(slPts,0),
            (UseATR_RelativeSL ? " (ATR-relative)" : " (fixed)"),
            "pts | TP=", DoubleToString(tp_pts,0),
            "pts | ratio=", DoubleToString(TP_RiskReward_Ratio,2));
      return;
   }

   // TP_MODE_ATR: unchanged old behavior.
   double atr = GetATR();
   double atrPoints = atr / _Point;
   tp_pts = atrPoints * ATR_TP_Mult;
   
   if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
   if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;
   
   tp_dist = tp_pts * _Point;
   
   Print("[SLTP] Mode=ATR | SL=", DoubleToString(slPts,0),
         (UseATR_RelativeSL ? " (ATR-relative)" : " (fixed)"),
         "pts | TP=", DoubleToString(tp_pts,0), "pts");
}

//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 30 * _Point;
   return atr[0];
}

//+------------------------------------------------------------------+
// *** ZX_PP_M5_v1: LOT SIZE LOCKED TO Fixed_Entry_Lot (ALWAYS 0.27) ***
// v2 (FX_M5_Scalp_v2) introduced risk-based sizing here (see the old V2-A
// note this replaces): CalcLot() used to size each trade off its own
// sl_dist and RiskPercent, controllable via the UseRiskSizing toggle, so
// mean-reversion and momentum trades (which can have very different SL
// distances) would risk a comparable dollar amount instead of a comparable
// lot size.
//
// For ZX_PP_M5_v1, per explicit request, that toggle is bypassed entirely:
// CalcLot() now ALWAYS returns Fixed_Entry_Lot (0.27) for every entry -
// momentum or mean-reversion, BUY or SELL - regardless of UseRiskSizing's
// value or sl_dist. The risk-based sizing code and the UseRiskSizing/
// RiskPercent inputs are left in place (unused) only so the rest of the
// file - and MinLot/MaxLot, which still bound the fixed lot for broker
// safety - doesn't need to change elsewhere.
//
// WORTH KNOWING: this reintroduces the exact inconsistency v2's risk-based
// sizing was built to fix - a mean-reversion trade (tight ATR-relative SL,
// e.g. ~20-100pts) and a momentum trade (wide 1503pt Fixed_SL_Points SL)
// now once again risk very different dollar amounts at the same 0.27 lots,
// since dollar risk = lot size x SL distance x point value, and only lot
// size is now held constant. If you want risk-based sizing back later,
// nothing needs to change here except restoring the branch below - the
// UseRiskSizing/RiskPercent inputs are already there and untouched.
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
   double lot = Fixed_Entry_Lot;   // always 0.27 - sl_dist and UseRiskSizing intentionally ignored

   // Still respect the broker's minimum/maximum volume bounds so the
   // fixed lot never gets rejected by the trade server.
   if(lot < MinLot) lot = MinLot;
   if(lot > MaxLot) lot = MaxLot;

   return lot;
}

//+------------------------------------------------------------------+
// CHANGE #4: isMeanRev (default false) means "use GetSLTP()'s normal
// trend-engine SL/TP exactly as in v7" - the momentum-confirmation branch's
// call to ExecuteBuy() is unchanged and still defaults to false. Only the
// mean-reversion branch passes true, routing GetSLTP() to the dedicated
// ATR-relative mean-reversion SL/TP instead.
void ExecuteBuy(bool isMeanRev = false)
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist, isMeanRev);
   double lot = CalcLot(sl_dist);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - sl_dist, _Digits);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);
   string comment = isMeanRev ? "M5v4 BUY MR" : "M5v4 BUY";

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, comment))
      Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] BUY ", lot, " lots | SL:", sl, " TP:", tp, isMeanRev ? " | MEAN-REV exits" : "");
   }
}

//+------------------------------------------------------------------+
// CHANGE #4: see the note above ExecuteBuy() - identical pattern.
void ExecuteSell(bool isMeanRev = false)
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist, isMeanRev);
   double lot = CalcLot(sl_dist);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + sl_dist, _Digits);
   double tp = NormalizeDouble(bid - tp_dist, _Digits);
   string comment = isMeanRev ? "M5v4 SELL MR" : "M5v4 SELL";

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, comment))
      Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] SELL ", lot, " lots | SL:", sl, " TP:", tp, isMeanRev ? " | MEAN-REV exits" : "");
   }
}

//+------------------------------------------------------------------+
// *** V2-B: LEGACY SECONDARY TP GATING ***
// See the V2-B note above the UseLegacySecondaryTP input for the full
// rationale. Both checks below are now gated behind that flag (default
// false); when off, GetSLTP()'s price-level TP - set directly on the order
// in ExecuteBuy()/ExecuteSell() - is this EA's sole active profit target.
//+------------------------------------------------------------------+
void CheckProfitTarget()
{
   if(!UseLegacySecondaryTP) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double priceCurrent = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (priceCurrent - priceOpen) / _Point;
      
      if(profit >= TakeProfit_Dollars)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[TP HIT] +$", DoubleToString(profit, 2), " | Points: ", IntegerToString((int)profitPoints));
         continue;
      }
      
      double atr = GetATR() / _Point;
      double dynamicTP = atr * 2.0;
      
      if(profitPoints >= dynamicTP)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[DYNAMIC TP] Profit: ", IntegerToString((int)profitPoints), "pts | Closed at optimal level");
      }
   }
}

//+------------------------------------------------------------------+
void HandleCandleEndClose()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (type == POSITION_TYPE_BUY) ? (bid - openPrice)/_Point : (openPrice - ask)/_Point;
      
      if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints)
      {
         Print("[HOLD] Winner running (+", IntegerToString((int)profitPts), "pts). Trail buffer: ", 
               IntegerToString((int)HoldTrailBuffer), "pts");
         continue;
      }
      
      if(profit >= -1.00)
      {
         trade.PositionClose(ticket);
         if(profit > 0) TodayWins++; else TodayLosses++;
         Print("[CANDLE END] ", (profit>0 ? "WIN +$" : "LOSS $"), DoubleToString(profit, 2));
      }
   }
}

//+------------------------------------------------------------------+
// *** BREAKEVEN + ATR TRAIL + GIVEBACK GUARD ***
// This function now protects a trade in THREE stages:
//
//  Stage 1 - BREAKEVEN (new in v1): as soon as profit reaches
//            BreakEven_TriggerPoints, the SL is moved to
//            entry price (+/- BreakEven_LockPoints) to lock in a small
//            guaranteed profit and remove the original (often wide)
//            initial SL risk. This fires EARLIER than the ATR trail
//            because BreakEven_TriggerPoints is expected to be smaller
//            than Trail_StartPoints.
//
//  Stage 2 - ATR TRAIL (progressive since PP-A): once profit reaches
//            Trail_StartPoints, the SL trails behind price at a distance
//            of ATR * (a multiplier that tightens through three profit
//            tiers - see GetProgressiveTrailMult()), tightening as the
//            trade runs further.
//
//  Stage 3 - GIVEBACK GUARD (new in v3): also once profit reaches
//            Trail_StartPoints, locks in at least (100-Giveback_Max_Pct)%
//            of the best favorable profit this trade has EVER reached,
//            independent of ATR - catches spike-then-reverse moves that
//            the (lagging, averaged) ATR trail alone might give back too
//            much of. See the V3-B header note for the full rationale.
//
// All three candidate stop levels are computed every tick, and the SL is
// only ever moved to whichever candidate is MOST PROTECTIVE (closest to
// current price in the trade's favor) and strictly better than the current
// SL - so the stop can only ratchet forward, never backward, and whichever
// stage is currently most protective naturally takes over from the others
// tick to tick.
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
// PP-A helper: returns the Stage-2 ATR trail multiplier to use for a
// position currently sitting at profitPts profit, given live atrPts. Falls
// back to the unchanged Trail_ATR_Mult when UseProgressiveProfitLock=false
// or profit hasn't reached Tier 1 yet.
//+------------------------------------------------------------------+
double GetProgressiveTrailMult(double atrPts, double profitPts)
{
   if(!UseProgressiveProfitLock) return Trail_ATR_Mult;

   if(profitPts >= atrPts * ProfitLock_Tier3_ATR_Trigger) return ProfitLock_Tier3_Mult;
   if(profitPts >= atrPts * ProfitLock_Tier2_ATR_Trigger) return ProfitLock_Tier2_Mult;
   if(profitPts >= atrPts * ProfitLock_Tier1_ATR_Trigger) return ProfitLock_Tier1_Mult;
   return Trail_ATR_Mult;
}

//+------------------------------------------------------------------+
// V3-B helper: returns the best favorable price reached since a position's
// own open time, on the current chart timeframe - i.e. the peak profit ever
// held, in points. Uses iHighest/iLowest over the position's lifetime bars
// rather than any persistent per-ticket variable, so it is exact even if the
// EA/terminal restarts mid-trade. Falls back to the current bid/ask (i.e.
// "no peak beyond right now") if the open bar can't be located, which simply
// makes the giveback guard inactive that tick rather than risk a bad value.
//+------------------------------------------------------------------+
double GetPeakProfitPts(datetime openTime, double openPrice, ENUM_POSITION_TYPE type)
{
   int openBar = iBarShift(_Symbol, PERIOD_CURRENT, openTime, false);
   if(openBar < 0)
   {
      double curPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (type == POSITION_TYPE_BUY) ? (curPrice - openPrice) / _Point : (openPrice - curPrice) / _Point;
   }

   int count = openBar + 1;   // bars 0..openBar inclusive

   if(type == POSITION_TYPE_BUY)
   {
      int hIdx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, count, 0);
      double peakPrice = (hIdx >= 0) ? iHigh(_Symbol, PERIOD_CURRENT, hIdx) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (peakPrice - openPrice) / _Point;
   }
   else
   {
      int lIdx = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, count, 0);
      double peakPrice = (lIdx >= 0) ? iLow(_Symbol, PERIOD_CURRENT, lIdx) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (openPrice - peakPrice) / _Point;
   }
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
   double atr = GetATR();
   double trailStep = Trail_StepPoints * _Point;

   // CHANGE #1: ATR-relative breakeven. BreakEven_TriggerPoints/BreakEven_LockPoints
   // remain hard FLOORS - effTriggerPts/effLockPts are never smaller than them,
   // they only grow when live ATR calls for more room. Set UseATR_BreakEven=false
   // to force the old fixed-point-only v7 behavior.
   double atrPts = atr / _Point;
   double effTriggerPts = BreakEven_TriggerPoints;
   double effLockPts    = BreakEven_LockPoints;
   if(UseATR_BreakEven)
   {
      effTriggerPts = MathMax(BreakEven_TriggerPoints, atrPts * BreakEven_TriggerATR_Mult);
      effLockPts    = MathMax(BreakEven_LockPoints,    atrPts * BreakEven_LockATR_Mult);
   }
   double beLockDist = effLockPts * _Point;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set
         double beSL = -1, trailSL = -1, guardSL = -1, peakPts = 0;

         // --- Stage 1: breakeven candidate (ATR-relative when UseATR_BreakEven) ---
         if(UseBreakEven && profitPts >= effTriggerPts)
         {
            beSL = NormalizeDouble(openPrice + beLockDist, _Digits);
            if(beSL > bestSL) bestSL = beSL;
         }

         // --- Stage 2: ATR trail candidate (PP-A: multiplier tightens progressively with profit) ---
         if(profitPts >= Trail_StartPoints)
         {
            double trailDist = atr * GetProgressiveTrailMult(atrPts, profitPts);
            trailSL = NormalizeDouble(bid - trailDist, _Digits);
            if(trailSL > bestSL) bestSL = trailSL;
         }

         // --- Stage 3 (V3-B): giveback guard - locks in at least (100-Giveback_Max_Pct)% ---
         // of the best favorable excursion this trade has ever reached, independent of ATR.
         if(UseGivebackGuard && profitPts >= Trail_StartPoints)
         {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            peakPts = GetPeakProfitPts(openTime, openPrice, type);
            double guardLockPts = peakPts * (1.0 - Giveback_Max_Pct/100.0);
            guardSL = NormalizeDouble(openPrice + guardLockPts * _Point, _Digits);
            if(guardSL > bestSL) bestSL = guardSL;
         }

         // Only modify if the best candidate is a real, meaningful improvement
         if(bestSL > curSL + trailStep)
         {
            trade.PositionModify(ticket, bestSL, curTP);
            string stage = (bestSL == guardSL) ? "GUARD" : (bestSL == beSL) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] BUY SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts")
                   : stage == "GUARD"   ? (" | peak=" + DoubleToString(peakPts,0) + "pts locking>=" + DoubleToString(100-Giveback_Max_Pct,0) + "% of peak")
                                        : (" | trailMult=" + DoubleToString(GetProgressiveTrailMult(atrPts, profitPts),2) + "xATR")));
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set
         bool haveCandidate = false;
         double beSL = -1, trailSL = -1, guardSL = -1, peakPts = 0;

         // --- Stage 1: breakeven candidate (ATR-relative when UseATR_BreakEven) ---
         if(UseBreakEven && profitPts >= effTriggerPts)
         {
            beSL = NormalizeDouble(openPrice - beLockDist, _Digits);
            if(!haveCandidate || beSL < bestSL) { bestSL = beSL; haveCandidate = true; }
         }

         // --- Stage 2: ATR trail candidate (PP-A: multiplier tightens progressively with profit) ---
         if(profitPts >= Trail_StartPoints)
         {
            double trailDist = atr * GetProgressiveTrailMult(atrPts, profitPts);
            trailSL = NormalizeDouble(ask + trailDist, _Digits);
            if(!haveCandidate || trailSL < bestSL) { bestSL = trailSL; haveCandidate = true; }
         }

         // --- Stage 3 (V3-B): giveback guard, symmetric to the BUY branch above ---
         if(UseGivebackGuard && profitPts >= Trail_StartPoints)
         {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            peakPts = GetPeakProfitPts(openTime, openPrice, type);
            double guardLockPts = peakPts * (1.0 - Giveback_Max_Pct/100.0);
            guardSL = NormalizeDouble(openPrice - guardLockPts * _Point, _Digits);
            if(!haveCandidate || guardSL < bestSL) { bestSL = guardSL; haveCandidate = true; }
         }

         // Only modify if we have a candidate and it's a real improvement
         // (tighter/closer to price than the current SL, or SL was unset)
         if(haveCandidate && (curSL == 0 || bestSL < curSL - trailStep))
         {
            trade.PositionModify(ticket, bestSL, curTP);
            string stage = (bestSL == guardSL) ? "GUARD" : (UseBreakEven && bestSL == beSL) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] SELL SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts")
                   : stage == "GUARD"   ? (" | peak=" + DoubleToString(peakPts,0) + "pts locking>=" + DoubleToString(100-Giveback_Max_Pct,0) + "% of peak")
                                        : (" | trailMult=" + DoubleToString(GetProgressiveTrailMult(atrPts, profitPts),2) + "xATR")));
         }
      }
   }
}

//+------------------------------------------------------------------+
// V4-A: QUICK-STOP LOSS CUTTING
// See the V4-A note above the UseQuickStop input for the full rationale.
// This is deliberately simple and one-directional: it only ever CLOSES a
// losing position outright - no hedge order, no averaging order, no basket
// management. It does not modify SL/TP levels (that stays ManageTrailing()'s
// job on the winning side); it just decides "has this trade lost enough,
// fast enough, that it's better to be flat than to keep holding it" and
// acts immediately if so.
//
// Grace period: uses POSITION_TIME (this specific trade's own open time,
// not the M5-candle-start M1BarsElapsed counter used during entry
// confirmation, which stops incrementing once a trade is open) so the
// grace period is always measured from when THIS trade actually opened.
// QuickStop_GraceM1Bars is treated as an approximate minute count (1 M1 bar
// ~= 60 seconds) rather than doing bar-index lookups, since a fast, simple
// wall-clock check is all a grace period needs.
//
// Deliberately does NOT reset TradeOpenThisCandle to false on close (unlike
// CheckProfitTarget()'s early-profit exit, which does reset it to allow a
// fresh same-candle attempt). This is intentional: a quick-stopped trade
// means the candle's setup didn't work, so re-entry is held until the next
// M5 candle rollover (which naturally resets TradeOpenThisCandle via
// HasPosition() in OnTick()) rather than immediately retrying the same
// candle's conditions - avoiding a chase/revenge-entry pattern.
//+------------------------------------------------------------------+
void ManageQuickStop()
{
   double atrPts = GetATR() / _Point;

   double quickStopPts = QuickStop_ATR_Mult * atrPts;
   if(quickStopPts < QuickStop_Min_Points) quickStopPts = QuickStop_Min_Points;

   double graceSeconds = QuickStop_GraceM1Bars * 60;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - openTime < graceSeconds) continue;   // still inside the grace period

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double lossPts = (type == POSITION_TYPE_BUY) ? (openPrice - bid) / _Point : (ask - openPrice) / _Point;

      if(lossPts >= quickStopPts)
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         trade.PositionClose(ticket);
         TodayLosses++;
         Print("[QUICK STOP] ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
               " closed | Loss: ", IntegerToString((int)lossPts), "pts ($", DoubleToString(profit, 2), ")",
               " | threshold=", DoubleToString(quickStopPts,0), "pts (", DoubleToString(QuickStop_ATR_Mult,2), "xATR)");
      }
   }
}

//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - DailyStartBalance;
   
   if(dailyPL >= DailyProfitTarget)
   {
      if(!DailyLimitHit)
      {
         Print("[DAILY LIMIT] Profit target reached. Stopping.");
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   if(dailyPL <= -DailyLossLimit)
   {
      if(!DailyLimitHit)
      {
         Print("[DAILY LIMIT] Loss limit reached. Stopping.");
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

//+------------------------------------------------------------------+
// PP-B helper: returns the net profit (profit + swap + commission) of the
// most recent closing deal (DEAL_ENTRY_OUT) for this symbol/magic. Used by
// the continuation re-entry check in OnTick() to tell whether a position
// that just disappeared (closed by the broker between ticks) closed in
// profit or in loss. Returns 0 if no matching closing deal is found in the
// last hour of history.
//+------------------------------------------------------------------+
double GetLastDealProfit()
{
   if(!HistorySelect(TimeCurrent() - 3600, TimeCurrent() + 60))
      return 0;

   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      return HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
           + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
           + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   }
   return 0;
}

