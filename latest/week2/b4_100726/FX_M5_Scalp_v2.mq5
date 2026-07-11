//+------------------------------------------------------------------+
//|                                          FX_M5_Scalp_v2.mq5      |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"

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
// the rest of the code base. It is NOT used directly by CalcLot() - see the
// V2-A RISK-BASED LOT SIZING note above CalcLot() for what actually sizes
// trades in FX_M5_Scalp_v2.
input double LotSize = 0.10;              // (unused for sizing — see CalcLot())
input long MagicNumber = 20260607;

//=== FIXED LOT SIZE (fallback when UseRiskSizing = false) ===
// As of FX_M5_Scalp_v2, this is only used when UseRiskSizing (below) is
// false. When UseRiskSizing is true (the default), CalcLot() instead sizes
// each trade off its OWN sl_dist and RiskPercent - see the V2-A note above
// CalcLot() for why this matters now that mean-reversion and momentum
// trades can have very different SL distances.
input double Fixed_Entry_Lot = 0.27;      // Fixed lot size used for ALL entries when UseRiskSizing=false

//=== SL/TP SETTINGS ===
input double Fixed_SL_Points = 1503;      // Fixed SL distance in points (e.g. price 4060 → SL 2557)
input double ATR_TP_Mult = 3.0;           // TP multiplier based on ATR
input double Max_TP_Points = 150;         // Cap TP at this many points (avoid too high)
input double Min_TP_Points = 40;          // Minimum TP to ensure worthwhile trades

//=== #3 HOLD WINNERS PAST CANDLE (IMPROVED) ===
input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;    // REDUCED from 30 - catch smaller trends
input double HoldTrailBuffer = 10;        // Keep trail buffer this far behind price

//=== #4 TRAILING STOP (OPTIMIZED) ===
input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 0.8;        // REDUCED from 1.0 - tighter trail
input int Trail_StartPoints = 25;         // REDUCED from 40 - trail earlier
input int Trail_StepPoints = 15;          // Move SL by this much when trailing

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

//=== #5 MTF SCORING ===
input bool UseMTF_Scoring = true;
input int MTF_MinScore = 2;

//=== #6 DAILY LIMITS + RISK SIZING ===
// As of FX_M5_Scalp_v2, UseRiskSizing/RiskPercent are no longer dead code -
// see the V2-A note above CalcLot(). MinLot/MaxLot are used as bounds either
// way (risk-based or fixed-lot fallback).
input bool UseRiskSizing = true;
input double RiskPercent = 0.5;           // % of account balance risked per trade when UseRiskSizing=true
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
   
   Print("[INIT] FX M5 Scalp v2 - risk-based lot sizing + gated legacy TP edition");
   Print("[INIT] Lot sizing: UseRiskSizing=" + (UseRiskSizing ? "true" : "false") +
         (UseRiskSizing ? (" | RiskPercent=" + DoubleToString(RiskPercent,2) + "% (sized per-trade off actual sl_dist)")
                        : (" | Fixed_Entry_Lot=" + DoubleToString(Fixed_Entry_Lot,2) + " lots")) +
         " | bounds=[" + DoubleToString(MinLot,2) + "," + DoubleToString(MaxLot,2) + "]");
   Print("[INIT] Fixed SL=" + DoubleToString(Fixed_SL_Points, 0) + "pts | TP=" + DoubleToString(ATR_TP_Mult, 2) + "xATR");
   Print("[INIT] Breakeven: trigger floor=" + DoubleToString(BreakEven_TriggerPoints,0) + "pts | lock floor=" + DoubleToString(BreakEven_LockPoints,0) + "pts | enabled=" + (UseBreakEven ? "true" : "false"));
   Print("[INIT] ATR-relative Breakeven: enabled=" + (UseATR_BreakEven ? "true" : "false") +
         " | triggerMult=" + DoubleToString(BreakEven_TriggerATR_Mult,2) + "xATR" +
         " | lockMult=" + DoubleToString(BreakEven_LockATR_Mult,2) + "xATR");
   Print("[INIT] Trail start=" + IntegerToString(Trail_StartPoints) + "pts | Step=" + IntegerToString(Trail_StepPoints) + "pts");
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
// its own ATR-relative SL/TP instead of the trend engine's Fixed_SL_Points/
// ATR*3 TP. Momentum trades (isMeanRev=false, the default) go through the
// exact same code path as v7 - nothing about that branch changed.
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

   // Fixed SL at 18 points always, regardless of lot size or volatility
   sl_dist = Fixed_SL_Points * _Point;
   
   // TP still uses ATR for dynamic targeting
   double atr = GetATR();
   double atrPoints = atr / _Point;
   double tp_pts = atrPoints * ATR_TP_Mult;
   
   if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
   if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;
   
   tp_dist = tp_pts * _Point;
   
   Print("[SLTP] Fixed SL=", DoubleToString(Fixed_SL_Points,0), 
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
// *** V2-A: RISK-BASED LOT SIZING ***
// FX_M5_Scalp_v1 gave mean-reversion trades their own dedicated,
// deliberately tighter ATR-relative SL (as low as the 15pt floor) while
// momentum trades kept the wide Fixed_SL_Points backstop (1503pts). With
// CalcLot() ignoring sl_dist and always returning a fixed lot, those two
// trade types ended up risking wildly different dollar amounts per trade
// for no intentional reason - a mean-reversion trade at ~20pt SL risks a
// small fraction of what a momentum trade at 1503pt SL risks, at the same
// lot size.
//
// CalcLot() now sizes each trade off its OWN sl_dist (the actual SL
// distance GetSLTP() computed for THIS trade) and RiskPercent, so every
// trade - regardless of which branch opened it - risks a comparable dollar
// amount of the account balance. Set UseRiskSizing=false to fall back to
// the old fixed Fixed_Entry_Lot behavior (still bounded by MinLot/MaxLot)
// for side-by-side comparison.
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
   double lot;

   if(UseRiskSizing && sl_dist > 0)
   {
      double slPoints  = sl_dist / _Point;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      // Value (in account currency) of a 1-point move for 1.0 lot.
      double pointValue = (tickSize > 0) ? (tickValue * (_Point / tickSize)) : tickValue;

      double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);

      if(pointValue > 0 && slPoints > 0)
      {
         lot = riskAmount / (slPoints * pointValue);

         // Snap to the broker's lot step so the volume is always valid.
         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         if(lotStep > 0)
            lot = MathFloor(lot / lotStep + 0.0000001) * lotStep;
      }
      else
      {
         // Fail safe: if tick value/size lookup failed for any reason,
         // fall back to the fixed lot rather than risk a bad calculation.
         lot = Fixed_Entry_Lot;
      }
   }
   else
   {
      // UseRiskSizing = false: exact old fixed-lot behavior.
      lot = Fixed_Entry_Lot;
   }

   // Always respect the broker's minimum/maximum volume bounds, regardless
   // of which path above produced the lot value.
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
// *** BREAKEVEN + ATR TRAIL CHANGE ***
// This function now protects a trade in TWO stages instead of one:
//
//  Stage 1 - BREAKEVEN (new): as soon as profit reaches
//            BreakEven_TriggerPoints, the SL is moved to
//            entry price (+/- BreakEven_LockPoints) to lock in a small
//            guaranteed profit and remove the original (often wide)
//            Fixed_SL_Points risk. This fires EARLIER than the ATR trail
//            because BreakEven_TriggerPoints is expected to be smaller
//            than Trail_StartPoints.
//
//  Stage 2 - ATR TRAIL (unchanged mechanic): once profit reaches
//            Trail_StartPoints, the SL trails behind price at a distance
//            of ATR * Trail_ATR_Mult, tightening as the trade runs.
//
// Both candidate stop levels are computed every tick, and the SL is only
// ever moved to whichever candidate is MOST PROTECTIVE (closest to current
// price in the trade's favor) and strictly better than the current SL -
// so the stop can only ratchet forward, never backward, and Stage 2 will
// naturally take over from Stage 1 once the ATR trail overtakes breakeven.
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double atr = GetATR();
   double trailDist = atr * Trail_ATR_Mult;
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

         // --- Stage 1: breakeven candidate (ATR-relative when UseATR_BreakEven) ---
         if(UseBreakEven && profitPts >= effTriggerPts)
         {
            double beSL = NormalizeDouble(openPrice + beLockDist, _Digits);
            if(beSL > bestSL) bestSL = beSL;
         }

         // --- Stage 2: ATR trail candidate ---
         if(profitPts >= Trail_StartPoints)
         {
            double trailSL = NormalizeDouble(bid - trailDist, _Digits);
            if(trailSL > bestSL) bestSL = trailSL;
         }

         // Only modify if the best candidate is a real, meaningful improvement
         if(bestSL > curSL + trailStep)
         {
            trade.PositionModify(ticket, bestSL, curTP);
            string stage = (bestSL == NormalizeDouble(openPrice + beLockDist, _Digits)) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] BUY SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts") : ""));
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set
         bool haveCandidate = false;

         // --- Stage 1: breakeven candidate (ATR-relative when UseATR_BreakEven) ---
         if(UseBreakEven && profitPts >= effTriggerPts)
         {
            double beSL = NormalizeDouble(openPrice - beLockDist, _Digits);
            if(!haveCandidate || beSL < bestSL) { bestSL = beSL; haveCandidate = true; }
         }

         // --- Stage 2: ATR trail candidate ---
         if(profitPts >= Trail_StartPoints)
         {
            double trailSL = NormalizeDouble(ask + trailDist, _Digits);
            if(!haveCandidate || trailSL < bestSL) { bestSL = trailSL; haveCandidate = true; }
         }

         // Only modify if we have a candidate and it's a real improvement
         // (tighter/closer to price than the current SL, or SL was unset)
         if(haveCandidate && (curSL == 0 || bestSL < curSL - trailStep))
         {
            trade.PositionModify(ticket, bestSL, curTP);
            string stage = (UseBreakEven && bestSL == NormalizeDouble(openPrice - beLockDist, _Digits)) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] SELL SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts") : ""));
         }
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
