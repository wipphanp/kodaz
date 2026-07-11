//+------------------------------------------------------------------+
//| ea_5minCandle_scalp_v5_RSIEnhanced_modular.mq5                   |
//| Modular RSI-enhanced EA derived from the user's original v4 EA   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "5.10"

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

input double LotSize = 0.10;
input long MagicNumber = 20260607;

input double ATR_TP_Mult = 3.0;
input double Max_TP_Points = 150;
input double Min_TP_Points = 40;

input int SwingLookbackBars = 20;
input int SwingBufferPoints = 60;
input int SL_MinPoints = 120;
input int SL_MaxPoints = 360;
input double SL_ATR_Mult = 0.8;

input int MaxEntrySecondsInM5 = 180;

input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;

input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 0.8;
input int Trail_StartPoints = 25;
input int Trail_StepPoints = 15;

input bool UseMTF_Scoring = true;
input int MTF_MinScore = 2;

input bool UseRiskSizing = true;
input double RiskPercent = 0.5;
input double MaxLot = 1.0;
input double MinLot = 0.01;

input bool UseDailyLimits = false;
input double DailyProfitTarget = 100.0;
input double DailyLossLimit = 50.0;

input int ConfirmWaitBars = 1;
input double MinM1ConfirmBody = 8.0;
input bool RequireM1BreakHigh = true;
input bool RequireM1BreakLow = true;

input bool UseMTF_Filter = true;
input int EMA_Fast_Period = 9;
input int EMA_Slow_Period = 21;

input int MomentumCandles = 3;
input double MinAvgBody_Points = 10.0;
input double MinATR_Points = 15.0;
input double RSI_BuyAbove = 51.0;
input double RSI_SellBelow = 47.0;

input bool UseRSISlopeFilter = true;
input bool UseDynamicRSIThresholds = true;
input double RSI_HighVol_BuyAbove = 55.0;
input double RSI_HighVol_SellBelow = 45.0;
input double RSI_LowVol_BuyAbove = 51.0;
input double RSI_LowVol_SellBelow = 47.0;
input double RSI_HighVol_ATR_Points = 35.0;
input bool UseH1RSIScore = true;
input double H1_RSI_Bull_Min = 52.0;
input double H1_RSI_Bear_Max = 48.0;
input bool UseRSIDivergenceBlock = true;
input int RSI_DivergenceLookback = 8;
input bool UseM1RSIConfirm = true;
input int RSI_M1_Period = 14;
input double M1_RSI_BuyMin = 52.0;
input double M1_RSI_SellMax = 48.0;
input bool UseRSIExtremeExit = true;
input double RSI_ExtremeOverbought = 72.0;
input double RSI_ExtremeOversold = 28.0;
input bool TightenTrailOnRSIExtreme = true;
input double ExtremeTrail_ATR_Mult = 0.45;
input int RSI_Short_Period = 7;
input bool UseDualRSIConfluence = true;
input double RSI_RecentCrossLevel = 50.0;
input int RSI_RecentCrossLookbackBars = 3;
input bool RequireRecentRSICenterCross = false;

input bool UseAI_Bias = true;
input int AI_RefreshSeconds = 60;
input string OpenAI_ApiKey = "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";
input string OpenAI_Model = "gpt-4o-mini";
input int AI_ConfidenceThreshold = 70;

int hEMA_Fast_M5 = INVALID_HANDLE;
int hEMA_Slow_M5 = INVALID_HANDLE;
int hEMA_Fast_M15 = INVALID_HANDLE;
int hEMA_Slow_M15 = INVALID_HANDLE;
int hRSI_M5 = INVALID_HANDLE;
int hRSI_M5_Short = INVALID_HANDLE;
int hRSI_M1 = INVALID_HANDLE;
int hATR_M5 = INVALID_HANDLE;
int hMA20_H1 = INVALID_HANDLE;
int hMA50_H1 = INVALID_HANDLE;
int hRSI_H1 = INVALID_HANDLE;

datetime LastM5CandleTime = 0;
datetime LastM1Time = 0;
datetime LastAIRequest = 0;
int M1BarsElapsed = 0;
bool TradeOpenThisCandle = false;
bool DirectionDecided = false;
string CandleDirection = "NONE";
string AI_Bias = "NONE";
int AI_Confidence = 0;
int TodayTrades = 0;
int TodayWins = 0;
int TodayLosses = 0;
int LastTradeDay = -1;
double DailyStartBalance = 0;
bool DailyLimitHit = false;
double TakeProfit_Dollars = 12.03;

struct DirectionContext
{
   double atrPoints;
   double rsi5;
   double rsi5Prev;
   double rsi5Short;
   double rsiH1;
   int bullishCount;
   int bearishCount;
   bool m5Bull;
   bool m5Bear;
   bool m15Bull;
   bool m15Bear;
   bool h1Bull;
   bool h1Bear;
};

bool SafeCopyBuffer(int handle, int count, double &arr[])
{
   if(handle == INVALID_HANDLE || count <= 0) return false;
   ArrayResize(arr, count);
   ArraySetAsSeries(arr, true);
   int copied = CopyBuffer(handle, 0, 0, count, arr);
   return (copied >= count);
}

bool SafeCopyRates(ENUM_TIMEFRAMES tf, int startPos, int count, MqlRates &rates[])
{
   if(count <= 0) return false;
   ArrayResize(rates, count);
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, startPos, count, rates);
   return (copied >= count);
}

bool IsNewTradingDay()
{
   MqlDateTime dt;
   TimeLocal(dt);
   if(dt.day != LastTradeDay)
   {
      LastTradeDay = dt.day;
      return true;
   }
   return false;
}

void ResetDailyStats()
{
   TodayTrades = 0;
   TodayWins = 0;
   TodayLosses = 0;
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   DailyLimitHit = false;
}

void ResetCandleState()
{
   TradeOpenThisCandle = HasPosition();
   DirectionDecided = false;
   CandleDirection = "NONE";
   M1BarsElapsed = 0;
   LastM1Time = 0;
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

bool CheckDailyLimits()
{
   if(!UseDailyLimits) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - DailyStartBalance;

   if(dailyPL >= DailyProfitTarget || dailyPL <= -DailyLossLimit)
   {
      if(!DailyLimitHit)
      {
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   return DailyLimitHit;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
}

void ReleaseHandle(int &h)
{
   if(h != INVALID_HANDLE)
   {
      IndicatorRelease(h);
      h = INVALID_HANDLE;
   }
}

bool InitIndicators()
{
   hEMA_Fast_M5   = iMA(_Symbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5   = iMA(_Symbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Fast_M15  = iMA(_Symbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15  = iMA(_Symbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5        = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   hRSI_M5_Short  = iRSI(_Symbol, PERIOD_M5, RSI_Short_Period, PRICE_CLOSE);
   hRSI_M1        = iRSI(_Symbol, PERIOD_M1, RSI_M1_Period, PRICE_CLOSE);
   hATR_M5        = iATR(_Symbol, PERIOD_M5, 14);
   hMA20_H1       = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1       = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1        = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);

   return (hEMA_Fast_M5 != INVALID_HANDLE && hEMA_Slow_M5 != INVALID_HANDLE &&
           hEMA_Fast_M15 != INVALID_HANDLE && hEMA_Slow_M15 != INVALID_HANDLE &&
           hRSI_M5 != INVALID_HANDLE && hRSI_M5_Short != INVALID_HANDLE &&
           hRSI_M1 != INVALID_HANDLE && hATR_M5 != INVALID_HANDLE &&
           hMA20_H1 != INVALID_HANDLE && hMA50_H1 != INVALID_HANDLE && hRSI_H1 != INVALID_HANDLE);
}

void ReleaseIndicators()
{
   ReleaseHandle(hEMA_Fast_M5);
   ReleaseHandle(hEMA_Slow_M5);
   ReleaseHandle(hEMA_Fast_M15);
   ReleaseHandle(hEMA_Slow_M15);
   ReleaseHandle(hRSI_M5);
   ReleaseHandle(hRSI_M5_Short);
   ReleaseHandle(hRSI_M1);
   ReleaseHandle(hATR_M5);
   ReleaseHandle(hMA20_H1);
   ReleaseHandle(hMA50_H1);
   ReleaseHandle(hRSI_H1);
}

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   if(!InitIndicators()) return INIT_FAILED;
   ResetDailyStats();
   Print("[INIT] Modular RSI-enhanced EA loaded");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ReleaseIndicators();
}

double GetATR()
{
   double atr[];
   if(!SafeCopyBuffer(hATR_M5, 1, atr)) return 30 * _Point;
   return atr[0];
}

void GetRSIThresholds(double atrPoints, double &buyLevel, double &sellLevel)
{
   buyLevel = RSI_BuyAbove;
   sellLevel = RSI_SellBelow;
   if(!UseDynamicRSIThresholds) return;

   if(atrPoints >= RSI_HighVol_ATR_Points)
   {
      buyLevel = RSI_HighVol_BuyAbove;
      sellLevel = RSI_HighVol_SellBelow;
   }
   else
   {
      buyLevel = RSI_LowVol_BuyAbove;
      sellLevel = RSI_LowVol_SellBelow;
   }
}

bool RecentCrossUp(const double &rsi[], double level, int lookback)
{
   int maxCheck = MathMin(lookback, ArraySize(rsi) - 2);
   for(int i = 1; i <= maxCheck; i++)
      if(rsi[i] <= level && rsi[i-1] > level)
         return true;
   return false;
}

bool RecentCrossDown(const double &rsi[], double level, int lookback)
{
   int maxCheck = MathMin(lookback, ArraySize(rsi) - 2);
   for(int i = 1; i <= maxCheck; i++)
      if(rsi[i] >= level && rsi[i-1] < level)
         return true;
   return false;
}

bool HasBearishRSIDivergence()
{
   if(!UseRSIDivergenceBlock) return false;
   MqlRates rates[];
   double rsi[];
   int count = RSI_DivergenceLookback + 6;
   if(!SafeCopyRates(PERIOD_M5, 1, count, rates) || !SafeCopyBuffer(hRSI_M5, count, rsi)) return false;

   int peak1 = -1, peak2 = -1;
   for(int i = 1; i < count - 1; i++)
   {
      if(rates[i].high > rates[i-1].high && rates[i].high > rates[i+1].high)
      {
         if(peak1 == -1) peak1 = i;
         else { peak2 = i; break; }
      }
   }
   if(peak1 == -1 || peak2 == -1) return false;
   return (rates[peak1].high > rates[peak2].high && rsi[peak1] < rsi[peak2]);
}

bool HasBullishRSIDivergence()
{
   if(!UseRSIDivergenceBlock) return false;
   MqlRates rates[];
   double rsi[];
   int count = RSI_DivergenceLookback + 6;
   if(!SafeCopyRates(PERIOD_M5, 1, count, rates) || !SafeCopyBuffer(hRSI_M5, count, rsi)) return false;

   int trough1 = -1, trough2 = -1;
   for(int i = 1; i < count - 1; i++)
   {
      if(rates[i].low < rates[i-1].low && rates[i].low < rates[i+1].low)
      {
         if(trough1 == -1) trough1 = i;
         else { trough2 = i; break; }
      }
   }
   if(trough1 == -1 || trough2 == -1) return false;
   return (rates[trough1].low < rates[trough2].low && rsi[trough1] > rsi[trough2]);
}

bool BuildDirectionContext(DirectionContext &ctx)
{
   double atr[];
   if(!SafeCopyBuffer(hATR_M5, 1, atr)) return false;
   ctx.atrPoints = atr[0] / _Point;
   if(ctx.atrPoints < MinATR_Points) return false;

   MqlRates m5[];
   if(!SafeCopyRates(PERIOD_M5, 1, MomentumCandles, m5)) return false;

   ctx.bullishCount = 0;
   ctx.bearishCount = 0;
   double totalBody = 0;
   for(int i = 0; i < MomentumCandles; i++)
   {
      double body = (m5[i].close - m5[i].open) / _Point;
      totalBody += MathAbs(body);
      if(m5[i].close > m5[i].open) ctx.bullishCount++;
      else if(m5[i].close < m5[i].open) ctx.bearishCount++;
   }
   if((totalBody / MomentumCandles) < MinAvgBody_Points) return false;

   double emaF5[], emaS5[], emaF15[], emaS15[], ma20[], ma50[], rsi5[], rsi5s[], rsiH1[];
   int rsiNeed = MathMax(RSI_RecentCrossLookbackBars + 2, 4);

   if(!SafeCopyBuffer(hEMA_Fast_M5, 2, emaF5) || !SafeCopyBuffer(hEMA_Slow_M5, 2, emaS5) ||
      !SafeCopyBuffer(hRSI_M5, rsiNeed, rsi5) || !SafeCopyBuffer(hRSI_M5_Short, 2, rsi5s)) return false;

   ctx.m5Bull = (emaF5[0] > emaS5[0]);
   ctx.m5Bear = (emaF5[0] < emaS5[0]);
   ctx.rsi5 = rsi5[0];
   ctx.rsi5Prev = rsi5[1];
   ctx.rsi5Short = rsi5s[0];
   ctx.rsiH1 = 50.0;
   ctx.m15Bull = true; ctx.m15Bear = true; ctx.h1Bull = true; ctx.h1Bear = true;

   if(UseMTF_Filter || UseH1RSIScore || UseMTF_Scoring)
   {
      if(!SafeCopyBuffer(hEMA_Fast_M15, 1, emaF15) || !SafeCopyBuffer(hEMA_Slow_M15, 1, emaS15) ||
         !SafeCopyBuffer(hMA20_H1, 1, ma20) || !SafeCopyBuffer(hMA50_H1, 1, ma50) || !SafeCopyBuffer(hRSI_H1, 2, rsiH1)) return false;
      ctx.m15Bull = (emaF15[0] > emaS15[0]);
      ctx.m15Bear = (emaF15[0] < emaS15[0]);
      ctx.h1Bull = (ma20[0] > ma50[0]);
      ctx.h1Bear = (ma20[0] < ma50[0]);
      ctx.rsiH1 = rsiH1[0];
   }

   return true;
}

string DecideDirection()
{
   DirectionContext ctx;
   if(!BuildDirectionContext(ctx)) return "SKIP";

   double buyLevel, sellLevel;
   GetRSIThresholds(ctx.atrPoints, buyLevel, sellLevel);

   double rsiFull[];
   int rsiNeed = MathMax(RSI_RecentCrossLookbackBars + 2, 4);
   if(!SafeCopyBuffer(hRSI_M5, rsiNeed, rsiFull)) return "SKIP";

   bool slopeUp = (ctx.rsi5 > ctx.rsi5Prev);
   bool slopeDown = (ctx.rsi5 < ctx.rsi5Prev);
   bool dualBuy = (!UseDualRSIConfluence || (ctx.rsi5Short > 50.0));
   bool dualSell = (!UseDualRSIConfluence || (ctx.rsi5Short < 50.0));
   bool recentBuy = (!RequireRecentRSICenterCross || RecentCrossUp(rsiFull, RSI_RecentCrossLevel, RSI_RecentCrossLookbackBars));
   bool recentSell = (!RequireRecentRSICenterCross || RecentCrossDown(rsiFull, RSI_RecentCrossLevel, RSI_RecentCrossLookbackBars));
   bool buyDivBlocked = HasBearishRSIDivergence();
   bool sellDivBlocked = HasBullishRSIDivergence();

   bool buyBase = (ctx.bullishCount >= 2 && ctx.rsi5 > buyLevel && (!UseRSISlopeFilter || slopeUp) && dualBuy && recentBuy && !buyDivBlocked);
   bool sellBase = (ctx.bearishCount >= 2 && ctx.rsi5 < sellLevel && (!UseRSISlopeFilter || slopeDown) && dualSell && recentSell && !sellDivBlocked);

   int buyScore = 0, sellScore = 0;
   if(ctx.m5Bull) buyScore++; else if(ctx.m5Bear) sellScore++;
   if(ctx.m15Bull) buyScore++; else if(ctx.m15Bear) sellScore++;
   if(ctx.h1Bull) buyScore++; else if(ctx.h1Bear) sellScore++;
   if(UseH1RSIScore)
   {
      if(ctx.rsiH1 >= H1_RSI_Bull_Min) buyScore++;
      else if(ctx.rsiH1 <= H1_RSI_Bear_Max) sellScore++;
   }

   string direction = "SKIP";
   if(UseMTF_Scoring)
   {
      if(buyBase && buyScore >= MTF_MinScore) direction = "BUY";
      else if(sellBase && sellScore >= MTF_MinScore) direction = "SELL";
   }
   else
   {
      bool h1rsiBuy = (!UseH1RSIScore || ctx.rsiH1 >= H1_RSI_Bull_Min);
      bool h1rsiSell = (!UseH1RSIScore || ctx.rsiH1 <= H1_RSI_Bear_Max);
      if(buyBase && ctx.m5Bull && ctx.m15Bull && ctx.h1Bull && h1rsiBuy) direction = "BUY";
      else if(sellBase && ctx.m5Bear && ctx.m15Bear && ctx.h1Bear && h1rsiSell) direction = "SELL";
   }

   if(UseAI_Bias && AI_Bias != "NONE" && direction != "SKIP")
   {
      if(direction == "BUY" && AI_Bias == "SELL") return "SKIP";
      if(direction == "SELL" && AI_Bias == "BUY") return "SKIP";
   }
   return direction;
}

int SecondsIntoCurrentM5()
{
   datetime m5Open = iTime(_Symbol, PERIOD_M5, 0);
   return (int)(TimeCurrent() - m5Open);
}

bool ConfirmM1WithRSI(string direction)
{
   if(!UseM1RSIConfirm) return true;
   double rsiM1[];
   if(!SafeCopyBuffer(hRSI_M1, 2, rsiM1)) return false;
   if(direction == "BUY") return (rsiM1[0] >= M1_RSI_BuyMin && rsiM1[0] > rsiM1[1]);
   if(direction == "SELL") return (rsiM1[0] <= M1_RSI_SellMax && rsiM1[0] < rsiM1[1]);
   return false;
}

void GetTP(double &tp_dist)
{
   double atrPoints = GetATR() / _Point;
   double tpPoints = atrPoints * ATR_TP_Mult;
   tpPoints = MathMax(tpPoints, Min_TP_Points);
   tpPoints = MathMin(tpPoints, Max_TP_Points);
   tp_dist = tpPoints * _Point;
}

bool GetLastSwingLow(double &swingLow)
{
   MqlRates m5[];
   if(!SafeCopyRates(PERIOD_M5, 1, SwingLookbackBars, m5)) return false;
   for(int i = 0; i <= SwingLookbackBars - 3; i++)
      if(m5[i].low < m5[i+1].low && m5[i].low < m5[i+2].low)
      {
         swingLow = m5[i].low;
         return true;
      }
   return false;
}

bool GetLastSwingHigh(double &swingHigh)
{
   MqlRates m5[];
   if(!SafeCopyRates(PERIOD_M5, 1, SwingLookbackBars, m5)) return false;
   for(int i = 0; i <= SwingLookbackBars - 3; i++)
      if(m5[i].high > m5[i+1].high && m5[i].high > m5[i+2].high)
      {
         swingHigh = m5[i].high;
         return true;
      }
   return false;
}

double ComputeBuySL(double entryPrice)
{
   double atrPts = GetATR() / _Point;
   double swingLow = 0.0;
   bool hasSwing = GetLastSwingLow(swingLow);
   double baseDistPts = hasSwing && swingLow < entryPrice ? ((entryPrice - swingLow) / _Point + SwingBufferPoints) : MathMax(atrPts, (double)SL_MinPoints);
   double minFloorPts = MathMax((double)SL_MinPoints, atrPts * SL_ATR_Mult);
   double finalDistPts = MathMin(MathMax(baseDistPts, minFloorPts), (double)SL_MaxPoints);
   return NormalizeDouble(entryPrice - finalDistPts * _Point, _Digits);
}

double ComputeSellSL(double entryPrice)
{
   double atrPts = GetATR() / _Point;
   double swingHigh = 0.0;
   bool hasSwing = GetLastSwingHigh(swingHigh);
   double baseDistPts = hasSwing && swingHigh > entryPrice ? ((swingHigh - entryPrice) / _Point + SwingBufferPoints) : MathMax(atrPts, (double)SL_MinPoints);
   double minFloorPts = MathMax((double)SL_MinPoints, atrPts * SL_ATR_Mult);
   double finalDistPts = MathMin(MathMax(baseDistPts, minFloorPts), (double)SL_MaxPoints);
   return NormalizeDouble(entryPrice + finalDistPts * _Point, _Digits);
}

double CalcLot(double sl_dist)
{
   if(!UseRiskSizing) return LotSize;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * RiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(tickVal <= 0 || tickSize <= 0 || step <= 0) return LotSize;

   double lossPerLot = (sl_dist / tickSize) * tickVal;
   if(lossPerLot <= 0) return LotSize;

   double lot = riskAmt / lossPerLot;
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, MinLot);
   lot = MathMin(lot, MaxLot);
   return lot;
}

bool ExecuteOrder(string direction)
{
   double tp_dist = 0.0;
   GetTP(tp_dist);

   if(direction == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ComputeBuySL(ask);
      double lot = CalcLot(MathAbs(ask - sl));
      double tp = NormalizeDouble(ask + tp_dist, _Digits);
      return trade.Buy(lot, _Symbol, ask, sl, tp, "M5v5 BUY");
   }
   if(direction == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = ComputeSellSL(bid);
      double lot = CalcLot(MathAbs(bid - sl));
      double tp = NormalizeDouble(bid - tp_dist, _Digits);
      return trade.Sell(lot, _Symbol, bid, sl, tp, "M5v5 SELL");
   }
   return false;
}

void RegisterFilledEntry()
{
   TradeOpenThisCandle = true;
   TodayTrades++;
}

void CheckM1Confirmation()
{
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 != LastM1Time)
   {
      LastM1Time = currentM1;
      M1BarsElapsed++;
   }

   if(M1BarsElapsed < ConfirmWaitBars) return;
   if(M1BarsElapsed > 3) { CandleDirection = "SKIP"; return; }
   if(SecondsIntoCurrentM5() > MaxEntrySecondsInM5) { CandleDirection = "SKIP"; return; }

   MqlRates m1[];
   if(!SafeCopyRates(PERIOD_M1, 1, 1, m1)) return;

   double body = (m1[0].close - m1[0].open) / _Point;
   if(MathAbs(body) < MinM1ConfirmBody) return;

   bool bull = (m1[0].close > m1[0].open);
   bool bear = (m1[0].close < m1[0].open);
   double m5Open = iOpen(_Symbol, PERIOD_M5, 0);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(CandleDirection == "BUY")
   {
      if(!bull) return;
      if(RequireM1BreakHigh && bid <= m5Open) return;
      if(!ConfirmM1WithRSI("BUY")) return;
      if(ExecuteOrder("BUY")) RegisterFilledEntry();
   }
   else if(CandleDirection == "SELL")
   {
      if(!bear) return;
      if(RequireM1BreakLow && ask >= m5Open) return;
      if(!ConfirmM1WithRSI("SELL")) return;
      if(ExecuteOrder("SELL")) RegisterFilledEntry();
   }
}

void CheckProfitTarget()
{
   double rsi5[];
   bool hasRSI = SafeCopyBuffer(hRSI_M5, 2, rsi5);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double curPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (type == POSITION_TYPE_BUY) ? ((curPrice - openPrice) / _Point) : ((openPrice - curPrice) / _Point);

      if(profit >= TakeProfit_Dollars || profitPts >= (GetATR() / _Point) * 2.0)
      {
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         continue;
      }

      if(UseRSIExtremeExit && hasRSI && profitPts > 0)
      {
         if(type == POSITION_TYPE_BUY && rsi5[0] >= RSI_ExtremeOverbought)
         {
            trade.PositionClose(ticket);
            TodayWins++;
            TradeOpenThisCandle = false;
         }
         else if(type == POSITION_TYPE_SELL && rsi5[0] <= RSI_ExtremeOversold)
         {
            trade.PositionClose(ticket);
            TodayWins++;
            TradeOpenThisCandle = false;
         }
      }
   }
}

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
      double profitPts = (type == POSITION_TYPE_BUY) ? (bid - openPrice) / _Point : (openPrice - ask) / _Point;

      if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints) continue;
      if(profit >= -1.00)
      {
         trade.PositionClose(ticket);
         if(profit > 0) TodayWins++; else TodayLosses++;
      }
   }
}

void ManageTrailing()
{
   double atr = GetATR();
   double rsi5[];
   bool hasRSI = SafeCopyBuffer(hRSI_M5, 2, rsi5);

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

      double trailMult = Trail_ATR_Mult;
      if(TightenTrailOnRSIExtreme && hasRSI)
      {
         if(type == POSITION_TYPE_BUY && rsi5[0] >= RSI_ExtremeOverbought) trailMult = ExtremeTrail_ATR_Mult;
         if(type == POSITION_TYPE_SELL && rsi5[0] <= RSI_ExtremeOversold) trailMult = ExtremeTrail_ATR_Mult;
      }

      double trailDist = atr * trailMult;
      double step = Trail_StepPoints * _Point;

      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice) / _Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(bid - trailDist, _Digits);
            if(curSL == 0 || newSL > curSL + step) trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask) / _Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(ask + trailDist, _Digits);
            if(curSL == 0 || newSL < curSL - step) trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

void UpdateAIBias()
{
   if(OpenAI_ApiKey == "") { AI_Bias = "NONE"; return; }

   double ma20[], ma50[], rsiH1[];
   if(!SafeCopyBuffer(hMA20_H1, 1, ma20) || !SafeCopyBuffer(hMA50_H1, 1, ma50) || !SafeCopyBuffer(hRSI_H1, 3, rsiH1))
   {
      AI_Bias = "NONE";
      return;
   }

   MqlRates h1[];
   if(!SafeCopyRates(PERIOD_H1, 0, 5, h1))
   {
      AI_Bias = "NONE";
      return;
   }

   string trend = (ma20[0] > ma50[0]) ? "BULLISH" : (ma20[0] < ma50[0]) ? "BEARISH" : "NEUTRAL";
   string candles = "";
   for(int i = 0; i < 5; i++)
      candles += "H1[" + IntegerToString(i) + "] O=" + DoubleToString(h1[i].open, _Digits) + " H=" + DoubleToString(h1[i].high, _Digits) + " L=" + DoubleToString(h1[i].low, _Digits) + " C=" + DoubleToString(h1[i].close, _Digits) + "\\n";

   string prompt = "=== M5 SCALPER BIAS ===\\n"
                 + "Symbol: " + _Symbol + "\\n"
                 + "Trend: " + trend + " | H1 RSI: " + DoubleToString(rsiH1[0], 2) + "\\n"
                 + candles
                 + "Reply BUY 78 or SELL 72 or HOLD 50. One line.";

   string raw = OpenAIRequest(prompt);
   if(raw == "") { AI_Bias = "NONE"; return; }

   int conf = 0;
   string sig = ExtractSignal(raw, conf);
   if(conf >= AI_ConfidenceThreshold) { AI_Bias = sig; AI_Confidence = conf; }
   else AI_Bias = "NONE";
}

string OpenAIRequest(string prompt)
{
   string url = "https://api.openai.com/v1/chat/completions";
   StringReplace(prompt, "\"", "'");

   string sys = "You are a XAUUSD M5 scalping bias analyst. Reply SIGNAL CONFIDENCE only.";
   string body = "{\"model\":\"" + OpenAI_Model + "\","
               + "\"messages\":[{\"role\":\"system\",\"content\":\"" + sys + "\"},{\"role\":\"user\",\"content\":\"" + prompt + "\"}],"
               + "\"max_tokens\":10,\"temperature\":0.0}";

   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);
   char result[];
   string responseHeaders;
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + OpenAI_ApiKey + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", url, headers, 30000, post, result, responseHeaders);
   if(code == -1) return "";
   return CharArrayToString(result);
}

string ExtractSignal(string jsonText, int &confidence)
{
   CJAVal json;
   confidence = 0;
   if(!json.Deserialize(jsonText)) return "HOLD";

   string text = json["choices"][0]["message"]["content"].ToStr();
   StringTrimLeft(text);
   StringTrimRight(text);
   StringToUpper(text);

   string signal = "HOLD";
   if(StringFind(text, "BUY") >= 0) signal = "BUY";
   else if(StringFind(text, "SELL") >= 0) signal = "SELL";

   string parts[];
   int n = StringSplit(text, ' ', parts);
   if(n >= 2)
   {
      int p = (int)StringToInteger(parts[1]);
      if(p > 0 && p <= 100) confidence = p;
      else confidence = 50;
   }
   else confidence = 50;
   return signal;
}

void OnTick()
{
   if(IsNewTradingDay()) ResetDailyStats();
   if(CheckDailyLimits()) return;

   if(UseAI_Bias)
   {
      datetime now = TimeCurrent();
      if((int)(now - LastAIRequest) >= AI_RefreshSeconds)
      {
         UpdateAIBias();
         LastAIRequest = now;
      }
   }

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
      ResetCandleState();

      if(!HasPosition())
      {
         CandleDirection = DecideDirection();
         DirectionDecided = true;
      }
   }

   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition() && CandleDirection != "SKIP")
      CheckM1Confirmation();
}
//+------------------------------------------------------------------+
