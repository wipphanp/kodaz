//+------------------------------------------------------------------+
//|                                          ea_5minCandle_scalp.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| M5 Candle Scalper v2 — "Confirm Then Enter"                      |
//| Waits for M1 confirmation within the M5 candle before entering   |
//| Uses M5 + M15 + H1 multi-timeframe alignment                    |
//| Exits at candle close or profit target                           |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
input double LotSize = 0.10;
input long MagicNumber = 20260607;

//=== #1 + #2 ATR-BASED SL/TP (fixes bad risk-reward) ===
input bool UseATR_SLTP = true;            // Use ATR-based SL/TP instead of fixed
input double ATR_SL_Mult = 1.5;           // SL = ATR(M5) * this
input double ATR_TP_Mult = 2.5;           // TP = ATR(M5) * this (bigger than SL)
input int Fallback_SL_Points = 150;       // Used if UseATR_SLTP = false
input double TakeProfit_Dollars = 12.03;  // Hard dollar TP (still active as a cap)

//=== #3 HOLD WINNERS PAST CANDLE ===
input bool HoldWinnersPastCandle = true;  // Don't force-close profitable trending trades
input double HoldMinProfitPoints = 30;    // Must be this far in profit to hold past candle

//=== #4 TRAILING STOP ===
input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 1.0;        // Trail distance = ATR * this
input int Trail_StartPoints = 40;         // Start trailing after this much profit

//=== #5 MTF SCORING (vs strict alignment) ===
input bool UseMTF_Scoring = true;         // Use score instead of requiring all TFs
input int MTF_MinScore = 2;               // Need at least this many TFs agreeing (of 3)

//=== #6 DAILY LIMITS + RISK SIZING ===
input bool UseRiskSizing = true;          // Scale lot by risk %
input double RiskPercent = 1.0;           // Risk % of balance per trade
input double MaxLot = 1.0;
input double MinLot = 0.01;
input bool UseDailyLimits = true;
input double DailyProfitTarget = 100.0;   // Stop after +$X
input double DailyLossLimit = 50.0;       // Stop after -$X

//=== CONFIRMATION ENTRY SETTINGS ===
input int ConfirmWaitBars = 1;            // Wait this many M1 bars for confirmation (1-2)
input double MinM1ConfirmBody = 10.0;     // Confirmation M1 candle must have this body size (pts)
input bool RequireM1BreakHigh = true;     // For BUY: M1 must break above M5 open price
input bool RequireM1BreakLow = true;      // For SELL: M1 must break below M5 open price

//=== MULTI-TIMEFRAME FILTER ===
input bool UseMTF_Filter = true;          // Require M5 + M15 + H1 agreement
input int EMA_Fast_Period = 9;            // Fast EMA (M5)
input int EMA_Slow_Period = 21;           // Slow EMA (M5)

//=== MOMENTUM & FILTERS ===
input int MomentumCandles = 3;            // Previous M5 candles to check
input double MinAvgBody_Points = 20.0;    // Skip if previous candles too small
input double MinATR_Points = 30.0;        // Skip if ATR too low (dead market)
input double RSI_BuyAbove = 50.0;
input double RSI_SellBelow = 50.0;

//=== AI BIAS (Optional) ===
input bool UseAI_Bias = true;
input int AI_RefreshSeconds = 60;
input string OpenAI_ApiKey = "";
input string OpenAI_Model = "gpt-4o-mini";
input int AI_ConfidenceThreshold = 65;

//=== GLOBAL STATE ===
datetime LastM5CandleTime = 0;
datetime LastAIRequest = 0;
string AI_Bias = "NONE";
int AI_Confidence = 0;
bool TradeOpenThisCandle = false;
bool DirectionDecided = false;            // Have we decided direction for this candle?
string CandleDirection = "NONE";          // Decided direction: BUY, SELL, SKIP
int M1BarsElapsed = 0;                    // How many M1 bars since M5 candle opened
datetime LastM1Time = 0;                  // Track M1 bar changes
int TodayTrades = 0;
int TodayWins = 0;
int TodayLosses = 0;
int LastTradeDay = -1;
double DailyStartBalance = 0;
bool DailyLimitHit = false;

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
   
   // M5 indicators
   hEMA_Fast_M5 = iMA(_Symbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5 = iMA(_Symbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   hATR_M5 = iATR(_Symbol, PERIOD_M5, 14);
   
   // M15 indicators (multi-timeframe)
   hEMA_Fast_M15 = iMA(_Symbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15 = iMA(_Symbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   // H1 indicators (AI + MTF)
   hMA20_H1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   
   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE)
   {
      Print("[ERROR] Indicator creation failed.");
      return(INIT_FAILED);
   }
   
   Print("[INIT] M5 Candle Scalper v2 (Confirm-Then-Enter)");
   Print("[INIT] Confirm wait=", ConfirmWaitBars, " M1 bars | MTF=", UseMTF_Filter, " | AI=", UseAI_Bias);
   
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(UseRiskSizing) Print("[INIT] Risk sizing ON: ", RiskPercent, "% per trade");
   if(UseDailyLimits) Print("[INIT] Daily limits: +$", DailyProfitTarget, " / -$", DailyLossLimit);
   
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
   // Daily reset
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
   
   // === #6 DAILY LIMITS (DISABLED - trades continue all day) ===
   // if(UseDailyLimits && CheckDailyLimits())
   //    return;
   
   // Update AI
   if(UseAI_Bias)
   {
      datetime now = TimeCurrent();
      if((int)(now - LastAIRequest) >= AI_RefreshSeconds)
      { UpdateAIBias(); LastAIRequest = now; }
   }
   
   // Check profit target on open position (every tick)
   if(HasPosition())
   {
      CheckProfitTarget();
      // === #4 TRAILING STOP ===
      if(UseTrailingStop) ManageTrailing();
   }
   
   // Detect new M5 candle
   datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5 != LastM5CandleTime)
   {
      // === CLOSE previous candle's trade (unless holding a winner) ===
      if(HasPosition())
         HandleCandleEndClose();
      
      // === RESET for new candle ===
      LastM5CandleTime = currentM5;
      TradeOpenThisCandle = HasPosition();  // If we held a winner, don't open another
      DirectionDecided = false;
      CandleDirection = "NONE";
      M1BarsElapsed = 0;
      LastM1Time = 0;
      
      // === DECIDE DIRECTION (but don't enter yet) ===
      if(!HasPosition())
      {
         CandleDirection = DecideDirection();
         DirectionDecided = true;
         if(CandleDirection != "SKIP")
            Print("[DIRECTION] ", CandleDirection, " decided. Waiting for M1 confirmation...");
      }
   }
   
   // === WAIT FOR M1 CONFIRMATION THEN ENTER ===
   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition() && CandleDirection != "SKIP")
   {
      CheckM1Confirmation();
   }
}

//+------------------------------------------------------------------+
// DECIDE DIRECTION AT M5 CANDLE OPEN (Step 1)
//+------------------------------------------------------------------+
string DecideDirection()
{
   // === ATR CHECK ===
   double atr[];
   ArraySetAsSeries(atr, true);
   CopyBuffer(hATR_M5, 0, 0, 1, atr);
   if(atr[0] / _Point < MinATR_Points)
      return "SKIP";
   
   // === M5 MOMENTUM (previous candles) ===
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
   
   // === M5 EMA DIRECTION ===
   double emaF5[], emaS5[];
   ArraySetAsSeries(emaF5, true);
   ArraySetAsSeries(emaS5, true);
   CopyBuffer(hEMA_Fast_M5, 0, 0, 2, emaF5);
   CopyBuffer(hEMA_Slow_M5, 0, 0, 2, emaS5);
   
   bool m5_bullish = (emaF5[0] > emaS5[0]);
   bool m5_bearish = (emaF5[0] < emaS5[0]);
   
   // === M5 RSI ===
   double rsi5[];
   ArraySetAsSeries(rsi5, true);
   CopyBuffer(hRSI_M5, 0, 0, 2, rsi5);
   
   // === MULTI-TIMEFRAME FILTER ===
   bool m15_bullish = true, m15_bearish = true;
   bool h1_bullish = true, h1_bearish = true;
   
   if(UseMTF_Filter)
   {
      // M15 EMA alignment
      double emaF15[], emaS15[];
      ArraySetAsSeries(emaF15, true);
      ArraySetAsSeries(emaS15, true);
      CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15);
      CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15);
      m15_bullish = (emaF15[0] > emaS15[0]);
      m15_bearish = (emaF15[0] < emaS15[0]);
      
      // H1 MA alignment
      double ma20[], ma50[];
      ArraySetAsSeries(ma20, true);
      ArraySetAsSeries(ma50, true);
      CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
      CopyBuffer(hMA50_H1, 0, 0, 1, ma50);
      h1_bullish = (ma20[0] > ma50[0]);
      h1_bearish = (ma20[0] < ma50[0]);
   }
   
   // === FINAL DIRECTION DECISION ===
   string direction = "SKIP";
   
   if(UseMTF_Scoring)
   {
      // === #5 MTF SCORING - count agreeing timeframes ===
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
      // Strict: all timeframes must agree
      if(bullish >= 2 && m5_bullish && rsi5[0] > RSI_BuyAbove && m15_bullish && h1_bullish)
         direction = "BUY";
      else if(bearish >= 2 && m5_bearish && rsi5[0] < RSI_SellBelow && m15_bearish && h1_bearish)
         direction = "SELL";
   }
   
   // === AI FILTER ===
   if(UseAI_Bias && AI_Bias != "NONE" && direction != "SKIP")
   {
      if(direction == "BUY" && AI_Bias == "SELL") return "SKIP";
      if(direction == "SELL" && AI_Bias == "BUY") return "SKIP";
   }
   
   return direction;
}

//+------------------------------------------------------------------+
// WAIT FOR M1 CONFIRMATION BEFORE ENTRY (Step 2)
//+------------------------------------------------------------------+
void CheckM1Confirmation()
{
   // Track M1 bars elapsed since M5 candle opened
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 != LastM1Time)
   {
      LastM1Time = currentM1;
      M1BarsElapsed++;
   }
   
   // Wait for at least ConfirmWaitBars M1 candles to complete
   if(M1BarsElapsed < ConfirmWaitBars)
      return;
   
   // Too late in the candle (already 3+ M1 bars = only 2 min left) - skip
   if(M1BarsElapsed > 3)
   {
      CandleDirection = "SKIP";
      Print("[SKIP] Too late in candle for confirmation. M1 bars elapsed: ", M1BarsElapsed);
      return;
   }
   
   // === CHECK THE LAST COMPLETED M1 CANDLE ===
   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   CopyRates(_Symbol, PERIOD_M1, 1, 1, m1);  // Last completed M1 bar
   
   double m1Body = (m1[0].close - m1[0].open) / _Point;
   double m1AbsBody = MathAbs(m1Body);
   bool m1Bullish = (m1[0].close > m1[0].open);
   bool m1Bearish = (m1[0].close < m1[0].open);
   
   // M1 candle must have minimum body size
   if(m1AbsBody < MinM1ConfirmBody)
      return;  // Wait for next M1 bar (might still confirm)
   
   // Get M5 candle open price for break check
   double m5Open = iOpen(_Symbol, PERIOD_M5, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // === CONFIRM BUY ===
   if(CandleDirection == "BUY")
   {
      // M1 must be bullish
      if(!m1Bullish) return;
      
      // Price must have broken above M5 open (confirms upward momentum)
      if(RequireM1BreakHigh && currentBid <= m5Open) return;
      
      // All confirmed - ENTER BUY
      Print("[CONFIRMED] BUY after ", M1BarsElapsed, " M1 bars. M1 body=", DoubleToString(m1AbsBody, 0),
            "pts. Price broke above M5 open (", DoubleToString(m5Open, _Digits), ")");
      ExecuteBuy();
   }
   
   // === CONFIRM SELL ===
   if(CandleDirection == "SELL")
   {
      // M1 must be bearish
      if(!m1Bearish) return;
      
      // Price must have broken below M5 open (confirms downward momentum)
      if(RequireM1BreakLow && currentAsk >= m5Open) return;
      
      // All confirmed - ENTER SELL
      Print("[CONFIRMED] SELL after ", M1BarsElapsed, " M1 bars. M1 body=", DoubleToString(m1AbsBody, 0),
            "pts. Price broke below M5 open (", DoubleToString(m5Open, _Digits), ")");
      ExecuteSell();
   }
}

//+------------------------------------------------------------------+
// ATR & SIZING HELPERS
//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 100 * _Point;
   return atr[0];
}

//--------------------------------------------------
void GetSLTP(double &sl_dist, double &tp_dist)
{
   if(UseATR_SLTP)
   {
      double atr = GetATR();
      sl_dist = atr * ATR_SL_Mult;
      tp_dist = atr * ATR_TP_Mult;
      if(tp_dist < sl_dist * 1.3) tp_dist = sl_dist * 1.3;
   }
   else
   {
      sl_dist = Fallback_SL_Points * _Point;
      tp_dist = sl_dist * 1.5;
   }
}

//--------------------------------------------------
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
// TRADE EXECUTION
//+------------------------------------------------------------------+
void ExecuteBuy()
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = CalcLot(sl_dist);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - sl_dist, _Digits);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, "M5v2 BUY"))
   {
      Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] BUY ", lot, " lots @ ", ask, " SL:", sl, " TP:", tp);
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

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, "M5v2 SELL"))
   {
      Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] SELL ", lot, " lots @ ", bid, " SL:", sl, " TP:", tp);
   }
}

//+------------------------------------------------------------------+
// EXIT LOGIC
//+------------------------------------------------------------------+
void CheckProfitTarget()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit >= TakeProfit_Dollars)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[TP HIT] +$", DoubleToString(profit, 2));
      }
   }
}

//+------------------------------------------------------------------+
// #3 CANDLE END - HOLD WINNERS, CLOSE LOSERS/FLAT
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
      
      // === HOLD WINNERS: keep profitable trending trades open ===
      if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints)
      {
         Print("[HOLD] Winner running (+", DoubleToString(profitPts,0), "pts). Keeping open past candle. Trail will manage exit.");
         continue;  // Don't close - let trailing stop handle it
      }
      
      // Otherwise close at candle end
      trade.PositionClose(ticket);
      if(profit > 0) TodayWins++;
      else TodayLosses++;
      Print("[CANDLE END] ", (profit>0 ? "WIN +$" : "LOSS $"), DoubleToString(profit, 2));
   }
}

//+------------------------------------------------------------------+
// #4 TRAILING STOP
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double atr = GetATR();
   double trailDist = atr * Trail_ATR_Mult;
   
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
            if(newSL > curSL)
            {
               trade.PositionModify(ticket, newSL, curTP);
               Print("[TRAIL] BUY SL -> ", newSL);
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(ask + trailDist, _Digits);
            if(newSL < curSL || curSL == 0)
            {
               trade.PositionModify(ticket, newSL, curTP);
               Print("[TRAIL] SELL SL -> ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
// #6 DAILY LIMITS
//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - DailyStartBalance;
   
   if(dailyPL >= DailyProfitTarget)
   {
      if(!DailyLimitHit)
      {
         Print("[DAILY LIMIT] Profit target +$", DoubleToString(dailyPL,2), " reached. Stopping.");
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   if(dailyPL <= -DailyLossLimit)
   {
      if(!DailyLimitHit)
      {
         Print("[DAILY LIMIT] Loss limit -$", DoubleToString(MathAbs(dailyPL),2), " reached. Stopping.");
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
// POSITION HELPER
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
// AI BIAS
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
   { AI_Bias = "NONE"; Print("[AI] Low confidence (", conf, "). No filter."); }
}

//+------------------------------------------------------------------+
// OPENAI API
//+------------------------------------------------------------------+
string OpenAIRequest(string prompt)
{
   string url = "https://api.openai.com/v1/chat/completions";
   StringReplace(prompt, "\"", "'");
   
   string sys = "You are a XAUUSD M5 scalping bias analyst.\\n"
      "Rules: Reply SIGNAL CONFIDENCE (e.g. BUY 78). One line. No explanation.";

   string body = "{\"model\":\"" + OpenAI_Model + "\","
                 "\"messages\":[{\"role\":\"system\",\"content\":\"" + sys + "\"},"
                 "{\"role\":\"user\",\"content\":\"" + prompt + "\"}],"
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
