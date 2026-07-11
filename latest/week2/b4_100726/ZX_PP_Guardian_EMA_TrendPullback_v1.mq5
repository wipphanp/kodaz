//+------------------------------------------------------------------+
//|                          ZX_PP_Guardian_EMA_TrendPullback_v1.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "5.17"

//+------------------------------------------------------------------+
//| ZX_PP_Guardian_EMA_TrendPullback_v1 — built from                     |
//| ZX_PP_Guardian_EMA200_v1, adding ONE new, fully independent,          |
//| self-contained strategy (Option B from the design discussion).        |
//| Every existing function, input, and code path (G-1 through G-4,       |
//| the momentum/mean-reversion engine, breakeven/trail/giveback stack,    |
//| manual-trade handling) is BYTE-FOR-BYTE unchanged EXCEPT for two        |
//| one-line additions inside ManageManualTrades()/ManageManualBasket()      |
//| that were REQUIRED for correctness - see the G-5 note there for exactly   |
//| why. Nothing else was touched.                                             |
//|                                                                              |
//| G-5 - EMA TREND PULLBACK STRATEGY (NEW, INDEPENDENT):                       |
//|   A second, fully separate signal path that trades a different thesis       |
//|   than the existing scalp system: catch a fresh trend leg on a             |
//|   9/20 EMA cross, wait for a pullback into the 9/20 gap (confirmed by      |
//|   a CLOSE inside the gap, not just a wick), then enter on a continuation    |
//|   candle that closes back beyond the 9 EMA in the trend direction.         |
//|   Stop loss sits at the 50 EMA (or a 10-bar swing high/low fallback         |
//|   when the 50 EMA is too close to entry, ATR-scaled), and target is the     |
//|   200 EMA itself - a "ride it back to the 200 EMA" trade, not a fast        |
//|   scalp. Runs under its own magic number (TP_MagicNumber), its own          |
//|   toggle (UseEMA_TrendPullback), its own indicator handles, and its own     |
//|   entry/manage/exit functions - it does not replace, share state with,      |
//|   or get managed by the existing momentum/mean-reversion system's           |
//|   breakeven/ATR-trail/giveback-guard stack. That stack was tuned for the    |
//|   existing fixed-dollar-target scalp style; forcing this structurally       |
//|   different, level-based trade through it would fight the strategy's own    |
//|   logic (e.g. breakeven at +6pts would very likely stop it out on a         |
//|   normal pullback long before it ever reached the 200 EMA). Its only exits   |
//|   are the broker-side SL/TP set at entry - full stop.                        |
//|                                                                                |
//|   Open questions resolved with these defaults (all tunable via inputs):       |
//|     1) Pullback confirmation: CLOSE inside the 9/20 gap, not a wick touch -   |
//|        far less noisy on M5.                                                  |
//|     2) "50 EMA too close": ATR-scaled via TP_EMA50_TooClose_ATR_Mult          |
//|        (default 0.3) - if price sits within ATR*0.3 of the 50 EMA, the SL      |
//|        falls back to the swing high/low instead, consistent with how every    |
//|        other exit mechanism in this file already scales with live ATR.        |
//|     3) Swing high/low fallback lookback: TP_Swing_LookbackBars (default 10)   |
//|        closed bars - enough for real recent structure without reaching back   |
//|        into ancient history.                                                  |
//|     4) Trade management: this strategy's own trades get ONLY their fixed      |
//|        entry SL/TP - no breakeven, no ATR trail, no giveback guard, no        |
//|        candle-end close. This falls out automatically: every existing         |
//|        management function already filters strictly on MagicNumber, so a      |
//|        position opened under TP_MagicNumber is invisible to all of them,       |
//|        with zero changes needed to any of those functions.                     |
//|     5) "9 EMA" not "8 EMA" - TP_EMA_Fast_Period defaults to 9, per explicit    |
//|        instruction, wherever the earlier design discussion said "8 EMA".       |
//|                                                                                  |
//|   G-4 INTERACTION: this strategy's setup only makes sense when there's         |
//|   real room left to run toward the 200 EMA, so by default              |
//|   (TP_RespectEMA200ZoneFilter=true) it reuses G-4's existing                    |
//|   EMA200_ZoneBlock (read-only - G-4 itself is completely untouched) to          |
//|   pause its own state machine while price is inside/clearing that zone -         |
//|   no conflict, no rework of G-4 needed, exactly as discussed.                     |
//|                                                                                     |
//|   REQUIRED ONE-LINE FIX (the only change to pre-existing functions):              |
//|   ManageManualTrades() and ManageManualBasket() previously treated ANY            |
//|   position with magic != MagicNumber as a manual/foreign trade to be              |
//|   auto-closed at small dollar thresholds ($24/$42/$12 basket). Without a           |
//|   fix, this strategy's own TP_MagicNumber trades would have been wrongly           |
//|   caught by that logic and cut short long before reaching the 200 EMA -             |
//|   defeating the entire point of the strategy. Both functions now also              |
//|   skip posMagic == TP_MagicNumber, one added line each, nothing else in              |
//|   either function changed.                                                           |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ZX_PP_Guardian_EMA200_v1 — built from ZX_PP_Guardian_InstantBE6_v1, |
//| adding ONE new entry filter. Everything else (manual-trade G-1/G-2,  |
//| instant breakeven G-3, all existing trailing/entry/exit logic) is     |
//| BYTE-FOR-BYTE unchanged.                                               |
//|                                                                          |
//| G-4 - 200 EMA NO-TRADE ZONE (NEW):                                     |
//|   New 200-period EMA on M5 (same timeframe as entries), via              |
//|   EMA200_Period (default 200). New UseEMA200Filter (default true)        |
//|   blocks new EA entries while price is approaching/sitting near this     |
//|   EMA, where price often chops before committing - the classic false-     |
//|   signal zone right at a major moving average.                            |
//|                                                                              |
//|   Zone width is ATR-scaled, not fixed: half-width = ATR(M5,14) *            |
//|   EMA200_ZoneATR_Mult (default 0.5), so it adapts to current volatility     |
//|   rather than a hardcoded point value. Checked once per new closed M5        |
//|   bar (UpdateEMA200Filter(), called from OnTick()'s existing new-bar         |
//|   block, right before CandleDirection = DecideDirection()) against that      |
//|   bar's close vs the 200 EMA value.                                           |
//|                                                                                  |
//|   Once price's last closed bar sits outside the zone, it must hold             |
//|   outside for EMA200_ClearBars (default 3) CONSECUTIVE closed M5 bars           |
//|   before entries resume - a single bar spiking through does not                  |
//|   instantly re-arm entries, satisfying "wait for some time for the setup         |
//|   to be formed". Once cleared, the EA's EXISTING signal logic (9/21 EMA           |
//|   cross momentum, RSI, mean-reversion) decides buy/sell exactly as before          |
//|   - this filter only gates WHEN a new entry may be evaluated, never HOW.            |
//|                                                                                        |
//|   Blocks BOTH entry paths, not just one: DecideDirection() returns "SKIP"             |
//|   immediately while EMA200_ZoneBlock is set (blocking the momentum path),              |
//|   AND the MEANREV_SKIP_ONLY mean-reversion gate in OnTick() now also                    |
//|   requires !EMA200_ZoneBlock - otherwise a SKIP caused by this filter would              |
//|   have been indistinguishable from a genuine "no trend" SKIP and would have               |
//|   let mean-reversion trade right through the zone regardless.                              |
//|                                                                                                |
//|   Does not touch open trades, trailing, breakeven, manual-trade handling,                     |
//|   or the entry signal logic itself - purely an additional gate on new                          |
//|   entries. Set UseEMA200Filter=false to disable entirely and fall back to                        |
//|   exact Guardian_InstantBE6_v1 behavior.                                                            |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//|                                 ZX_PP_Guardian_InstantBE6_v1.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| ZX_PP_Guardian_InstantBE6_v1 — built from ZX_PP_Guardian_ML_SL_v2,  |
//| adding ONE new candidate stop to ManageTrailing() for the EA's OWN   |
//| trades only. Manual-trade handling (G-1/G-2) and everything else      |
//| carries over BYTE-FOR-BYTE unchanged. This only adds new, additive     |
//| code - Option B from the design discussion: a fully separate,          |
//| independent stage, not a retune of the existing breakeven inputs.       |
//|                                                                          |
//| G-3 - INSTANT BREAKEVEN @ FIXED +6 POINTS (NEW):                       |
//|   The existing breakeven stage (Stage 1) only arms once profit          |
//|   reaches effTriggerPts (15pts floor, or more if ATR-scaled) and then    |
//|   locks in effLockPts (5pts floor, or more if ATR-scaled) - so a         |
//|   trade sitting at, say, +8pts still has no protection at all if it      |
//|   reverses back through entry into a loss before reaching that           |
//|   trigger.                                                                |
//|                                                                             |
//|   New UseInstantBreakeven6 (default true) adds a Stage 0 candidate,        |
//|   evaluated BEFORE Stage 1, that arms the moment a trade turns             |
//|   positive at all (profitPts > 0) and locks in a FIXED                     |
//|   Instant_BE_LockPoints (default 6) beyond entry:                          |
//|      BUY:  candidate SL = openPrice + Instant_BE_LockPoints*_Point         |
//|      SELL: candidate SL = openPrice - Instant_BE_LockPoints*_Point         |
//|   e.g. entry 4105.03 -> candidate SL 4105.09 on a BUY. This is             |
//|   deliberately a fixed point value, NOT ATR-scaled, and completely         |
//|   separate from BreakEven_TriggerPoints/BreakEven_LockPoints/              |
//|   UseATR_BreakEven - those existing inputs are untouched and can still     |
//|   be retuned independently for other purposes. Applies to every one of     |
//|   the EA's own open trades (momentum and mean-reversion alike -            |
//|   ManageTrailing() already covers both, filtering only on MagicNumber).    |
//|                                                                             |
//|   This candidate is fed into the exact same "best of all candidates,       |
//|   ratchet-forward-only" comparison Stage 1/2/3 already use - the SL        |
//|   only ever moves to whichever candidate is MOST protective and            |
//|   strictly better than the current SL, so Stage 0 can only ever tighten    |
//|   protection earlier than Stage 1 would have, never loosen it, and it's    |
//|   automatically superseded once Stage 1/2/3 become more protective as      |
//|   the trade runs further. Runs alongside the existing breakeven stage -    |
//|   both can stay enabled at once, or either can be disabled independently.  |
//|   Set UseInstantBreakeven6=false to disable this stage entirely and        |
//|   fall back to the exact Guardian_ML_SL_v2 behavior.                       |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ZX_PP_Guardian_v1 — built from ZX_PP_ML_v1, adding two targeted    |
//| improvements to manual-trade handling. Everything about the EA's   |
//| own trading logic (entries, SL/TP, breakeven, trail, giveback      |
//| guard, QuickStop, continuation re-entry, daily limits) and the      |
//| existing per-trade manual-trade close-at-+$24 logic is BYTE-FOR-    |
//| BYTE identical to ML_v1. This only adds new, additive code.         |
//|                                                                        |
//| G-1 - MANUAL TRADE STOP LOSS (NEW):                                  |
//|   ManageManualTrades() previously only ever took profit on a manual   |
//|   trade (closing it once floating profit reached                     |
//|   ManualTrade_CloseProfitUSD) and otherwise left it completely alone  |
//|   - including while it sat in a loss. New ManualTrade_CloseLossUSD    |
//|   (default $27) adds a floor: once a manual trade's floating LOSS     |
//|   reaches this many dollars, it is closed too. This is a strict,      |
//|   symmetrical dollar-based stop loss - it does not touch the manual    |
//|   trade's own broker-side SL/TP, it just force-closes at the EA level  |
//|   once the loss threshold is hit. Still fully independent per-trade:   |
//|   each manual position is checked against both thresholds on its own   |
//|   floating profit, with no interaction between tickets.                |
//|                                                                         |
//| G-2 - MANUAL TRADE BASKET TAKE-PROFIT (NEW):                          |
//|   New UseManualBasketTP (default true) adds a SEPARATE, additional     |
//|   check: whenever ManualBasket_MinTrades (default 2) or more manual     |
//|   trades are open on this symbol at the same time, their COMBINED net  |
//|   floating profit (profit+swap+commission summed across all of them)   |
//|   is evaluated every tick. Once that combined total reaches            |
//|   ManualBasket_CloseProfitUSD (default $12), ALL of those manual        |
//|   trades are closed together, regardless of where any single one of    |
//|   them individually stands. This runs independently of, and in         |
//|   addition to, the per-trade profit/loss checks in G-1 and the         |
//|   original ML_v1 logic - whichever condition is met first on a given   |
//|   tick is what fires. With fewer than ManualBasket_MinTrades manual     |
//|   trades open, this basket check does nothing and the per-trade logic  |
//|   alone governs, exactly as before.                                    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ZX_PP_ML_v1 — built from ZX_PP_M5_v3, adding a manual-trade         |
//| detector. Nothing about the EA's own trading logic changed - every  |
//| existing function (entries, SL/TP, breakeven, trail, giveback       |
//| guard, QuickStop, continuation re-entry, daily limits) is BYTE-FOR- |
//| BYTE identical to v3. This only adds new, additive code.            |
//|                                                                        |
//| ML-1 - MANUAL TRADE DETECTION + AUTO-CLOSE AT +$24:                  |
//|   Every existing position loop in this EA (ManageTrailing,           |
//|   ManageQuickStop, HandleCandleEndClose, CloseAllPositions,          |
//|   HasPosition, GetLastDealProfit) filters strictly by                |
//|   PositionGetInteger(POSITION_MAGIC) == MagicNumber - so any         |
//|   position opened manually (or by another EA) on this chart's        |
//|   symbol was previously invisible to this code: never logged, never  |
//|   managed, never touched. New UseManualTradeDetection (default       |
//|   true) adds a SEPARATE function, ManageManualTrades(), which scans  |
//|   for the opposite - positions on this symbol whose magic number is  |
//|   NOT MagicNumber - and treats those as manual/foreign trades:       |
//|      - logs them ([MANUAL TRADE DETECTED]) so they're visible in the |
//|        Experts log, and                                              |
//|      - automatically closes one once its floating profit reaches     |
//|        ManualTrade_CloseProfitUSD (default $24).                     |
//|   This is a NEW, independent function called once per tick from      |
//|   OnTick() - it does not read from or write to any variable the      |
//|   EA's own trade-management functions use, and none of those         |
//|   functions were modified to add this. Set                           |
//|   UseManualTradeDetection=false to disable it entirely (manual       |
//|   trades are then left alone, exactly as in v3). A manual position   |
//|   below the profit threshold, or in loss, is left untouched - this   |
//|   only ever closes a manual trade that has reached the target        |
//|   profit, it never cuts a manual loss and never modifies a manual    |
//|   trade's own SL/TP.                                                 |
//+------------------------------------------------------------------+
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

//=== G-3: INSTANT BREAKEVEN @ FIXED +6 POINTS (NEW, Option B - separate/independent stage) ===
// Arms the moment a trade turns positive at all (profitPts > 0) and locks in
// a FIXED Instant_BE_LockPoints beyond entry - completely independent of
// BreakEven_TriggerPoints/BreakEven_LockPoints/UseATR_BreakEven above, which
// are untouched and remain free to be retuned separately. Fed into the same
// best-of-all-candidates, ratchet-forward-only comparison in ManageTrailing()
// as every other stage, so it can only tighten protection, never loosen it,
// and never conflicts with the ATR trail or giveback guard. Set
// UseInstantBreakeven6=false to disable this stage entirely.
input bool   UseInstantBreakeven6   = true;   // Master switch for the fixed +6pt instant breakeven stage
input double Instant_BE_LockPoints  = 6;      // Fixed points locked beyond entry the instant a trade turns positive

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

//=== ML-1: MANUAL TRADE DETECTION (NEW, ZX_PP_ML_v1) ===
// Detects any position on this symbol whose magic number is NOT MagicNumber
// - i.e. opened manually or by a different EA - and auto-closes it once its
// floating profit reaches ManualTrade_CloseProfitUSD. Fully independent of
// every other function in this file: no existing loop, variable, or check
// was touched to add this. See the ML-1 header note above for full
// rationale. Set UseManualTradeDetection=false to leave manual trades
// completely alone, exactly as in v3.
input bool   UseManualTradeDetection   = true;   // Master switch for manual/foreign trade detection + auto-close
input double ManualTrade_CloseProfitUSD = 36.0;  // Auto-close a detected manual trade once its floating profit reaches this many dollars
input double ManualTrade_CloseLossUSD   = 27.0;  // G-1: Auto-close a detected manual trade once its floating LOSS reaches this many dollars (strict per-trade stop loss)

// G-2: Manual trade BASKET take-profit. Independent of, and additional to,
// the per-trade checks above. When ManualBasket_MinTrades or more manual
// trades are open on this symbol at once, their combined net floating
// profit is watched, and ALL of them are closed together the moment that
// combined total reaches ManualBasket_CloseProfitUSD - regardless of any
// single trade's own individual profit/loss. See the G-2 header note near
// the top of the file for full rationale.
input bool   UseManualBasketTP            = true;   // Master switch for the manual-trade basket take-profit
input int    ManualBasket_MinTrades       = 2;       // Minimum number of simultaneous manual trades needed to arm the basket check ("more than 1")
input double ManualBasket_CloseProfitUSD  = 12.0;    // Close ALL manual trades once their COMBINED net profit reaches this many dollars

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

//=== G-4: 200 EMA NO-TRADE ZONE (NEW) ===
// Avoids taking new EA entries while price is approaching/sitting near the
// 200 EMA on M5 (same timeframe as entries), where price often chops before
// committing to a direction. Blocks BOTH the momentum direction check in
// DecideDirection() and the mean-reversion check in the MEANREV_SKIP_ONLY
// path - not just one of them. Does not touch existing open trades, the
// entry SIGNAL logic itself (9/21 EMA cross, RSI, mean-reversion), or
// anything else - it only gates WHEN a new entry is allowed to be evaluated.
// Zone width is ATR-scaled (adapts to volatility) rather than a fixed point
// value. Once price closes outside the zone, it must hold outside for
// EMA200_ClearBars consecutive closed M5 bars before new entries resume -
// a single spike through the zone does not immediately re-arm entries.
input bool   UseEMA200Filter      = true;   // Master switch for the 200 EMA no-trade zone
input int    EMA200_Period        = 200;    // EMA period (M5 timeframe)
input double EMA200_ZoneATR_Mult  = 0.5;    // Zone half-width = ATR(M5,14) * this multiplier
input int    EMA200_ClearBars     = 3;      // Consecutive closed M5 bars required outside the zone before entries resume

//=== G-5: EMA TREND PULLBACK STRATEGY (NEW, INDEPENDENT) ===
// Fully separate signal path, own magic number, own SL/TP, own management -
// see the G-5 header note at the top of the file for the full rationale.
input bool   UseEMA_TrendPullback       = true;       // Master switch for this independent strategy - runs alongside the existing system, doesn't replace it
input long   TP_MagicNumber             = 20260608;   // Separate magic number for this strategy's own trades (same family as MagicNumber)
input int    TP_EMA_Fast_Period         = 9;          // "9 EMA" - together with TP_EMA_Mid_Period defines the pullback gap
input int    TP_EMA_Mid_Period          = 20;         // "20 EMA" - together with TP_EMA_Fast_Period defines the pullback gap
input int    TP_EMA_SL_Period           = 50;         // 50 EMA - primary SL reference for this strategy
input int    TP_EMA_TP_Period           = 200;        // 200 EMA - TP reference (own independent handle - decoupled from G-4's EMA200_Period so the two can be tuned separately)
input double TP_EMA50_TooClose_ATR_Mult = 0.3;        // If entry price is within ATR(M5,14)*this of the 50 EMA, fall back to the swing high/low SL instead
input int    TP_Swing_LookbackBars      = 10;         // Closed bars to look back for the swing high/low SL fallback
input double TP_SL_Buffer_Points        = 10;         // Extra buffer beyond the 50 EMA / swing level, so ordinary noise doesn't clip the SL immediately
input double TP_Min_SL_Points           = 30;         // Safety floor for this strategy's SL distance
input double TP_Max_SL_Points           = 800;        // Safety ceiling for this strategy's SL distance
input double TP_Min_TP_Points           = 30;         // Safety floor for this strategy's TP distance (distance from entry to the 200 EMA)
input double TP_Max_TP_Points           = 3000;       // Safety ceiling for this strategy's TP distance (deliberately generous - the whole idea is letting it run to the 200 EMA)
input double TP_Fixed_Lot               = 0.27;       // Fixed lot size for this strategy's own trades (independent of Fixed_Entry_Lot, since its SL distance is structurally different)
input bool   TP_RespectEMA200ZoneFilter = true;       // Pause this strategy's state machine while G-4's 200-EMA zone block is active (read-only reuse of EMA200_ZoneBlock - G-4 itself is untouched)
input int    TP_MaxConfirmBars          = 5;          // If the pullback/continuation hasn't occurred within this many closed M5 bars of the last step, cancel the setup and re-arm on the next fresh cross

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

// G-4: 200 EMA zone filter state. Updated once per new closed M5 bar in
// UpdateEMA200Filter(), consumed by DecideDirection() and the mean-reversion
// gate in OnTick() - both check EMA200_ZoneBlock, not just one.
bool EMA200_ZoneBlock       = false;
int  EMA200_BarsOutsideZone = 0;

// G-5: EMA Trend Pullback strategy state machine. Fully independent of every
// global variable above - CandleDirection, DirectionDecided, TradeOpenThisCandle,
// M1BarsElapsed etc. all belong to the existing momentum/mean-reversion system
// and are never read or written by this strategy.
enum ENUM_TP_STATE
{
   TP_STATE_IDLE,             // waiting for a fresh 9/20 EMA cross
   TP_STATE_WAIT_PULLBACK,    // cross seen - waiting for a bar to CLOSE inside the 9/20 gap
   TP_STATE_WAIT_CONTINUATION // pullback seen - waiting for a bar to close back beyond the 9 EMA
};
ENUM_TP_STATE TP_State       = TP_STATE_IDLE;
string        TP_Direction   = "NONE";   // "BUY" or "SELL" while TP_State != TP_STATE_IDLE
int           TP_BarsInState = 0;        // closed M5 bars spent in the current state, for the TP_MaxConfirmBars timeout

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
int hEMA200_M5;   // G-4: 200 EMA, M5 timeframe
int hMA20_H1, hMA50_H1, hRSI_H1;
int hRSI_M1;

// G-5: EMA Trend Pullback strategy - own, independent indicator handles.
// Deliberately separate from hEMA_Fast_M5/hEMA_Slow_M5/hEMA200_M5 above so
// this strategy's EMA periods can be tuned without touching the existing
// system's inputs (EMA_Fast_Period/EMA_Slow_Period/EMA200_Period), and vice versa.
int hTP_EMA9_M5, hTP_EMA20_M5, hTP_EMA50_M5, hTP_EMA200_M5;
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   
   hEMA_Fast_M5 = iMA(_Symbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5 = iMA(_Symbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   hATR_M5 = iATR(_Symbol, PERIOD_M5, 14);
   hEMA200_M5 = iMA(_Symbol, PERIOD_M5, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);   // G-4
   
   hEMA_Fast_M15 = iMA(_Symbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15 = iMA(_Symbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   hMA20_H1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);

   // G-5: EMA Trend Pullback strategy - own indicator handles, created
   // regardless of UseEMA_TrendPullback so toggling it on mid-session (input
   // change + reload) doesn't require anything else to change.
   hTP_EMA9_M5   = iMA(_Symbol, PERIOD_M5, TP_EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hTP_EMA20_M5  = iMA(_Symbol, PERIOD_M5, TP_EMA_Mid_Period,  0, MODE_EMA, PRICE_CLOSE);
   hTP_EMA50_M5  = iMA(_Symbol, PERIOD_M5, TP_EMA_SL_Period,   0, MODE_EMA, PRICE_CLOSE);
   hTP_EMA200_M5 = iMA(_Symbol, PERIOD_M5, TP_EMA_TP_Period,   0, MODE_EMA, PRICE_CLOSE);
   
   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA200_M5 == INVALID_HANDLE ||
      hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE ||
      hTP_EMA9_M5 == INVALID_HANDLE || hTP_EMA20_M5 == INVALID_HANDLE ||
      hTP_EMA50_M5 == INVALID_HANDLE || hTP_EMA200_M5 == INVALID_HANDLE)
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
   Print("[INIT] ZX_PP_Guardian_EMA200_v1 - 200 EMA no-trade zone edition");
   Print("[INIT] 200 EMA Filter (G-4): enabled=" + (UseEMA200Filter ? "true" : "false") +
         " | period=" + IntegerToString(EMA200_Period) +
         " | zoneATRmult=" + DoubleToString(EMA200_ZoneATR_Mult, 2) +
         " | clearBars=" + IntegerToString(EMA200_ClearBars));
   Print("[INIT] Instant Breakeven (G-3): enabled=" + (UseInstantBreakeven6 ? "true" : "false") +
         " | lockPoints=" + DoubleToString(Instant_BE_LockPoints, 0) + "pts (fixed, not ATR-scaled)");
   Print("[INIT] Manual Trade Stop Loss (G-1): enabled=" + (UseManualTradeDetection ? "true" : "false") +
         " | closeLossUSD=$" + DoubleToString(ManualTrade_CloseLossUSD, 2));
   Print("[INIT] Manual Trade Basket TP (G-2): enabled=" + (UseManualBasketTP ? "true" : "false") +
         " | minTrades=" + IntegerToString(ManualBasket_MinTrades) +
         " | closeProfitUSD=$" + DoubleToString(ManualBasket_CloseProfitUSD, 2));
   Print("[INIT] Manual Trade Detection: enabled=" + (UseManualTradeDetection ? "true" : "false") +
         (UseManualTradeDetection ? (" | auto-close manual/foreign positions on this symbol at +$" + DoubleToString(ManualTrade_CloseProfitUSD,2)) : ""));

   Print("[INIT] G-5 EMA Trend Pullback: enabled=" + (UseEMA_TrendPullback ? "true" : "false") +
         " | magic=" + IntegerToString((int)TP_MagicNumber) +
         " | EMAs=" + IntegerToString(TP_EMA_Fast_Period) + "/" + IntegerToString(TP_EMA_Mid_Period) +
         "/" + IntegerToString(TP_EMA_SL_Period) + "/" + IntegerToString(TP_EMA_TP_Period) +
         " (fast/mid/SL/TP) | lot=" + DoubleToString(TP_Fixed_Lot,2));
   Print("[INIT] G-5 SL logic: 50EMA unless within " + DoubleToString(TP_EMA50_TooClose_ATR_Mult,2) +
         "xATR of entry, then " + IntegerToString(TP_Swing_LookbackBars) + "-bar swing fallback" +
         " | buffer=" + DoubleToString(TP_SL_Buffer_Points,0) + "pts | clamp[" +
         DoubleToString(TP_Min_SL_Points,0) + "," + DoubleToString(TP_Max_SL_Points,0) + "]pts");
   Print("[INIT] G-5 TP logic: target=200EMA | clamp[" + DoubleToString(TP_Min_TP_Points,0) + "," +
         DoubleToString(TP_Max_TP_Points,0) + "]pts | own fixed SL/TP only, no breakeven/trail/giveback" +
         " | respects G-4 zone filter=" + (TP_RespectEMA200ZoneFilter ? "true" : "false"));
   
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
   if(hEMA200_M5 != INVALID_HANDLE) IndicatorRelease(hEMA200_M5);   // G-4
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1 != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
if(hRSI_M1 != INVALID_HANDLE) IndicatorRelease(hRSI_M1);
   // G-5
   if(hTP_EMA9_M5 != INVALID_HANDLE) IndicatorRelease(hTP_EMA9_M5);
   if(hTP_EMA20_M5 != INVALID_HANDLE) IndicatorRelease(hTP_EMA20_M5);
   if(hTP_EMA50_M5 != INVALID_HANDLE) IndicatorRelease(hTP_EMA50_M5);
   if(hTP_EMA200_M5 != INVALID_HANDLE) IndicatorRelease(hTP_EMA200_M5);
   Print("[STATS] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // ML-1: manual trade detection, runs first and unconditionally, every tick,
   // completely independent of this EA's own HasPosition()/PrevHadPosition
   // state below (a manual trade can exist whether or not this EA currently
   // has one open). Does not alter any existing variable or control flow.
   ManageManualTrades();

   // G-2: manual trade basket take-profit. Runs right after the per-trade
   // manual detection above, every tick, independent of everything else.
   ManageManualBasket();

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
      
      // G-4: refresh the 200 EMA no-trade zone state once per new closed M5
      // bar, BEFORE deciding direction, so DecideDirection() and the
      // mean-reversion gate below both see this bar's up-to-date value.
      UpdateEMA200Filter();

      // G-5: EMA Trend Pullback strategy - fully independent state machine,
      // evaluated once per new closed M5 bar just like G-4 above. Runs
      // regardless of whether the existing momentum/mean-reversion system
      // has a position open or has decided a direction this candle - it
      // opens and manages its own trades under its own separate magic
      // number, in parallel with (not instead of) everything else here.
      UpdateEMA_TrendPullback();
      
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
   // G-4: the 200 EMA no-trade zone blocks BOTH branches below - if
   // EMA200_ZoneBlock is set, DecideDirection() already returned "SKIP"
   // itself (see its own early check), and here we additionally make sure
   // that SKIP does NOT get treated as a genuine "no trend, safe to mean-
   // revert" condition while still inside/clearing the zone.
   bool allowMeanRevOnSkip = (UseMeanReversion && MeanRev_Mode == MEANREV_SKIP_ONLY && CandleDirection == "SKIP" && !EMA200_ZoneBlock);

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
//+------------------------------------------------------------------+
// G-4: 200 EMA no-trade zone. Called once per new closed M5 bar, before
// DecideDirection(). Zone half-width is ATR(M5,14)-scaled, not fixed. Once
// price's last closed bar sits outside the zone, it must hold outside for
// EMA200_ClearBars consecutive closed bars before EMA200_ZoneBlock clears -
// a single bar poking through does not immediately re-arm entries. Sets the
// global EMA200_ZoneBlock, consumed by DecideDirection() and the mean-
// reversion SKIP gate in OnTick().
//+------------------------------------------------------------------+
void UpdateEMA200Filter()
{
   if(!UseEMA200Filter)
   {
      EMA200_ZoneBlock = false;
      return;
   }

   double ema200[];
   ArraySetAsSeries(ema200, true);
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hEMA200_M5, 0, 0, 1, ema200) <= 0 || CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0)
   {
      // Not enough history yet (e.g. right after EA start) - fail safe by
      // not blocking, rather than guessing.
      EMA200_ZoneBlock = false;
      return;
   }

   double zoneDist  = atr[0] * EMA200_ZoneATR_Mult;
   double lastClose = iClose(_Symbol, PERIOD_M5, 1);   // last fully closed M5 bar
   double distToEMA = MathAbs(lastClose - ema200[0]);

   if(distToEMA <= zoneDist)
   {
      // Inside/near the 200 EMA - block, and reset the clear-bar counter so
      // a brief poke outside doesn't get partial credit toward clearing.
      EMA200_BarsOutsideZone = 0;
      EMA200_ZoneBlock = true;
      Print("[EMA200 FILTER] Blocked - price ", DoubleToString(distToEMA/_Point,0),
            "pts from 200EMA, inside ", DoubleToString(zoneDist/_Point,0), "pt zone");
      return;
   }

   // Outside the zone this bar - count consecutive clear closed bars.
   EMA200_BarsOutsideZone++;
   if(EMA200_BarsOutsideZone < EMA200_ClearBars)
   {
      EMA200_ZoneBlock = true;
      Print("[EMA200 FILTER] Clearing zone - bar ", EMA200_BarsOutsideZone, "/", EMA200_ClearBars,
            " outside (dist=", DoubleToString(distToEMA/_Point,0), "pts)");
      return;
   }

   if(EMA200_ZoneBlock)   // was blocked, just cleared this bar - log the unblock once
      Print("[EMA200 FILTER] Cleared - entries re-armed after ", EMA200_BarsOutsideZone, " bars outside zone");
   EMA200_ZoneBlock = false;
}

//+------------------------------------------------------------------+
string DecideDirection()
{
   // G-4: 200 EMA no-trade zone - if price is inside the zone, or hasn't yet
   // held clear of it for EMA200_ClearBars consecutive bars, no new momentum
   // direction is evaluated at all this bar. EMA200_ZoneBlock was refreshed
   // for this bar by UpdateEMA200Filter() just before this function was called.
   if(EMA200_ZoneBlock)
      return "SKIP";
   
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
         double instSL = -1, beSL = -1, trailSL = -1, guardSL = -1, peakPts = 0;

         // --- Stage 0 (G-3): instant breakeven, fixed +Instant_BE_LockPoints, ---
         // arms the moment the trade is positive at all (profitPts > 0), independent
         // of the Stage 1 breakeven trigger/lock below.
         if(UseInstantBreakeven6 && profitPts > 0)
         {
            instSL = NormalizeDouble(openPrice + Instant_BE_LockPoints * _Point, _Digits);
            if(instSL > bestSL) bestSL = instSL;
         }

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
            string stage = (bestSL == guardSL) ? "GUARD" : (bestSL == beSL) ? "BREAKEVEN" : (bestSL == instSL) ? "INSTANT_BE6" : "TRAIL";
            Print("[", stage, "] BUY SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "INSTANT_BE6" ? (" | fixed lock=" + DoubleToString(Instant_BE_LockPoints,0) + "pts")
                   : stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts")
                   : stage == "GUARD"   ? (" | peak=" + DoubleToString(peakPts,0) + "pts locking>=" + DoubleToString(100-Giveback_Max_Pct,0) + "% of peak")
                                        : (" | trailMult=" + DoubleToString(GetProgressiveTrailMult(atrPts, profitPts),2) + "xATR")));
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set
         bool haveCandidate = false;
         double instSL = -1, beSL = -1, trailSL = -1, guardSL = -1, peakPts = 0;

         // --- Stage 0 (G-3): instant breakeven, fixed -Instant_BE_LockPoints, ---
         // arms the moment the trade is positive at all (profitPts > 0), independent
         // of the Stage 1 breakeven trigger/lock below.
         if(UseInstantBreakeven6 && profitPts > 0)
         {
            instSL = NormalizeDouble(openPrice - Instant_BE_LockPoints * _Point, _Digits);
            if(!haveCandidate || instSL < bestSL) { bestSL = instSL; haveCandidate = true; }
         }

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
            string stage = (bestSL == guardSL) ? "GUARD" : (bestSL == instSL) ? "INSTANT_BE6" : (UseBreakEven && bestSL == beSL) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] SELL SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "INSTANT_BE6" ? (" | fixed lock=" + DoubleToString(Instant_BE_LockPoints,0) + "pts")
                   : stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts")
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
// ML-1: MANUAL TRADE DETECTION + AUTO-CLOSE
// See the ML-1 header note near the top of the file for the full
// rationale. This function is completely independent of every other
// function in this EA - it does not read or write TradeOpenThisCandle,
// TodayWins/TodayLosses, or any other of the EA's own state, and no
// existing function was changed to add this. It simply scans this
// symbol's open positions for any magic number OTHER than MagicNumber
// (i.e. not opened by this EA - a manual trade, or a different EA/
// script), logs it, and closes it once its floating profit reaches
// ManualTrade_CloseProfitUSD. A manual position that is still below the
// profit threshold (including one in loss) is left completely alone -
// this never modifies a manual trade's SL/TP and never cuts a manual
// loss, it only ever takes profit on a manual trade once it has reached
// the configured target.
//+------------------------------------------------------------------+
void ManageManualTrades()
{
   if(!UseManualTradeDetection) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;

      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic == MagicNumber) continue;   // this EA's own trade - handled by the functions above, untouched
      if(posMagic == TP_MagicNumber) continue;  // G-5: EMA Trend Pullback strategy's own trade - has its own dedicated management, not a manual/foreign trade

      ulong ticket   = PositionGetInteger(POSITION_TICKET);
      double profit  = PositionGetDouble(POSITION_PROFIT);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(profit >= ManualTrade_CloseProfitUSD)
      {
         if(trade.PositionClose(ticket))
            Print("[MANUAL TRADE DETECTED] ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                  " ticket ", ticket, " (magic=", posMagic, ") closed at +$", DoubleToString(profit, 2),
                  " | threshold=$", DoubleToString(ManualTrade_CloseProfitUSD, 2));
         else
            Print("[MANUAL TRADE] Close failed for ticket ", ticket, ": ",
                  trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
      // G-1: strict per-trade stop loss - a manual trade left alone by ML_v1
      // while it sat in a loss is now force-closed once its floating loss
      // reaches ManualTrade_CloseLossUSD. Independent of the profit branch
      // above; only one of the two can fire per ticket per tick.
      else if(profit <= -ManualTrade_CloseLossUSD)
      {
         if(trade.PositionClose(ticket))
            Print("[MANUAL TRADE SL] ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                  " ticket ", ticket, " (magic=", posMagic, ") closed at -$", DoubleToString(MathAbs(profit), 2),
                  " | threshold=$", DoubleToString(ManualTrade_CloseLossUSD, 2));
         else
            Print("[MANUAL TRADE SL] Close failed for ticket ", ticket, ": ",
                  trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
// G-2: MANUAL TRADE BASKET TAKE-PROFIT
// Independent of, and additional to, ManageManualTrades() above. Scans this
// symbol's positions for the same "manual" definition (magic != MagicNumber).
// If ManualBasket_MinTrades or more of them are open at once, sums their net
// floating profit (profit + swap + commission) and, once that combined total
// reaches ManualBasket_CloseProfitUSD, closes ALL of those manual trades
// together in one pass. Does not read or write any state used elsewhere in
// this EA. If fewer than ManualBasket_MinTrades manual trades are open, this
// function does nothing and returns immediately - the per-trade logic above
// is unaffected either way.
//+------------------------------------------------------------------+
void ManageManualBasket()
{
   if(!UseManualBasketTP) return;

   ulong  manualTickets[];
   int    manualCount = 0;
   double basketNet    = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;

      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic == MagicNumber) continue;   // this EA's own trade - not part of the manual basket
      if(posMagic == TP_MagicNumber) continue;  // G-5: EMA Trend Pullback strategy's own trade - has its own dedicated management, not part of the manual basket

      ulong ticket = PositionGetInteger(POSITION_TICKET);

      ArrayResize(manualTickets, manualCount + 1);
      manualTickets[manualCount] = ticket;
      manualCount++;

      basketNet += PositionGetDouble(POSITION_PROFIT)
                 + PositionGetDouble(POSITION_SWAP)
                 + PositionGetDouble(POSITION_COMMISSION);
   }

   if(manualCount < ManualBasket_MinTrades) return;

   if(basketNet >= ManualBasket_CloseProfitUSD)
   {
      Print("[MANUAL BASKET TP] ", manualCount, " manual trades | combined net=+$",
            DoubleToString(basketNet, 2), " | threshold=$", DoubleToString(ManualBasket_CloseProfitUSD, 2),
            " | closing all");

      for(int i = 0; i < manualCount; i++)
      {
         if(!trade.PositionClose(manualTickets[i]))
            Print("[MANUAL BASKET TP] Close failed for ticket ", manualTickets[i], ": ",
                  trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
   }
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

//+------------------------------------------------------------------+
// G-5: EMA TREND PULLBACK STRATEGY - fully independent signal path.
// See the G-5 header note at the top of the file for the full rationale.
// Everything below is NEW code; nothing above this point in the file was
// changed to support it, aside from the two one-line manual-trade
// exclusions noted where they occur.
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// G-5 helper: does this strategy currently have a position open on this
// symbol? Mirrors HasPosition() exactly, but filtered on TP_MagicNumber
// instead of MagicNumber, so the two strategies each independently enforce
// their own "one trade at a time" rule without ever seeing each other's
// positions.
//+------------------------------------------------------------------+
bool TP_HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == TP_MagicNumber)
            return true;
   return false;
}

//+------------------------------------------------------------------+
// G-5 helper: computes this strategy's own SL/TP for a prospective entry at
// entryPrice. SL defaults to the current TP_EMA_SL_Period (50) EMA, plus a
// small buffer; if price is currently within ATR*TP_EMA50_TooClose_ATR_Mult
// of that EMA (i.e. the 50 EMA is "too close" to give the trade breathing
// room), it falls back instead to the most recent swing high/low over
// TP_Swing_LookbackBars closed bars. TP is simply the current
// TP_EMA_TP_Period (200) EMA level - the "ride it back to the 200 EMA"
// target. Both distances are clamped by their own safety floor/ceiling
// inputs, consistent with how every other exit mechanism in this file is
// clamped.
//+------------------------------------------------------------------+
void TP_GetSLTP(bool isBuy, double entryPrice, double &sl_dist, double &tp_dist)
{
   double atr = GetATR();

   double ema50arr[];
   ArraySetAsSeries(ema50arr, true);
   CopyBuffer(hTP_EMA50_M5, 0, 0, 1, ema50arr);
   double ema50 = ema50arr[0];

   double ema200arr[];
   ArraySetAsSeries(ema200arr, true);
   CopyBuffer(hTP_EMA200_M5, 0, 0, 1, ema200arr);
   double ema200 = ema200arr[0];

   double tooCloseDist = atr * TP_EMA50_TooClose_ATR_Mult;
   bool   usedSwing    = false;
   double slPrice;

   if(MathAbs(entryPrice - ema50) <= tooCloseDist)
   {
      // 50 EMA sits too close to entry to leave room for normal noise -
      // fall back to the swing high/low over the lookback window instead.
      usedSwing = true;
      if(isBuy)
      {
         int lIdx = iLowest(_Symbol, PERIOD_M5, MODE_LOW, TP_Swing_LookbackBars, 1);   // closed bars only (shift starts at 1)
         double swingLow = (lIdx >= 0) ? iLow(_Symbol, PERIOD_M5, lIdx) : (entryPrice - TP_Min_SL_Points * _Point);
         slPrice = swingLow - TP_SL_Buffer_Points * _Point;
      }
      else
      {
         int hIdx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, TP_Swing_LookbackBars, 1);
         double swingHigh = (hIdx >= 0) ? iHigh(_Symbol, PERIOD_M5, hIdx) : (entryPrice + TP_Min_SL_Points * _Point);
         slPrice = swingHigh + TP_SL_Buffer_Points * _Point;
      }
   }
   else
   {
      slPrice = isBuy ? (ema50 - TP_SL_Buffer_Points * _Point) : (ema50 + TP_SL_Buffer_Points * _Point);
   }

   double slPts = MathAbs(entryPrice - slPrice) / _Point;
   if(slPts < TP_Min_SL_Points) slPts = TP_Min_SL_Points;
   if(slPts > TP_Max_SL_Points) slPts = TP_Max_SL_Points;
   sl_dist = slPts * _Point;

   double tpPts = MathAbs(ema200 - entryPrice) / _Point;
   if(tpPts < TP_Min_TP_Points) tpPts = TP_Min_TP_Points;
   if(tpPts > TP_Max_TP_Points) tpPts = TP_Max_TP_Points;
   tp_dist = tpPts * _Point;

   Print("[TP-EMA SLTP] ", (isBuy ? "BUY" : "SELL"),
         " | SL source=", (usedSwing ? "SWING(" + IntegerToString(TP_Swing_LookbackBars) + "bar)" : "50EMA"),
         " | SL=", DoubleToString(slPts,0), "pts | TP(->200EMA)=", DoubleToString(tpPts,0), "pts",
         " | ATR=", DoubleToString(atr/_Point,1), "pts | 50EMA dist=", DoubleToString(MathAbs(entryPrice-ema50)/_Point,0),
         "pts (tooClose<=", DoubleToString(tooCloseDist/_Point,0), "pts)");
}

//+------------------------------------------------------------------+
// G-5: opens this strategy's own BUY, using its own SL/TP (TP_GetSLTP()) and
// its own fixed lot (TP_Fixed_Lot), tagged with TP_MagicNumber so it is
// invisible to every one of the existing system's management functions.
// The trade object's magic number is temporarily switched to TP_MagicNumber
// for this one call, then restored to MagicNumber immediately after, so
// every other entry path in this file (ExecuteBuy/ExecuteSell) is completely
// unaffected and keeps opening trades under MagicNumber exactly as before.
//+------------------------------------------------------------------+
void TP_ExecuteBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl_dist, tp_dist;
   TP_GetSLTP(true, ask, sl_dist, tp_dist);

   double lot = TP_Fixed_Lot;
   if(lot < MinLot) lot = MinLot;
   if(lot > MaxLot) lot = MaxLot;

   double sl = NormalizeDouble(ask - sl_dist, _Digits);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);

   trade.SetExpertMagicNumber(TP_MagicNumber);
   bool ok = trade.Buy(lot, _Symbol, ask, sl, tp, "TP_EMA BUY");
   trade.SetExpertMagicNumber(MagicNumber);   // restore - every other entry path in this file relies on this default

   if(!ok)
      Print("[TP-EMA ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
      Print("[TP-EMA ENTRY] BUY ", DoubleToString(lot,2), " lots | SL:", sl, " TP:", tp,
            " | magic=", (int)TP_MagicNumber, " | fixed SL/TP only - no breakeven/trail/giveback management");
}

//+------------------------------------------------------------------+
// G-5: see the note above TP_ExecuteBuy() - identical pattern, mirrored.
//+------------------------------------------------------------------+
void TP_ExecuteSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl_dist, tp_dist;
   TP_GetSLTP(false, bid, sl_dist, tp_dist);

   double lot = TP_Fixed_Lot;
   if(lot < MinLot) lot = MinLot;
   if(lot > MaxLot) lot = MaxLot;

   double sl = NormalizeDouble(bid + sl_dist, _Digits);
   double tp = NormalizeDouble(bid - tp_dist, _Digits);

   trade.SetExpertMagicNumber(TP_MagicNumber);
   bool ok = trade.Sell(lot, _Symbol, bid, sl, tp, "TP_EMA SELL");
   trade.SetExpertMagicNumber(MagicNumber);   // restore - every other entry path in this file relies on this default

   if(!ok)
      Print("[TP-EMA ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
      Print("[TP-EMA ENTRY] SELL ", DoubleToString(lot,2), " lots | SL:", sl, " TP:", tp,
            " | magic=", (int)TP_MagicNumber, " | fixed SL/TP only - no breakeven/trail/giveback management");
}

//+------------------------------------------------------------------+
// G-5: the strategy's state machine. Called once per new closed M5 bar from
// OnTick() (right after UpdateEMA200Filter()). Sequence per direction:
//   1) IDLE              -> fresh 9/20 EMA cross detected -> WAIT_PULLBACK
//   2) WAIT_PULLBACK     -> a bar CLOSES inside the 9/20 gap -> WAIT_CONTINUATION
//   3) WAIT_CONTINUATION -> a bar closes back beyond the 9 EMA, same
//                           direction as the original cross -> ENTRY, back to IDLE
// A fresh cross always takes priority and (re)starts the sequence, in either
// direction. If neither the pullback nor the continuation step happens
// within TP_MaxConfirmBars closed bars of entering that step, the setup
// times out back to IDLE - a stale setup is discarded rather than fired
// late, and a fresh cross is required to try again.
//+------------------------------------------------------------------+
void UpdateEMA_TrendPullback()
{
   if(!UseEMA_TrendPullback) return;

   // G-4 interaction: pause the whole state machine (including picking up a
   // fresh cross) while price is inside/still clearing the 200-EMA zone -
   // there's no point starting a "run to the 200 EMA" trade with no room to
   // run. Read-only reuse of G-4's own global; G-4 itself is untouched.
   if(TP_RespectEMA200ZoneFilter && EMA200_ZoneBlock)
      return;

   // One trade at a time for this strategy, exactly like the existing system.
   if(TP_HasPosition())
      return;

   double ema9[], ema20[];
   ArraySetAsSeries(ema9, true);
   ArraySetAsSeries(ema20, true);
   if(CopyBuffer(hTP_EMA9_M5, 0, 0, 3, ema9) <= 0 || CopyBuffer(hTP_EMA20_M5, 0, 0, 3, ema20) <= 0)
      return;   // not enough history yet

   MqlRates bar[];
   ArraySetAsSeries(bar, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 3, bar) <= 0)
      return;

   // Indices: 0 = current forming bar, 1 = last fully CLOSED bar, 2 = the one before it.
   bool bullCrossNow = (ema9[1] > ema20[1]) && (ema9[2] <= ema20[2]);
   bool bearCrossNow = (ema9[1] < ema20[1]) && (ema9[2] >= ema20[2]);

   if(bullCrossNow || bearCrossNow)
   {
      TP_State       = TP_STATE_WAIT_PULLBACK;
      TP_Direction   = bullCrossNow ? "BUY" : "SELL";
      TP_BarsInState = 0;
      Print("[TP-EMA] Fresh ", IntegerToString(TP_EMA_Fast_Period), "/", IntegerToString(TP_EMA_Mid_Period),
            " EMA cross -> ", TP_Direction, ". Watching for a pullback CLOSE into the gap...");
      return;
   }

   if(TP_State == TP_STATE_IDLE)
      return;

   TP_BarsInState++;
   if(TP_BarsInState > TP_MaxConfirmBars)
   {
      Print("[TP-EMA] Setup timed out (", TP_Direction, ") after ", TP_BarsInState,
            " bars without progressing. Resetting - waiting for a fresh cross.");
      TP_State     = TP_STATE_IDLE;
      TP_Direction = "NONE";
      return;
   }

   double closeBar1 = bar[1].close;
   double openBar1  = bar[1].open;

   if(TP_State == TP_STATE_WAIT_PULLBACK)
   {
      bool pulledBack = (TP_Direction == "BUY")
                        ? (closeBar1 <= ema9[1] && closeBar1 >= ema20[1])
                        : (closeBar1 >= ema9[1] && closeBar1 <= ema20[1]);

      if(pulledBack)
      {
         TP_State       = TP_STATE_WAIT_CONTINUATION;
         TP_BarsInState = 0;
         Print("[TP-EMA] Pullback confirmed (", TP_Direction, ") - bar closed inside the ",
               IntegerToString(TP_EMA_Fast_Period), "/", IntegerToString(TP_EMA_Mid_Period),
               " gap. Watching for continuation...");
      }
      return;
   }

   if(TP_State == TP_STATE_WAIT_CONTINUATION)
   {
      bool continued = (TP_Direction == "BUY")
                        ? (closeBar1 > ema9[1] && closeBar1 > openBar1)
                        : (closeBar1 < ema9[1] && closeBar1 < openBar1);

      if(continued)
      {
         Print("[TP-EMA] Continuation confirmed (", TP_Direction, ") - entering.");
         if(TP_Direction == "BUY") TP_ExecuteBuy(); else TP_ExecuteSell();
         TP_State     = TP_STATE_IDLE;
         TP_Direction = "NONE";
      }
      return;
   }
}

