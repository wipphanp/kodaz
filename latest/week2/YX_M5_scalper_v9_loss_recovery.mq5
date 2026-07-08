//+------------------------------------------------------------------+
//|                                        ea_5minCandle_scalp_v4.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.03"

//+------------------------------------------------------------------+
//| YX M5 Scalper v9 — LOSS RECOVERY (hedge/average/close) edition     |
//| Quant Only Closed Candle M1 RSI + Mean Reversion                  |
//| Lower entry thresholds for more trades on both sides              |
//| Same optimized exit logic as v3                                   |
//|                                                                    |
//| CHANGES IN THIS VERSION (vs YX_M5_scalper_v7_breakeven_stop):      |
//|  5. LOSS RECOVERY SUBSYSTEM (NEW) - entirely additive.              |
//|     The original entry logic (DecideDirection, CheckM1Confirmation,|
//|     ExecuteBuy/Sell) and the original per-trade exit logic          |
//|     (GetSLTP, CheckProfitTarget, ManageTrailing breakeven+ATR       |
//|     trail) are UNCHANGED. This subsystem only watches an already-  |
//|     open ORIGINAL strategy trade and, once its floating loss       |
//|     reaches LossRecovery_TriggerDollars, makes a ONE-TIME decision: |
//|                                                                    |
//|       CLOSE    - cut the loss immediately.                         |
//|       HEDGE    - open an OPPOSITE-direction order at                |
//|                  LossRecovery_Lot, freezing further loss growth     |
//|                  on the pair without giving up the original level.  |
//|       AVERAGE  - open a SAME-direction order at LossRecovery_Lot,   |
//|                  pulling the combined breakeven price closer to     |
//|                  market (classic martingale-style add - INCREASES   |
//|                  size against an adverse move, so a continued move  |
//|                  against you compounds the loss instead of just     |
//|                  holding it flat).                                  |
//|       AUTO     - picks one of the three above using the EA's        |
//|                  existing MTF trend signals as a simple heuristic:  |
//|                  trend still fully aligned with the original trade  |
//|                  -> AVERAGE; trend fully flipped against it ->      |
//|                  CLOSE; anything mixed/uncertain -> HEDGE. This is  |
//|                  a heuristic, not a guarantee of profit.            |
//|                                                                    |
//|     Once HEDGE or AVERAGE fires, the original ticket + the new      |
//|     recovery ticket become a tracked "basket". Every tick, their    |
//|     COMBINED floating profit is checked; once it reaches            |
//|     LossRecovery_CloseInProfit, BOTH legs are closed together.      |
//|     This is a ONE-SHOT recovery per original trade - it never adds  |
//|     a second recovery leg on top of the first, so this cannot turn  |
//|     into an open-ended martingale ladder. The original trade's own  |
//|     wide Fixed_SL_Points stop remains the final backstop throughout.|
//|                                                                    |
//|     IMPORTANT: HEDGE requires a "Hedging"-type MT5 account. On a   |
//|     Netting account, an opposite-direction order on the same        |
//|     symbol nets against the existing position instead of creating  |
//|     a second independent ticket - this basket-tracking design      |
//|     assumes Hedging mode. Confirm your account type before using    |
//|     HEDGE or AUTO mode live.                                        |
//|                                                                    |
//|     To keep the existing strategy's own exit logic exactly as-is,  |
//|     recovery legs (comment starting "RECOVERY_") are explicitly     |
//|     excluded from CheckProfitTarget(), HandleCandleEndClose(), and  |
//|     ManageTrailing() - those three continue to manage ONLY the      |
//|     original strategy's own positions, unchanged. Recovery legs are |
//|     managed exclusively by ManageRecoveryBaskets() below.           |
//|     See "*** LOSS RECOVERY SUBSYSTEM ***" comment blocks for detail.|
//|                                                                    |
//|  Carried over from YX_M5_scalper_v7_breakeven_stop:                |
//|  3. Breakeven stop stage ahead of the ATR trail - unchanged.        |
//|                                                                    |
//|  Carried over from YX_M5_scalper_v7_fixedlot_0.27:                |
//|  1. Entry lot is hard-coded to 0.27 for BUY and SELL (CalcLot()).  |
//|  2. Fixed_SL_Points default = 1503 - unchanged.                    |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
// NOTE: LotSize is kept here only for reference / backward compatibility with
// the rest of the code base. It is NO LONGER USED to size trades - as of this
// version every trade (BUY and SELL) uses a hard-coded fixed lot of 0.27,
// enforced inside CalcLot(). Changing this input will have NO effect on the
// actual traded volume.
input double LotSize = 0.10;              // (unused for sizing — see CalcLot(), fixed at 0.27)
input long MagicNumber = 20260607;

//=== FIXED LOT SIZE (ALWAYS APPLIED TO BUY & SELL) ===
// This is the single source of truth for trade volume in this EA version.
// Every BUY and every SELL will use exactly this many lots, regardless of
// account balance, risk percent, or stop-loss distance.
input double Fixed_Entry_Lot = 0.27;      // Fixed lot size used for ALL entries (BUY + SELL)

//=== SL/TP SETTINGS ===
input double Fixed_SL_Points = 1503;      // Fixed SL distance in points (e.g. price 4060 → SL 2557)
input double ATR_TP_Mult = 3.0;           // TP multiplier based on ATR
input double Max_TP_Points = 150;         // Cap TP at this many points (avoid too high)
input double Min_TP_Points = 40;          // Minimum TP to ensure worthwhile trades

//=== #7 LOSS RECOVERY (NEW) ===
// See the version-header comment block at the top of this file for the full
// explanation of what this does and its risks. Off by default
// (UseLossRecovery = false) so existing behavior is 100% unchanged unless
// you explicitly turn it on.
enum ENUM_RECOVERY_MODE
{
   RECOVERY_CLOSE,    // Always cut the loss immediately once triggered
   RECOVERY_HEDGE,    // Always open an opposite-direction recovery order
   RECOVERY_AVERAGE,  // Always open a same-direction recovery order (martingale-style add)
   RECOVERY_AUTO      // Pick CLOSE/HEDGE/AVERAGE using existing MTF trend signals
};

input bool   UseLossRecovery            = false;  // Master switch - if false, this subsystem does nothing at all
input double LossRecovery_TriggerDollars = 50.0;  // Floating loss (in account currency) that arms a recovery decision
input ENUM_RECOVERY_MODE LossRecoveryMode = RECOVERY_AUTO; // How to react once triggered
input double LossRecovery_Lot           = 0.4;    // Lot size for the HEDGE/AVERAGE recovery order
input double LossRecovery_CloseInProfit = 0.50;   // Close BOTH legs once their COMBINED floating profit reaches this

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
input double BreakEven_TriggerPoints = 15;  // Profit (pts) needed to arm the breakeven move
input double BreakEven_LockPoints = 5;      // Buffer locked in beyond entry once armed (covers spread/commission)

//=== #5 MTF SCORING ===
input bool UseMTF_Scoring = true;
input int MTF_MinScore = 2;

//=== #6 DAILY LIMITS + RISK SIZING ===
input bool UseRiskSizing = true;
input double RiskPercent = 0.5;           // Reduced to 0.5% for safer trading
input double MaxLot = 1.0;
input double MinLot = 0.01;

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

//=== LOSS RECOVERY STATE ===
// Tracks original tickets that have already had a recovery decision made,
// so ManageLossRecovery() only ever acts ONCE per original trade - it
// cannot re-trigger and stack a second recovery leg on top of the first.
ulong RecoveryHandledTickets[];

// A "basket" pairs an original ticket with the recovery ticket opened
// against it (HEDGE or AVERAGE). ManageRecoveryBaskets() watches each
// active basket's COMBINED floating profit and closes both legs together
// once it reaches LossRecovery_CloseInProfit.
struct RecoveryBasket
{
   ulong originalTicket;
   ulong recoveryTicket;
   bool  active;
};
RecoveryBasket RecoveryBaskets[];

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
   
   Print("[INIT] YX M5 Scalper v7 - FIXED LOT + BREAKEVEN STOP edition");
   Print("[INIT] Fixed Entry Lot=" + DoubleToString(Fixed_Entry_Lot, 2) + " lots (applied to BOTH BUY and SELL)");
   Print("[INIT] Fixed SL=" + DoubleToString(Fixed_SL_Points, 0) + "pts | TP=" + DoubleToString(ATR_TP_Mult, 2) + "xATR");
   Print("[INIT] Breakeven: trigger=" + DoubleToString(BreakEven_TriggerPoints,0) + "pts | lock=" + DoubleToString(BreakEven_LockPoints,0) + "pts | enabled=" + (UseBreakEven ? "true" : "false"));
   Print("[INIT] Trail start=" + IntegerToString(Trail_StartPoints) + "pts | Step=" + IntegerToString(Trail_StepPoints) + "pts");
   Print("[INIT] Loss Recovery: enabled=" + (UseLossRecovery ? "true" : "false") +
         " | trigger=-$" + DoubleToString(LossRecovery_TriggerDollars,2) +
         " | mode=" + EnumToString(LossRecoveryMode) +
         " | recovery lot=" + DoubleToString(LossRecovery_Lot,2) +
         " | close basket at +$" + DoubleToString(LossRecovery_CloseInProfit,2));
   if(UseLossRecovery)
      Print("[INIT] NOTE: HEDGE mode requires a Hedging-type MT5 account. On a Netting account, opposite-direction orders on the same symbol net together instead of creating a second ticket.");
   
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
      if(UseLossRecovery)
      {
         ManageLossRecovery();
         ManageRecoveryBaskets();
      }
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
      }
   }
   
   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition() && CandleDirection != "SKIP")
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
            Print("[MEAN REVERSAL] SELL | M1 RSI=", DoubleToString(m1RsiVal, 1),
                  " | M5 RSI=", DoubleToString(m5RsiVal, 1),
                  " | M1 body=", DoubleToString(m1AbsBody, 1), "pts");
            ExecuteSell();
            return;
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
            Print("[MEAN REVERSAL] BUY | M1 RSI=", DoubleToString(m1RsiVal, 1),
                  " | M5 RSI=", DoubleToString(m5RsiVal, 1),
                  " | M1 body=", DoubleToString(m1AbsBody, 1), "pts");
            ExecuteBuy();
            return;
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
void GetSLTP(double &sl_dist, double &tp_dist)
{
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
// *** FIXED LOT CHANGE ***
// This function used to calculate lot size dynamically based on either
// risk-percent-of-balance sizing (UseRiskSizing = true) or a static
// LotSize input (UseRiskSizing = false). Both of those code paths have
// been removed for this EA version.
//
// CalcLot() is called from BOTH ExecuteBuy() and ExecuteSell() (see below),
// so returning a single constant value here guarantees that every BUY and
// every SELL trade opened by this EA uses the exact same fixed lot size -
// there is no direction-based (BUY vs SELL), balance-based, or
// SL-distance-based variation anymore.
//
// The sl_dist parameter is intentionally left in the function signature
// (unused) so the rest of the code — which calls CalcLot(sl_dist) from
// ExecuteBuy()/ExecuteSell() — does not need to be modified elsewhere.
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
   // Always trade a fixed 0.27 lots, regardless of BUY/SELL direction,
   // account balance, risk percent, or stop-loss distance.
   double lot = Fixed_Entry_Lot;

   // Still respect the broker's minimum/maximum volume bounds so the
   // fixed lot never gets rejected by the trade server.
   if(lot < MinLot) lot = MinLot;
   if(lot > MaxLot) lot = MaxLot;

   return lot;
}

//+------------------------------------------------------------------+
void ExecuteBuy()
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = CalcLot(sl_dist);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - sl_dist, _Digits);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, "M5v4 BUY"))
      Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] BUY ", lot, " lots | SL:", sl, " TP:", tp);
   }
}

//+------------------------------------------------------------------+
void ExecuteSell()
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = CalcLot(sl_dist);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + sl_dist, _Digits);
   double tp = NormalizeDouble(bid - tp_dist, _Digits);

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, "M5v4 SELL"))
      Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] SELL ", lot, " lots | SL:", sl, " TP:", tp);
   }
}

//+------------------------------------------------------------------+
void CheckProfitTarget()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RECOVERY_") == 0) continue; // recovery legs are managed by ManageRecoveryBaskets() instead
      
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
      if(StringFind(PositionGetString(POSITION_COMMENT), "RECOVERY_") == 0) continue; // recovery legs are managed by ManageRecoveryBaskets() instead
      
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
   double beLockDist = BreakEven_LockPoints * _Point;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RECOVERY_") == 0) continue; // recovery legs are managed by ManageRecoveryBaskets() instead
      
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

         // --- Stage 1: breakeven candidate ---
         if(UseBreakEven && profitPts >= BreakEven_TriggerPoints)
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
            Print("[", stage, "] BUY SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts");
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set
         bool haveCandidate = false;

         // --- Stage 1: breakeven candidate ---
         if(UseBreakEven && profitPts >= BreakEven_TriggerPoints)
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
            Print("[", stage, "] SELL SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts");
         }
      }
   }
}

//+------------------------------------------------------------------+
// *** LOSS RECOVERY SUBSYSTEM ***
// Everything below is new and entirely additive - it never touches
// entries, and the three functions above (CheckProfitTarget,
// HandleCandleEndClose, ManageTrailing) already skip any position whose
// comment starts with "RECOVERY_", so this subsystem is the only thing
// that manages recovery legs.
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// Lightweight trend-alignment check reusing the EA's existing MTF signals
// (same EMAs/MAs as DecideDirection()) - NOT a full re-entry evaluation,
// just "how many of the 3 timeframes still agree with 'direction' right
// now". Returns 0-3.
//+------------------------------------------------------------------+
int GetTrendAlignmentScore(string direction)
{
   double emaF5[], emaS5[], emaF15[], emaS15[], ma20[], ma50[];
   ArraySetAsSeries(emaF5, true);  ArraySetAsSeries(emaS5, true);
   ArraySetAsSeries(emaF15, true); ArraySetAsSeries(emaS15, true);
   ArraySetAsSeries(ma20, true);   ArraySetAsSeries(ma50, true);

   CopyBuffer(hEMA_Fast_M5, 0, 0, 1, emaF5);
   CopyBuffer(hEMA_Slow_M5, 0, 0, 1, emaS5);
   CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15);
   CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15);
   CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
   CopyBuffer(hMA50_H1, 0, 0, 1, ma50);

   bool m5_bull  = emaF5[0]  > emaS5[0];
   bool m15_bull = emaF15[0] > emaS15[0];
   bool h1_bull  = ma20[0]   > ma50[0];

   int score = 0;
   if(direction == "BUY")
   {
      if(m5_bull)  score++;
      if(m15_bull) score++;
      if(h1_bull)  score++;
   }
   else // SELL
   {
      if(!m5_bull)  score++;
      if(!m15_bull) score++;
      if(!h1_bull)  score++;
   }
   return score;
}

//+------------------------------------------------------------------+
// AUTO mode's decision rule. This is a heuristic, not a guarantee -
// no rule can predict where price goes next.
//   3/3 timeframes still agree with the original direction -> thesis
//       looks intact, so AVERAGE (add at a better price).
//   0/3 timeframes agree -> trend has fully flipped against the trade,
//       so CLOSE (cut the loss rather than fight the trend).
//   1-2/3 -> mixed/uncertain -> HEDGE (protect without fully giving up
//       the level, but don't add more risk into an unclear trend either).
//+------------------------------------------------------------------+
ENUM_RECOVERY_MODE DecideRecoveryMode(string originalDirection)
{
   int score = GetTrendAlignmentScore(originalDirection);
   if(score == 3) return RECOVERY_AVERAGE;
   if(score == 0) return RECOVERY_CLOSE;
   return RECOVERY_HEDGE;
}

//+------------------------------------------------------------------+
// Finds the most recently opened position for this symbol/magic - used
// right after opening a recovery order to get its ticket, since a fresh
// trade.Buy()/trade.Sell() call doesn't return the position ticket
// directly (only the order ticket).
//+------------------------------------------------------------------+
ulong FindLatestPositionTicket()
{
   ulong best = 0;
   long bestTime = -1;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      long t = (long)PositionGetInteger(POSITION_TIME);
      if(t > bestTime)
      {
         bestTime = t;
         best = PositionGetInteger(POSITION_TICKET);
      }
   }
   return best;
}

//+------------------------------------------------------------------+
// Opens the HEDGE or AVERAGE recovery order. Direction is opposite the
// original for HEDGE, same as the original for AVERAGE. Uses the same
// Fixed_SL_Points safety backstop as normal entries (so a recovery leg is
// never left completely unprotected) but NO fixed TP - its exit is
// entirely managed by ManageRecoveryBaskets() against the combined basket
// profit target instead.
// Returns the new position ticket, or 0 on failure.
//+------------------------------------------------------------------+
ulong OpenRecoveryOrder(string modeStr, string originalDirection)
{
   string dir = (modeStr == "HEDGE") ? (originalDirection == "BUY" ? "SELL" : "BUY") : originalDirection;
   string comment = "RECOVERY_" + modeStr + "_" + dir;
   double sl_dist = Fixed_SL_Points * _Point;
   bool ok;

   if(dir == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = NormalizeDouble(ask - sl_dist, _Digits);
      ok = trade.Buy(LossRecovery_Lot, _Symbol, ask, sl, 0, comment);
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = NormalizeDouble(bid + sl_dist, _Digits);
      ok = trade.Sell(LossRecovery_Lot, _Symbol, bid, sl, 0, comment);
   }

   if(!ok)
   {
      Print("[RECOVERY] Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return 0;
   }

   ulong newTicket = FindLatestPositionTicket();
   Print("[RECOVERY] Opened ", comment, " | ", DoubleToString(LossRecovery_Lot,2), " lots | ticket ", newTicket);
   return newTicket;
}

//+------------------------------------------------------------------+
bool IsRecoveryHandled(ulong ticket)
{
   for(int i = 0; i < ArraySize(RecoveryHandledTickets); i++)
      if(RecoveryHandledTickets[i] == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
void MarkRecoveryHandled(ulong ticket)
{
   int n = ArraySize(RecoveryHandledTickets);
   ArrayResize(RecoveryHandledTickets, n + 1);
   RecoveryHandledTickets[n] = ticket;
}

//+------------------------------------------------------------------+
void AddRecoveryBasket(ulong origTicket, ulong recTicket)
{
   int n = ArraySize(RecoveryBaskets);
   ArrayResize(RecoveryBaskets, n + 1);
   RecoveryBaskets[n].originalTicket = origTicket;
   RecoveryBaskets[n].recoveryTicket = recTicket;
   RecoveryBaskets[n].active = true;
}

//+------------------------------------------------------------------+
// Watches every ORIGINAL strategy position (never a recovery leg itself -
// those are identified and skipped by their "RECOVERY_" comment prefix).
// Once a position's floating loss reaches LossRecovery_TriggerDollars, this
// makes exactly ONE decision for it and marks it handled permanently - it
// will never re-trigger on that ticket again, even if the loss keeps
// growing afterward. That one-shot rule is what keeps this from turning
// into an open-ended martingale ladder.
//+------------------------------------------------------------------+
void ManageLossRecovery()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RECOVERY_") == 0) continue; // never re-trigger off a recovery leg

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(IsRecoveryHandled(ticket)) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > -LossRecovery_TriggerDollars) continue; // not in enough loss yet

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string origDir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      ENUM_RECOVERY_MODE mode = LossRecoveryMode;
      if(mode == RECOVERY_AUTO) mode = DecideRecoveryMode(origDir);

      MarkRecoveryHandled(ticket); // one-shot, regardless of what happens next

      if(mode == RECOVERY_CLOSE)
      {
         Print("[RECOVERY] CLOSE | cutting loss at $", DoubleToString(profit,2), " on ticket ", ticket);
         trade.PositionClose(ticket);
         TodayLosses++;
         continue;
      }

      string modeStr = (mode == RECOVERY_HEDGE) ? "HEDGE" : "AVERAGE";
      Print("[RECOVERY] ", modeStr, " triggered | original loss=$", DoubleToString(profit,2),
            " on ticket ", ticket, " | opening ", DoubleToString(LossRecovery_Lot,2), " lot recovery order");

      ulong recTicket = OpenRecoveryOrder(modeStr, origDir);
      if(recTicket != 0)
         AddRecoveryBasket(ticket, recTicket);
      else
         Print("[RECOVERY] Failed to open recovery order for ticket ", ticket, " - original trade left under normal SL/trail management only.");
   }
}

//+------------------------------------------------------------------+
// Watches every active basket's COMBINED floating profit (original leg +
// recovery leg) and closes BOTH together once it reaches
// LossRecovery_CloseInProfit ("close the trade in positive"). Also
// contains a safety cleanup: if one leg of a basket was already closed
// independently by something else (e.g. its own SL was hit), the other
// leg is now orphaned from its intended pairing and is closed too rather
// than left to run unmanaged.
//+------------------------------------------------------------------+
void ManageRecoveryBaskets()
{
   for(int i = ArraySize(RecoveryBaskets) - 1; i >= 0; i--)
   {
      if(!RecoveryBaskets[i].active) continue;

      bool origExists = PositionSelectByTicket(RecoveryBaskets[i].originalTicket);
      double origProfit = origExists ? PositionGetDouble(POSITION_PROFIT) : 0;

      bool recExists = PositionSelectByTicket(RecoveryBaskets[i].recoveryTicket);
      double recProfit = recExists ? PositionGetDouble(POSITION_PROFIT) : 0;

      if(!origExists && !recExists)
      {
         RecoveryBaskets[i].active = false; // both already gone
         continue;
      }

      double basketProfit = origProfit + recProfit;

      if(basketProfit >= LossRecovery_CloseInProfit)
      {
         Print("[RECOVERY] Basket target reached (+$", DoubleToString(basketProfit,2), "). Closing both legs.");
         if(origExists) trade.PositionClose(RecoveryBaskets[i].originalTicket);
         if(recExists)  trade.PositionClose(RecoveryBaskets[i].recoveryTicket);
         RecoveryBaskets[i].active = false;
         TodayWins++;
         continue;
      }

      if(origExists != recExists)
      {
         Print("[RECOVERY] One leg of the basket closed independently - closing the other leg too rather than leaving it unmanaged.");
         if(origExists) trade.PositionClose(RecoveryBaskets[i].originalTicket);
         if(recExists)  trade.PositionClose(RecoveryBaskets[i].recoveryTicket);
         RecoveryBaskets[i].active = false;
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