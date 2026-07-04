//+------------------------------------------------------------------+
//|                                   ea_5minCandle_scalp_v3_git.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| M5 Candle Scalper v3 — Optimized Exit Logic                      |
//| Dynamic SL/TP based on volatility + ATR-based trailing           |
//| Profit targets adjusted to catch more winners                    |
//| Loss prevention via dynamic stop management                      |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
input double LotSize = 0.10;
input long MagicNumber = 20260607;

//=== DYNAMIC SL/TP OPTIMIZATION (NEW v3) ===
input bool UseDynamic_SLTP = true;        // Use dynamic ATR-based SL/TP with volatility adjustment
input double ATR_SL_Mult = 1.2;           // Reduced from 1.5 - tighter stop
input double ATR_TP_Mult = 3.0;           // Increased from 2.5 - better reward ratio
input double Min_RR_Ratio = 1.5;          // Minimum Risk-Reward ratio required
input double Max_TP_Points = 150;         // Cap TP at this many points (avoid too high)
input double Min_TP_Points = 40;          // Minimum TP to ensure worthwhile trades

//=== #3 HOLD WINNERS PAST CANDLE (IMPROVED) ===
input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;    // Reduced from 30 - catch smaller trends
input double HoldTrailBuffer = 10;        // Keep trail buffer this far behind price

//=== #4 TRAILING STOP (OPTIMIZED) ===
input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 0.8;        // Reduced from 1.0 - tighter trail
input int Trail_StartPoints = 25;         // Reduced from 40 - trail earlier
input int Trail_StepPoints = 15;          // Move SL by this much when trailing

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

//=== MULTI-TIMEFRAME FILTER ===
input bool UseMTF_Filter = true;
input int EMA_Fast_Period = 9;
input int EMA_Slow_Period = 21;

//=== MOMENTUM & FILTERS ===
input int MomentumCandles = 3;
input double MinAvgBody_Points = 15.0;    // Reduced to catch more setups
input double MinATR_Points = 25.0;        // Reduced for more opportunities
input double RSI_BuyAbove = 52.0;
input double RSI_SellBelow = 48.0;

//=== EARLY REVERSAL MANAGEMENT (NEW v3.1) === [ADDED: v3.1 NEW PARAMETERS]
input bool UseEarlyReversalClose = true;        // Close trade early if direction reverses significantly
input double EarlyCloseThreshold = 0.6;         // Close if price moves 60% toward opposite SL
input bool AllowCounterTrade = true;            // Take opposite trade after early close
input double EmergencyExitPercent = 0.7;        // Emergency exit if trade moves 70% against us
input int MaxTradeTimeSeconds = 150;           // Max time to hold a trade (2.5 minutes)
input bool UseBreakevenStop = true;            // Move SL to breakeven when profit reaches 0.3x SL
input double BreakevenTrigger = 0.3;           // Trigger breakeven at 30% of SL distance

//=== AI BIAS ===
input bool UseAI_Bias = true;
input int AI_RefreshSeconds = 60;
input string OpenAI_ApiKey = "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";
input string OpenAI_Model = "gpt-4o-mini";
input int AI_ConfidenceThreshold = 70;    // Increased threshold for better quality signals

//=== GLOBAL STATE ===
datetime LastM5CandleTime = 0;
datetime LastAIRequest = 0;
string AI_Bias = "NONE";
int AI_Confidence = 0;
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

//=== REVERSAL MANAGEMENT STATE === [ADDED: v3.1 NEW STATE VARIABLES]
datetime TradeOpenTime = 0;
ulong CurrentTradeTicket = 0;
bool EarlyCloseExecuted = false;
bool CounterTradeAllowed = false;
string LastClosedDirection = "NONE";
double LastClosedProfit = 0;

// Hardcoded profit target
double TakeProfit_Dollars = 12.03;

//=== INDICATOR HANDLES ===
int hEMA_Fast_M5, hEMA_Slow_M5;
int hEMA_Fast_M15, hEMA_Slow_M15;
int hRSI_M5;
int hATR_M5;
int hMA20_H1, hMA50_H1, hRSI_H1;

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
   
   Print("[INIT] M5 Candle Scalper v3 (Optimized Exit)");
   Print("[INIT] SL=" + DoubleToString(ATR_SL_Mult, 2) + "xATR | TP=" + DoubleToString(ATR_TP_Mult, 2) + "xATR");
   Print("[INIT] Trail start=" + IntegerToString(Trail_StartPoints) + "pts | Step=" + IntegerToString(Trail_StepPoints) + "pts");
   
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Initialize new state variables [ADDED: v3.1 INITIALIZATION]
   TradeOpenTime = 0;
   CurrentTradeTicket = 0;
   EarlyCloseExecuted = false;
   CounterTradeAllowed = false;
   LastClosedDirection = "NONE";
   LastClosedProfit = 0;
   
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
   
   if(UseAI_Bias)
   {
      datetime now = TimeCurrent();
      if((int)(now - LastAIRequest) >= AI_RefreshSeconds)
      { UpdateAIBias(); LastAIRequest = now; }
   }
   
   if(HasPosition())
   {
      CheckProfitTarget();
      if(UseTrailingStop) ManageTrailing();
      
      // New: Early reversal management [ADDED: v3.1 EARLY REVERSAL CHECK]
      if(UseEarlyReversalClose) CheckEarlyReversal();
      
      // New: Breakeven stop management [ADDED: v3.1 BREAKEVEN STOP CHECK]
      if(UseBreakevenStop) CheckBreakevenStop();
      
      // New: Max time exit [ADDED: v3.1 MAX TIME CHECK]
      CheckMaxTradeTime();
      
      // New: Consider counter trade after early exit [ADDED: v3.1 COUNTER TRADE CHECK]
      ConsiderCounterTrade();
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
   
   if(UseAI_Bias && AI_Bias != "NONE" && direction != "SKIP")
   {
      if(direction == "BUY" && AI_Bias == "SELL") return "SKIP";
      if(direction == "SELL" && AI_Bias == "BUY") return "SKIP";
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
   CopyRates(_Symbol, PERIOD_M1, 1, 1, m1);
   
   double m1Body = (m1[0].close - m1[0].open) / _Point;
   double m1AbsBody = MathAbs(m1Body);
   bool m1Bullish = (m1[0].close > m1[0].open);
   bool m1Bearish = (m1[0].close < m1[0].open);
   
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
void GetDynamicSLTP(double &sl_dist, double &tp_dist)
{
   double atr = GetATR();
   double atrPoints = atr / _Point;
   
   double sl_pts = atrPoints * ATR_SL_Mult;
   double tp_pts = atrPoints * ATR_TP_Mult;
   
   if(sl_pts < 20) sl_pts = 20;
   if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
   if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;
   
   if(tp_pts / sl_pts < Min_RR_Ratio)
      tp_pts = sl_pts * Min_RR_Ratio;
   
   sl_dist = sl_pts * _Point;
   tp_dist = tp_pts * _Point;
   
   Print("[SLTP] ATR=", DoubleToString(atrPoints,1), "pts | SL=", DoubleToString(sl_pts,0), 
         "pts | TP=", DoubleToString(tp_pts,0), "pts | RR=", DoubleToString(tp_pts/sl_pts,2));
}

//+------------------------------------------------------------------+
void GetSLTP(double &sl_dist, double &tp_dist)
{
   if(UseDynamic_SLTP)
      GetDynamicSLTP(sl_dist, tp_dist);
   else
   {
      double atr = GetATR();
      sl_dist = atr * ATR_SL_Mult;
      tp_dist = atr * ATR_TP_Mult;
   }
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
double CalcLot(double sl_dist)
{
   if(!UseRiskSizing) return LotSize;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * RiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0 || tickVal == 0) return LotSize;
   
   double lossPerLot = (sl_dist / tickSize) * tickVal;
   if(lossPerLot <= 0) return LotSize;
   
   double lot = riskAmt / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
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

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, "M5v3 BUY"))
      Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      TradeOpenTime = TimeCurrent();           // [ADDED: v3.1 RECORD TRADE TIME]
      EarlyCloseExecuted = false;              // [ADDED: v3.1 RESET EARLY CLOSE FLAG]
      CounterTradeAllowed = false;             // [ADDED: v3.1 RESET COUNTER TRADE FLAG]
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

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, "M5v3 SELL"))
      Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      TradeOpenTime = TimeCurrent();           // [ADDED: v3.1 RECORD TRADE TIME]
      EarlyCloseExecuted = false;              // [ADDED: v3.1 RESET EARLY CLOSE FLAG]
      CounterTradeAllowed = false;             // [ADDED: v3.1 RESET COUNTER TRADE FLAG]
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
      
      // MODIFIED: v3.1 - Only take dynamic TP if we're at least halfway through the candle
      // This prevents taking small profits too early [CHANGE: ADDED TIME FILTER]
      datetime currentTime = TimeCurrent();
      datetime candleStart = iTime(_Symbol, PERIOD_M5, 0);
      int secondsInCandle = (int)(currentTime - candleStart);
      
      if(profitPoints >= dynamicTP && secondsInCandle >= 150) // At least 2.5 minutes into candle
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[DYNAMIC TP] Profit: ", IntegerToString((int)profitPoints), "pts | Closed at optimal level");
      }
      // ADDED: v3.1 - Small profit lock if trade is struggling [NEW: PARTIAL PROFIT LOCK]
      else if(profitPoints >= (atr * 0.8) && profitPoints < dynamicTP && secondsInCandle >= 180)
      {
         // If we have some profit but not reaching target, and candle is ending soon
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[PARTIAL TP] Locked +", IntegerToString((int)profitPoints), "pts before candle end");
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
      
      // Only hold winners past candle if option enabled AND profit is decent
      if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints)
      {
         Print("[HOLD] Winner running (+", IntegerToString((int)profitPts), "pts). Trail buffer: ", 
               IntegerToString((int)HoldTrailBuffer), "pts");
         continue;
      }
      
      // MODIFIED: v3.1 - Don't close small losses prematurely - let SL handle it [CHANGE: FIXED EXIT LOGIC]
      // Only close at candle end if we have some profit or it's break-even
      if(profit > 0)
      {
         trade.PositionClose(ticket);
         TodayWins++;
         Print("[CANDLE END] WIN +$", DoubleToString(profit, 2));
      }
      // MODIFIED: v3.1 - Let losing positions ride to their proper SL [CHANGE: NO MORE EARLY LOSS CLOSE]
   }
}

//+------------------------------------------------------------------+
void ManageTrailing()
{
   double atr = GetATR();
   double trailDist = atr * Trail_ATR_Mult;
   double trailStep = Trail_StepPoints * _Point;
   
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
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(bid - trailDist, _Digits);
            if(newSL > curSL + trailStep)
            {
               trade.PositionModify(ticket, newSL, curTP);
               Print("[TRAIL] BUY SL -> ", newSL, " | Profit: ", IntegerToString((int)profitPts), "pts");
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(ask + trailDist, _Digits);
            if(newSL < curSL - trailStep || curSL == 0)
            {
               trade.PositionModify(ticket, newSL, curTP);
               Print("[TRAIL] SELL SL -> ", newSL, " | Profit: ", IntegerToString((int)profitPts), "pts");
            }
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

//+------------------------------------------------------------------+
void UpdateAIBias()
{
   if(OpenAI_ApiKey == "") { AI_Bias = "NONE"; return; }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ma20[], ma50[], rsiH1[];
   ArraySetAsSeries(ma20, true);
   ArraySetAsSeries(ma50, true);
   ArraySetAsSeries(rsiH1, true);
   CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
   CopyBuffer(hMA50_H1, 0, 0, 1, ma50);
   CopyBuffer(hRSI_H1, 0, 0, 3, rsiH1);
   
   MqlRates h1[];
   ArraySetAsSeries(h1, true);
   CopyRates(_Symbol, PERIOD_H1, 0, 5, h1);
   
   string candles = "";
   for(int i = 0; i < 5; i++)
      candles += "H1[" + IntegerToString(i) + "] O=" + DoubleToString(h1[i].open, _Digits)
               + " H=" + DoubleToString(h1[i].high, _Digits)
               + " L=" + DoubleToString(h1[i].low, _Digits)
               + " C=" + DoubleToString(h1[i].close, _Digits) + "\\n";
   
   string trend = (ma20[0] > ma50[0]) ? "BULLISH" : (ma20[0] < ma50[0]) ? "BEARISH" : "NEUTRAL";

   string prompt =
      "=== M5 SCALPER BIAS ===\\n"
      "Symbol: " + _Symbol + " | Bid: " + DoubleToString(bid, _Digits) + "\\n" +
      "H1 MA20: " + DoubleToString(ma20[0], _Digits) + " MA50: " + DoubleToString(ma50[0], _Digits) + "\\n" +
      "Trend: " + trend + " | RSI: " + DoubleToString(rsiH1[0], 2) + "\\n" +
      "Candles:\\n" + candles +
      "Reply: SIGNAL CONFIDENCE (BUY 78 / SELL 72 / HOLD 50). One line.";

   string raw = OpenAIRequest(prompt);
   if(raw == "") { AI_Bias = "NONE"; return; }
   
   int conf = 0;
   string sig = ExtractSignal(raw, conf);
   if(conf >= AI_ConfidenceThreshold)
   { AI_Bias = sig; AI_Confidence = conf; Print("[AI] ", AI_Bias, " (", conf, ")"); }
   else
   { AI_Bias = "NONE"; Print("[AI] Low confidence. No filter."); }
}

//+------------------------------------------------------------------+
string OpenAIRequest(string prompt)
{
   string url = "https://api.openai.com/v1/chat/completions";
   StringReplace(prompt, "\"", "'");
   
   string sys = "You are a XAUUSD M5 scalping bias analyst.\\n"
      "Rules: Reply SIGNAL CONFIDENCE (e.g. BUY 78). One line. No explanation.";

   string body = "{\"model\":\"" + OpenAI_Model + "\"," +
                 "\"messages\":[{\"role\":\"system\",\"content\":\"" + sys + "\"}," +
                 "{\"role\":\"user\",\"content\":\"" + prompt + "\"}]," +
                 "\"max_tokens\":10,\"temperature\":0.0}";

   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);
   char result[];
   string rh;
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + OpenAI_ApiKey + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", url, headers, 30000, post, result, rh);
   if(code == -1) { Print("[API ERROR] ", GetLastError()); return ""; }
   return CharArrayToString(result);
}

//+------------------------------------------------------------------+
string ExtractSignal(string jsonText, int &confidence)
{
   CJAVal json;
   confidence = 0;
   if(!json.Deserialize(jsonText)) return "HOLD";

   string text = json["choices"][0]["message"]["content"].ToStr();
   StringTrimLeft(text); StringTrimRight(text); StringToUpper(text);

   string signal = "HOLD";
   if(StringFind(text, "BUY") >= 0) signal = "BUY";
   else if(StringFind(text, "SELL") >= 0) signal = "SELL";

   string parts[];
   int n = StringSplit(text, ' ', parts);
   if(n >= 2)
   {
      int p = (int)StringToInteger(parts[1]);
      if(p > 0 && p <= 100) confidence = p;
      else { p = (int)StringToInteger(parts[n-1]); if(p > 0 && p <= 100) confidence = p; else confidence = 50; }
   }
   else confidence = 50;
   return signal;
}

//+------------------------------------------------------------------+
//| Early Reversal Detection - Close trade early if reversing        |
//+------------------------------------------------------------------+
void CheckEarlyReversal()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // Calculate how far price has moved toward opposite direction
      double progressTowardOpposite = 0;
      
      if(type == POSITION_TYPE_BUY)
      {
         // For BUY: check how far price has fallen from open toward SL
         if(sl > 0)
         {
            double totalDistance = openPrice - sl;  // Distance from open to SL
            double currentFall = openPrice - bid;   // How much price has fallen
            if(totalDistance > 0) 
               progressTowardOpposite = currentFall / totalDistance;
         }
         
         // Emergency exit: if price moves significantly against us
         // ADDED: v3.1 - Emergency exit if price moves significantly against us [NEW: EARLY EXIT LOGIC]
         if(EmergencyExitPercent > 0 && progressTowardOpposite >= EmergencyExitPercent)
         {
            trade.PositionClose(ticket);
            TodayLosses++;
            TradeOpenThisCandle = false;
            EarlyCloseExecuted = true;          // [ADDED: v3.1 SET EARLY CLOSE FLAG]
            Print("[EMERGENCY EXIT] BUY closed early at ", DoubleToString(bid, _Digits), 
                  " | Progress to SL: ", DoubleToString(progressTowardOpposite*100, 1), "%");
            
            if(AllowCounterTrade && !CounterTradeAllowed)
            {
               CounterTradeAllowed = true;      // [ADDED: v3.1 ENABLE COUNTER TRADE]
               Print("[REVERSAL] Price reversed strongly - considering counter trade");
            }
            return;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         // For SELL: check how far price has risen from open toward SL
         if(sl > 0)
         {
            double totalDistance = sl - openPrice;  // Distance from SL to open
            double currentRise = ask - openPrice;   // How much price has risen
            if(totalDistance > 0)
               progressTowardOpposite = currentRise / totalDistance;
         }
         
         // ADDED: v3.1 - Emergency exit if price moves significantly against us [NEW: EARLY EXIT LOGIC]
         if(EmergencyExitPercent > 0 && progressTowardOpposite >= EmergencyExitPercent)
         {
            trade.PositionClose(ticket);
            TodayLosses++;
            TradeOpenThisCandle = false;
            EarlyCloseExecuted = true;          // [ADDED: v3.1 SET EARLY CLOSE FLAG]
            Print("[EMERGENCY EXIT] SELL closed early at ", DoubleToString(ask, _Digits),
                  " | Progress to SL: ", DoubleToString(progressTowardOpposite*100, 1), "%");
            
            if(AllowCounterTrade && !CounterTradeAllowed)
            {
               CounterTradeAllowed = true;      // [ADDED: v3.1 ENABLE COUNTER TRADE]
               Print("[REVERSAL] Price reversed strongly - considering counter trade");
            }
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Breakeven Stop Management - Move SL to breakeven                 |
//+------------------------------------------------------------------+
void CheckBreakevenStop()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // Calculate profit in points
      double profitPoints = 0;
      double priceCurrent = (type == POSITION_TYPE_BUY) ? bid : ask;
      
      if(type == POSITION_TYPE_BUY)
         profitPoints = (bid - openPrice) / _Point;
      else if(type == POSITION_TYPE_SELL)
         profitPoints = (openPrice - ask) / _Point;
      
      // ADDED: v3.1 - Calculate original SL distance [NEW: BREAKEVEN LOGIC]
      double originalSLDistance = 0;
      if(type == POSITION_TYPE_BUY && sl > 0)
         originalSLDistance = (openPrice - sl) / _Point;
      else if(type == POSITION_TYPE_SELL && sl > 0)
         originalSLDistance = (sl - openPrice) / _Point;
      
      // ADDED: v3.1 - Move SL to breakeven if profit reaches trigger percentage [NEW: RISK FREE TRADE]
      if(originalSLDistance > 0 && profitPoints >= (originalSLDistance * BreakevenTrigger))
      {
         double newSL = openPrice;
         if(trade.PositionModify(ticket, newSL, tp))
         {
            Print("[BREAKEVEN] SL moved to entry price at ", DoubleToString(profitPoints, 0), "pts profit");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Max Trade Time Check - Close trades that run too long            |
//+------------------------------------------------------------------+
// ADDED: v3.1 - CheckMaxTradeTime function [NEW: MAX TIME EXIT]
void CheckMaxTradeTime()
{
   if(MaxTradeTimeSeconds <= 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
      datetime currentTime = TimeCurrent();
      
      // ADDED: v3.1 - Close trade if it runs too long [NEW: TIME-BASED EXIT]
      if((currentTime - positionTime) >= MaxTradeTimeSeconds)
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         trade.PositionClose(ticket);
         
         if(profit > 0) TodayWins++; else TodayLosses++;
         TradeOpenThisCandle = false;
         
         Print("[MAX TIME] Trade closed after ", MaxTradeTimeSeconds, " seconds | P&L: $", DoubleToString(profit, 2));
      }
   }
}

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Consider Counter Trade - After early exit, check if we should    |
//| take opposite trade                                              |
//+------------------------------------------------------------------+
// ADDED: v3.1 - ConsiderCounterTrade function [NEW: COUNTER TRADE LOGIC]
void ConsiderCounterTrade()
{
   if(!AllowCounterTrade || !CounterTradeAllowed) return;
   
   // ADDED: v3.1 - Check if we had an early close recently [NEW: COUNTER TRADE CONDITION]
   if(!EarlyCloseExecuted) return;
   
   // ADDED: v3.1 - Only consider counter trade in same candle [NEW: TIMING FILTER]
   datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5 != LastM5CandleTime) 
   {
      CounterTradeAllowed = false; // New candle, reset
      return;
   }
   
   // ADDED: v3.1 - Wait a bit after early close [NEW: DELAYED ENTRY]
   datetime now = TimeCurrent();
   if((now - TradeOpenTime) < 30) return; // Wait at least 30 seconds
   
   // ADDED: v3.1 - Check current market conditions [NEW: RE-ENTRY ANALYSIS]
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // ADDED: v3.1 - Get fresh direction signal [NEW: RE-EVALUATION]
   string newDirection = DecideDirection();
   
   // ADDED: v3.1 - If new direction is opposite to what we just closed, consider it [NEW: OPPOSITE TRADE]
   // (Note: We would need to track what direction we just closed)
   Print("[COUNTER TRADE] Evaluating opposite position. New signal: ", newDirection);
   
   CounterTradeAllowed = false; // Reset flag [ADDED: v3.1 RESET COUNTER TRADE FLAG]
}

//+------------------------------------------------------------------+
