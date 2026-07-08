//+------------------------------------------------------------------+
//| ea_5minCandle_scalp_v5_RSIEnhanced.mq5                           |
//| RSI-enhanced version derived from user's v4 EA                   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "5.00"

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
input double LotSize = 0.10;
input long MagicNumber = 20260607;

//=== SL/TP SETTINGS ===
input double Fixed_SL_Points = 18;
input double ATR_TP_Mult = 3.0;
input double Max_TP_Points = 150;
input double Min_TP_Points = 40;

//=== SWING SL GUARDRAILS ===
input int SwingLookbackBars = 20;
input int SwingBufferPoints = 60;
input int SL_MinPoints = 120;
input int SL_MaxPoints = 360;
input double SL_ATR_Mult = 0.8;

//=== ENTRY TIMING GUARD ===
input int MaxEntrySecondsInM5 = 180;

//=== HOLD WINNERS ===
input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;
input double HoldTrailBuffer = 10;

//=== TRAILING STOP ===
input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 0.8;
input int Trail_StartPoints = 25;
input int Trail_StepPoints = 15;

//=== MTF SCORING ===
input bool UseMTF_Scoring = true;
input int MTF_MinScore = 2;

//=== RISK ===
input bool UseRiskSizing = true;
input double RiskPercent = 0.5;
input double MaxLot = 1.0;
input double MinLot = 0.01;

//=== DAILY LIMITS ===
input bool UseDailyLimits = false;
input double DailyProfitTarget = 100.0;
input double DailyLossLimit = 50.0;

//=== CONFIRMATION ENTRY SETTINGS ===
input int ConfirmWaitBars = 1;
input double MinM1ConfirmBody = 8.0;
input bool RequireM1BreakHigh = true;
input bool RequireM1BreakLow = true;

//=== MULTI-TIMEFRAME FILTER ===
input bool UseMTF_Filter = true;
input int EMA_Fast_Period = 9;
input int EMA_Slow_Period = 21;

//=== MOMENTUM & FILTERS ===
input int MomentumCandles = 3;
input double MinAvgBody_Points = 10.0;
input double MinATR_Points = 15.0;
input double RSI_BuyAbove = 51.0;
input double RSI_SellBelow = 47.0;

//=== RSI ENHANCEMENTS ===
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

//=== AI BIAS ===
input bool UseAI_Bias = true;
input int AI_RefreshSeconds = 60;
input string OpenAI_ApiKey = "";
input string OpenAI_Model = "gpt-4o-mini";
input int AI_ConfidenceThreshold = 70;

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
double TakeProfit_Dollars = 12.03;

//=== INDICATOR HANDLES ===
int hEMA_Fast_M5, hEMA_Slow_M5;
int hEMA_Fast_M15, hEMA_Slow_M15;
int hRSI_M5, hRSI_M5_Short, hRSI_M1;
int hATR_M5;
int hMA20_H1, hMA50_H1, hRSI_H1;

bool CopyIndicator(int handle, int count, double &arr[])
{
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, 0, 0, count, arr) < count)
      return false;
   return true;
}

bool CopyM5Rates(int startPos, int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, startPos, count, rates) < count)
      return false;
   return true;
}

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   hEMA_Fast_M5 = iMA(_Symbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5 = iMA(_Symbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5      = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   hRSI_M5_Short= iRSI(_Symbol, PERIOD_M5, RSI_Short_Period, PRICE_CLOSE);
   hRSI_M1      = iRSI(_Symbol, PERIOD_M1, RSI_M1_Period, PRICE_CLOSE);
   hATR_M5      = iATR(_Symbol, PERIOD_M5, 14);
   hEMA_Fast_M15= iMA(_Symbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15= iMA(_Symbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hMA20_H1     = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1     = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1      = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);

   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hRSI_M5_Short == INVALID_HANDLE ||
      hRSI_M1 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE ||
      hMA20_H1 == INVALID_HANDLE || hMA50_H1 == INVALID_HANDLE || hRSI_H1 == INVALID_HANDLE)
      return(INIT_FAILED);

   Print("[INIT] M5 Candle Scalper v5 RSI Enhanced");
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hEMA_Fast_M5 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M5);
   if(hEMA_Slow_M5 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M5);
   if(hEMA_Fast_M15 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M15);
   if(hEMA_Slow_M15 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M15);
   if(hRSI_M5 != INVALID_HANDLE) IndicatorRelease(hRSI_M5);
   if(hRSI_M5_Short != INVALID_HANDLE) IndicatorRelease(hRSI_M5_Short);
   if(hRSI_M1 != INVALID_HANDLE) IndicatorRelease(hRSI_M1);
   if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1 != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
}

void GetRSIThresholds(double atrPoints, double &buyLevel, double &sellLevel)
{
   buyLevel = RSI_BuyAbove;
   sellLevel = RSI_SellBelow;
   if(!UseDynamicRSIThresholds)
      return;

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

bool HadRecentCrossUp(const double &rsi[], double level, int lookback)
{
   for(int i = 1; i <= lookback; i++)
      if(rsi[i] <= level && rsi[i-1] > level)
         return true;
   return false;
}

bool HadRecentCrossDown(const double &rsi[], double level, int lookback)
{
   for(int i = 1; i <= lookback; i++)
      if(rsi[i] >= level && rsi[i-1] < level)
         return true;
   return false;
}

bool HasBearishRSIDivergence(int lookback)
{
   MqlRates m5[];
   double rsi[];
   int count = lookback + 6;
   if(!CopyM5Rates(1, count, m5) || !CopyIndicator(hRSI_M5, count, rsi))
      return false;

   int first = -1, second = -1;
   for(int i = 1; i < count - 1; i++)
   {
      if(m5[i].high > m5[i-1].high && m5[i].high > m5[i+1].high)
      {
         if(first == -1) first = i;
         else { second = i; break; }
      }
   }
   if(first == -1 || second == -1)
      return false;

   return (m5[first].high > m5[second].high && rsi[first] < rsi[second]);
}

bool HasBullishRSIDivergence(int lookback)
{
   MqlRates m5[];
   double rsi[];
   int count = lookback + 6;
   if(!CopyM5Rates(1, count, m5) || !CopyIndicator(hRSI_M5, count, rsi))
      return false;

   int first = -1, second = -1;
   for(int i = 1; i < count - 1; i++)
   {
      if(m5[i].low < m5[i-1].low && m5[i].low < m5[i+1].low)
      {
         if(first == -1) first = i;
         else { second = i; break; }
      }
   }
   if(first == -1 || second == -1)
      return false;

   return (m5[first].low < m5[second].low && rsi[first] > rsi[second]);
}

void OnTick()
{
   MqlDateTime dt;
   TimeLocal(dt);
   if(dt.day != LastTradeDay)
   {
      TodayTrades = 0; TodayWins = 0; TodayLosses = 0;
      LastTradeDay = dt.day;
      DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      DailyLimitHit = false;
   }

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
      TradeOpenThisCandle = HasPosition();
      DirectionDecided = false;
      CandleDirection = "NONE";
      M1BarsElapsed = 0;
      LastM1Time = 0;

      if(!HasPosition())
      {
         CandleDirection = DecideDirection();
         DirectionDecided = true;
      }
   }

   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition() && CandleDirection != "SKIP")
      CheckM1Confirmation();
}

string DecideDirection()
{
   double atr[];
   if(!CopyIndicator(hATR_M5, 1, atr))
      return "SKIP";
   double atrPoints = atr[0] / _Point;
   if(atrPoints < MinATR_Points)
      return "SKIP";

   MqlRates m5[];
   if(!CopyM5Rates(1, MomentumCandles, m5))
      return "SKIP";

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

   double emaF5[], emaS5[], rsi5[], rsi5s[];
   if(!CopyIndicator(hEMA_Fast_M5, 2, emaF5) || !CopyIndicator(hEMA_Slow_M5, 2, emaS5) ||
      !CopyIndicator(hRSI_M5, MathMax(RSI_RecentCrossLookbackBars + 2, 4), rsi5) ||
      !CopyIndicator(hRSI_M5_Short, 2, rsi5s))
      return "SKIP";

   bool m5_bullish = (emaF5[0] > emaS5[0]);
   bool m5_bearish = (emaF5[0] < emaS5[0]);
   bool rsiSlopeUp = (rsi5[0] > rsi5[1]);
   bool rsiSlopeDown = (rsi5[0] < rsi5[1]);
   bool dualBuy = (!UseDualRSIConfluence || (rsi5s[0] > rsi5s[1] && rsi5s[0] > 50.0));
   bool dualSell = (!UseDualRSIConfluence || (rsi5s[0] < rsi5s[1] && rsi5s[0] < 50.0));

   double buyRSILevel, sellRSILevel;
   GetRSIThresholds(atrPoints, buyRSILevel, sellRSILevel);

   bool recentCrossBuy = (!RequireRecentRSICenterCross || HadRecentCrossUp(rsi5, RSI_RecentCrossLevel, RSI_RecentCrossLookbackBars));
   bool recentCrossSell = (!RequireRecentRSICenterCross || HadRecentCrossDown(rsi5, RSI_RecentCrossLevel, RSI_RecentCrossLookbackBars));

   bool m15_bullish = true, m15_bearish = true;
   bool h1_bullish = true, h1_bearish = true;
   double rsiH1[];
   if(UseMTF_Filter || UseH1RSIScore)
   {
      double emaF15[], emaS15[], ma20[], ma50[];
      if(!CopyIndicator(hEMA_Fast_M15, 1, emaF15) || !CopyIndicator(hEMA_Slow_M15, 1, emaS15) ||
         !CopyIndicator(hMA20_H1, 1, ma20) || !CopyIndicator(hMA50_H1, 1, ma50) ||
         !CopyIndicator(hRSI_H1, 2, rsiH1))
         return "SKIP";
      m15_bullish = (emaF15[0] > emaS15[0]);
      m15_bearish = (emaF15[0] < emaS15[0]);
      h1_bullish = (ma20[0] > ma50[0]);
      h1_bearish = (ma20[0] < ma50[0]);
   }

   bool blockBuyDiv = (UseRSIDivergenceBlock && HasBearishRSIDivergence(RSI_DivergenceLookback));
   bool blockSellDiv = (UseRSIDivergenceBlock && HasBullishRSIDivergence(RSI_DivergenceLookback));

   string direction = "SKIP";
   bool buyBase = (bullish >= 2 && rsi5[0] > buyRSILevel && (!UseRSISlopeFilter || rsiSlopeUp) && dualBuy && recentCrossBuy && !blockBuyDiv);
   bool sellBase = (bearish >= 2 && rsi5[0] < sellRSILevel && (!UseRSISlopeFilter || rsiSlopeDown) && dualSell && recentCrossSell && !blockSellDiv);

   if(UseMTF_Scoring)
   {
      int buyScore = 0, sellScore = 0;
      if(m5_bullish) buyScore++; else if(m5_bearish) sellScore++;
      if(m15_bullish) buyScore++; else if(m15_bearish) sellScore++;
      if(h1_bullish) buyScore++; else if(h1_bearish) sellScore++;
      if(UseH1RSIScore && ArraySize(rsiH1) > 0)
      {
         if(rsiH1[0] >= H1_RSI_Bull_Min) buyScore++;
         else if(rsiH1[0] <= H1_RSI_Bear_Max) sellScore++;
      }
      if(buyBase && buyScore >= MTF_MinScore) direction = "BUY";
      else if(sellBase && sellScore >= MTF_MinScore) direction = "SELL";
   }
   else
   {
      bool h1rsiBuy = (!UseH1RSIScore || (ArraySize(rsiH1) > 0 && rsiH1[0] >= H1_RSI_Bull_Min));
      bool h1rsiSell = (!UseH1RSIScore || (ArraySize(rsiH1) > 0 && rsiH1[0] <= H1_RSI_Bear_Max));
      if(buyBase && m5_bullish && m15_bullish && h1_bullish && h1rsiBuy) direction = "BUY";
      else if(sellBase && m5_bearish && m15_bearish && h1_bearish && h1rsiSell) direction = "SELL";
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

   int secsInto = SecondsIntoCurrentM5();
   if(secsInto > MaxEntrySecondsInM5) { CandleDirection = "SKIP"; return; }

   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, m1) < 1) return;

   double m1Body = (m1[0].close - m1[0].open) / _Point;
   double m1AbsBody = MathAbs(m1Body);
   bool m1Bullish = (m1[0].close > m1[0].open);
   bool m1Bearish = (m1[0].close < m1[0].open);
   if(m1AbsBody < MinM1ConfirmBody) return;

   if(UseM1RSIConfirm)
   {
      double rsiM1[];
      if(!CopyIndicator(hRSI_M1, 2, rsiM1)) return;
      if(CandleDirection == "BUY" && !(rsiM1[0] >= M1_RSI_BuyMin && rsiM1[0] > rsiM1[1])) return;
      if(CandleDirection == "SELL" && !(rsiM1[0] <= M1_RSI_SellMax && rsiM1[0] < rsiM1[1])) return;
   }

   double m5Open = iOpen(_Symbol, PERIOD_M5, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(CandleDirection == "BUY")
   {
      if(!m1Bullish) return;
      if(RequireM1BreakHigh && currentBid <= m5Open) return;
      ExecuteBuy();
   }
   if(CandleDirection == "SELL")
   {
      if(!m1Bearish) return;
      if(RequireM1BreakLow && currentAsk >= m5Open) return;
      ExecuteSell();
   }
}

double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 30 * _Point;
   return atr[0];
}

void GetTP(double &tp_dist)
{
   double atr = GetATR();
   double atrPoints = atr / _Point;
   double tp_pts = atrPoints * ATR_TP_Mult;
   if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
   if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;
   tp_dist = tp_pts * _Point;
}

bool GetLastSwingLow(double &swingLow)
{
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   int copied = CopyRates(_Symbol, PERIOD_M5, 1, SwingLookbackBars, m5);
   if(copied < 3) return false;
   for(int i = 0; i <= copied - 3; i++)
   {
      if(m5[i].low < m5[i+1].low && m5[i].low < m5[i+2].low)
      {
         swingLow = m5[i].low;
         return true;
      }
   }
   return false;
}

bool GetLastSwingHigh(double &swingHigh)
{
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   int copied = CopyRates(_Symbol, PERIOD_M5, 1, SwingLookbackBars, m5);
   if(copied < 3) return false;
   for(int i = 0; i <= copied - 3; i++)
   {
      if(m5[i].high > m5[i+1].high && m5[i].high > m5[i+2].high)
      {
         swingHigh = m5[i].high;
         return true;
      }
   }
   return false;
}

double ComputeBuySL(double entryPrice)
{
   double swingLow;
   bool hasSwing = GetLastSwingLow(swingLow);
   double atr = GetATR();
   double atrPts = atr / _Point;
   double dynSL_pts = atrPts * 1.0;
   if(dynSL_pts < SL_MinPoints) dynSL_pts = SL_MinPoints;

   double baseDistPts;
   if(hasSwing && swingLow < entryPrice)
      baseDistPts = (entryPrice - swingLow) / _Point + SwingBufferPoints;
   else
      baseDistPts = dynSL_pts;

   double minVolFloorPts = atrPts * SL_ATR_Mult;
   double minFloorPts = MathMax((double)SL_MinPoints, minVolFloorPts);
   double finalDistPts = MathMin(MathMax(baseDistPts, minFloorPts), (double)SL_MaxPoints);
   return NormalizeDouble(entryPrice - finalDistPts * _Point, _Digits);
}

double ComputeSellSL(double entryPrice)
{
   double swingHigh;
   bool hasSwing = GetLastSwingHigh(swingHigh);
   double atr = GetATR();
   double atrPts = atr / _Point;
   double dynSL_pts = atrPts * 1.0;
   if(dynSL_pts < SL_MinPoints) dynSL_pts = SL_MinPoints;

   double baseDistPts;
   if(hasSwing && swingHigh > entryPrice)
      baseDistPts = (swingHigh - entryPrice) / _Point + SwingBufferPoints;
   else
      baseDistPts = dynSL_pts;

   double minVolFloorPts = atrPts * SL_ATR_Mult;
   double minFloorPts = MathMax((double)SL_MinPoints, minVolFloorPts);
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

void ExecuteBuy()
{
   double tp_dist;
   GetTP(tp_dist);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = ComputeBuySL(ask);
   double sl_dist = MathAbs(ask - sl);
   double lot = CalcLot(sl_dist);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);
   if(trade.Buy(lot, _Symbol, ask, sl, tp, "M5v5 BUY"))
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
   }
}

void ExecuteSell()
{
   double tp_dist;
   GetTP(tp_dist);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = ComputeSellSL(bid);
   double sl_dist = MathAbs(bid - sl);
   double lot = CalcLot(sl_dist);
   double tp = NormalizeDouble(bid - tp_dist, _Digits);
   if(trade.Sell(lot, _Symbol, bid, sl, tp, "M5v5 SELL"))
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
   }
}

void CheckProfitTarget()
{
   double rsi5[];
   CopyIndicator(hRSI_M5, 2, rsi5);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double priceCurrent = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (type == POSITION_TYPE_BUY) ? (priceCurrent - priceOpen) / _Point : (priceOpen - priceCurrent) / _Point;

      if(profit >= TakeProfit_Dollars)
      {
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
         TodayWins++;
         TradeOpenThisCandle = false;
         continue;
      }

      double atr = GetATR() / _Point;
      if(profitPoints >= atr * 2.0)
      {
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
         TodayWins++;
         TradeOpenThisCandle = false;
         continue;
      }

      if(UseRSIExtremeExit && ArraySize(rsi5) > 0)
      {
         if(type == POSITION_TYPE_BUY && rsi5[0] >= RSI_ExtremeOverbought && profitPoints > 0)
         {
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
            TodayWins++;
            TradeOpenThisCandle = false;
            continue;
         }
         if(type == POSITION_TYPE_SELL && rsi5[0] <= RSI_ExtremeOversold && profitPoints > 0)
         {
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
            TodayWins++;
            TradeOpenThisCandle = false;
            continue;
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
      double profitPts = (type == POSITION_TYPE_BUY) ? (bid - openPrice)/_Point : (openPrice - ask)/_Point;

      if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints)
         continue;

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
   CopyIndicator(hRSI_M5, 2, rsi5);

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
      if(TightenTrailOnRSIExtreme && ArraySize(rsi5) > 0)
      {
         if(type == POSITION_TYPE_BUY && rsi5[0] >= RSI_ExtremeOverbought) trailMult = ExtremeTrail_ATR_Mult;
         if(type == POSITION_TYPE_SELL && rsi5[0] <= RSI_ExtremeOversold) trailMult = ExtremeTrail_ATR_Mult;
      }

      double trailDist = atr * trailMult;
      double trailStep = Trail_StepPoints * _Point;

      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice)/_Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(bid - trailDist, _Digits);
            if(newSL > curSL + trailStep)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(ask + trailDist, _Digits);
            if(newSL < curSL - trailStep || curSL == 0)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

bool CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - DailyStartBalance;
   if(dailyPL >= DailyProfitTarget)
   {
      if(!DailyLimitHit)
      {
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   if(dailyPL <= -DailyLossLimit)
   {
      if(!DailyLimitHit)
      {
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   return false;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

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
   {
      AI_Bias = sig;
      AI_Confidence = conf;
   }
   else AI_Bias = "NONE";
}

string OpenAIRequest(string prompt)
{
   string url = "https://api.openai.com/v1/chat/completions";
   StringReplace(prompt, "\"", "'");

   string sys = "You are a XAUUSD M5 scalping bias analyst.\\nRules: Reply SIGNAL CONFIDENCE (e.g. BUY 78). One line. No explanation.";
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
   if(code == -1) return "";
   return CharArrayToString(result);
}

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
      else
      {
         p = (int)StringToInteger(parts[n-1]);
         confidence = (p > 0 && p <= 100) ? p : 50;
      }
   }
   else confidence = 50;
   return signal;
}
//+------------------------------------------------------------------+
