//+------------------------------------------------------------------+
//| ea_5minCandle_scalp_v6_Fixed18SL_COMPLETE_PATCHED_ALL_MODS.mq5    |
//| Complete EA patched for entry and all modification stop checks    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.20"

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

input double LotSize = 0.10;
input long MagicNumber = 20260607;
input double Fixed_SL_Points = 18;
input double ATR_TP_Mult = 3.0;
input double Max_TP_Points = 150;
input double Min_TP_Points = 40;
input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;
input double HoldTrailBuffer = 10;
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
input bool UseAI_Bias = true;
input int AI_RefreshSeconds = 60;
input string OpenAI_ApiKey = "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";
input string OpenAI_Model = "gpt-4o-mini";
input int AI_ConfidenceThreshold = 70;

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

int hEMA_Fast_M5, hEMA_Slow_M5;
int hEMA_Fast_M15, hEMA_Slow_M15;
int hRSI_M5;
int hATR_M5;
int hMA20_H1, hMA50_H1, hRSI_H1;

int GetVolumeDigits(double step)
{
   if(step <= 0.0) return 2;
   int digits = 0;
   while(step < 1.0 && digits < 8)
   {
      step *= 10.0;
      digits++;
   }
   return digits;
}

long GetBrokerStopsLevelPoints(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
long GetBrokerFreezeLevelPoints(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL); }

double GetStopLevelPrice(){ return (double)GetBrokerStopsLevelPoints() * _Point; }
double GetFreezeLevelPrice(){ return (double)GetBrokerFreezeLevelPoints() * _Point; }
double GetMinProtectedDistancePrice(){ return MathMax(GetStopLevelPrice(), GetFreezeLevelPrice()); }

double NormalizeLot(double lot)
{
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volStep <= 0.0) volStep = 0.01;
   lot = MathFloor(lot / volStep) * volStep;
   if(lot < volMin) lot = volMin;
   if(lot < MinLot) lot = MinLot;
   if(lot > volMax) lot = volMax;
   if(lot > MaxLot) lot = MaxLot;
   return NormalizeDouble(lot, GetVolumeDigits(volStep));
}

void GetSLTP(double &sl_dist, double &tp_dist)
{
   sl_dist = Fixed_SL_Points * _Point;
   double atr = GetATR();
   double atrPoints = atr / _Point;
   double tp_pts = atrPoints * ATR_TP_Mult;
   if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
   if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;
   tp_dist = tp_pts * _Point;
   Print("[SLTP] Fixed SL=", DoubleToString(Fixed_SL_Points,0), "pts | TP=", DoubleToString(tp_pts,0), "pts");
}

double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 30 * _Point;
   return atr[0];
}

void GetSafeSLTP(bool isBuy, double entryPrice, double &sl, double &tp, double &safeSLDist, double &safeTPDist)
{
   double reqSLDist, reqTPDist;
   GetSLTP(reqSLDist, reqTPDist);
   double minDist = GetMinProtectedDistancePrice();
   double extraBuf = 5 * _Point;
   safeSLDist = MathMax(reqSLDist, minDist + extraBuf);
   safeTPDist = MathMax(reqTPDist, minDist + extraBuf);
   if(isBuy)
   {
      sl = NormalizeDouble(entryPrice - safeSLDist, _Digits);
      tp = NormalizeDouble(entryPrice + safeTPDist, _Digits);
   }
   else
   {
      sl = NormalizeDouble(entryPrice + safeSLDist, _Digits);
      tp = NormalizeDouble(entryPrice - safeTPDist, _Digits);
   }
}

bool ValidateStopsAgainstMarket(ENUM_POSITION_TYPE type, double sl, double tp)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = GetMinProtectedDistancePrice() + 2 * _Point;

   if(type == POSITION_TYPE_BUY)
   {
      if(sl > 0 && (bid - sl) < minDist) return false;
      if(tp > 0 && (tp - bid) < minDist) return false;
   }
   else if(type == POSITION_TYPE_SELL)
   {
      if(sl > 0 && (sl - ask) < minDist) return false;
      if(tp > 0 && (ask - tp) < minDist) return false;
   }
   return true;
}

bool MakeProtectedStopsForPosition(ENUM_POSITION_TYPE type, double desiredSL, double desiredTP, double &safeSL, double &safeTP)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = GetMinProtectedDistancePrice() + 5 * _Point;

   safeSL = desiredSL;
   safeTP = desiredTP;

   if(type == POSITION_TYPE_BUY)
   {
      if(safeSL > 0)
         safeSL = NormalizeDouble(MathMin(safeSL, bid - minDist), _Digits);
      if(safeTP > 0)
         safeTP = NormalizeDouble(MathMax(safeTP, bid + minDist), _Digits);
   }
   else if(type == POSITION_TYPE_SELL)
   {
      if(safeSL > 0)
         safeSL = NormalizeDouble(MathMax(safeSL, ask + minDist), _Digits);
      if(safeTP > 0)
         safeTP = NormalizeDouble(MathMin(safeTP, ask - minDist), _Digits);
   }

   return ValidateStopsAgainstMarket(type, safeSL, safeTP);
}

bool SafePositionModify(ulong ticket, ENUM_POSITION_TYPE type, double desiredSL, double desiredTP)
{
   double safeSL, safeTP;
   if(!MakeProtectedStopsForPosition(type, desiredSL, desiredTP, safeSL, safeTP))
   {
      Print("[MODIFY BLOCKED] Invalid protected SL/TP after adjustment | ticket=", ticket,
            " | desiredSL=", desiredSL, " | desiredTP=", desiredTP);
      return false;
   }

   if(!trade.PositionModify(ticket, safeSL, safeTP))
   {
      Print("[MODIFY ERROR] ticket=", ticket,
            " | retcode=", trade.ResultRetcode(),
            " | desc=", trade.ResultRetcodeDescription(),
            " | SL=", safeSL, " | TP=", safeTP,
            " | stopPts=", GetBrokerStopsLevelPoints(),
            " | freezePts=", GetBrokerFreezeLevelPoints());
      return false;
   }

   Print("[MODIFY OK] ticket=", ticket, " | SL=", safeSL, " | TP=", safeTP);
   return true;
}

double CalcLot(double sl_dist)
{
   if(!UseRiskSizing) return NormalizeLot(LotSize);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * RiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickVal <= 0) return NormalizeLot(LotSize);
   double lossPerLot = (sl_dist / tickSize) * tickVal;
   if(lossPerLot <= 0) return NormalizeLot(LotSize);
   double lot = riskAmt / lossPerLot;
   return NormalizeLot(lot);
}

bool PlaceBuyWithFallback(double lot, double ask, double sl, double tp)
{
   if(trade.Buy(lot, _Symbol, ask, sl, tp, "M5v6 BUY")) return true;
   Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_STOPS) return false;
   Print("[RETRY] BUY without SL/TP, then modify after fill");
   if(!trade.Buy(lot, _Symbol, ask, 0.0, 0.0, "M5v6 BUY"))
   {
      Print("[ERROR] BUY retry failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }
   if(!PositionSelect(_Symbol))
   {
      Print("[ERROR] BUY retry filled but PositionSelect failed");
      return false;
   }
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   return SafePositionModify(ticket, type, sl, tp);
}

bool PlaceSellWithFallback(double lot, double bid, double sl, double tp)
{
   if(trade.Sell(lot, _Symbol, bid, sl, tp, "M5v6 SELL")) return true;
   Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_STOPS) return false;
   Print("[RETRY] SELL without SL/TP, then modify after fill");
   if(!trade.Sell(lot, _Symbol, bid, 0.0, 0.0, "M5v6 SELL"))
   {
      Print("[ERROR] SELL retry failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
   }
   if(!PositionSelect(_Symbol))
   {
      Print("[ERROR] SELL retry filled but PositionSelect failed");
      return false;
   }
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   return SafePositionModify(ticket, type, sl, tp);
}

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
   hRSI_H1 = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE || hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE || hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE)
      return(INIT_FAILED);
   Print("[INIT] M5 Candle Scalper v6 fully patched for entry + all modify checks");
   Print("[INIT] stop level pts=", GetBrokerStopsLevelPoints(), " | freeze level pts=", GetBrokerFreezeLevelPoints());
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
   if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1 != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
   Print("[STATS] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses);
}

string DecideDirection()
{
   double atr[]; ArraySetAsSeries(atr, true); CopyBuffer(hATR_M5, 0, 0, 1, atr); if(atr[0] / _Point < MinATR_Points) return "SKIP";
   MqlRates m5[]; ArraySetAsSeries(m5, true); CopyRates(_Symbol, PERIOD_M5, 1, MomentumCandles, m5);
   int bullish = 0, bearish = 0; double totalBody = 0;
   for(int i = 0; i < MomentumCandles; i++)
   {
      double body = (m5[i].close - m5[i].open) / _Point;
      totalBody += MathAbs(body);
      if(m5[i].close > m5[i].open) bullish++; else if(m5[i].close < m5[i].open) bearish++;
   }
   if(totalBody / MomentumCandles < MinAvgBody_Points) return "SKIP";
   double emaF5[], emaS5[]; ArraySetAsSeries(emaF5, true); ArraySetAsSeries(emaS5, true); CopyBuffer(hEMA_Fast_M5, 0, 0, 2, emaF5); CopyBuffer(hEMA_Slow_M5, 0, 0, 2, emaS5);
   bool m5_bullish = (emaF5[0] > emaS5[0]); bool m5_bearish = (emaF5[0] < emaS5[0]);
   double rsi5[]; ArraySetAsSeries(rsi5, true); CopyBuffer(hRSI_M5, 0, 0, 2, rsi5);
   bool m15_bullish = true, m15_bearish = true; bool h1_bullish = true, h1_bearish = true;
   if(UseMTF_Filter)
   {
      double emaF15[], emaS15[]; ArraySetAsSeries(emaF15, true); ArraySetAsSeries(emaS15, true); CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15); CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15);
      m15_bullish = (emaF15[0] > emaS15[0]); m15_bearish = (emaF15[0] < emaS15[0]);
      double ma20[], ma50[]; ArraySetAsSeries(ma20, true); ArraySetAsSeries(ma50, true); CopyBuffer(hMA20_H1, 0, 0, 1, ma20); CopyBuffer(hMA50_H1, 0, 0, 1, ma50);
      h1_bullish = (ma20[0] > ma50[0]); h1_bearish = (ma20[0] < ma50[0]);
   }
   string direction = "SKIP";
   if(UseMTF_Scoring)
   {
      int buyScore = 0, sellScore = 0;
      if(m5_bullish) buyScore++; else if(m5_bearish) sellScore++;
      if(m15_bullish) buyScore++; else if(m15_bearish) sellScore++;
      if(h1_bullish) buyScore++; else if(h1_bearish) sellScore++;
      if(bullish >= 2 && rsi5[0] > RSI_BuyAbove && buyScore >= MTF_MinScore) direction = "BUY";
      else if(bearish >= 2 && rsi5[0] < RSI_SellBelow && sellScore >= MTF_MinScore) direction = "SELL";
   }
   else
   {
      if(bullish >= 2 && m5_bullish && rsi5[0] > RSI_BuyAbove && m15_bullish && h1_bullish) direction = "BUY";
      else if(bearish >= 2 && m5_bearish && rsi5[0] < RSI_SellBelow && m15_bearish && h1_bearish) direction = "SELL";
   }
   if(UseAI_Bias && AI_Bias != "NONE" && direction != "SKIP")
   {
      if(direction == "BUY" && AI_Bias == "SELL") return "SKIP";
      if(direction == "SELL" && AI_Bias == "BUY") return "SKIP";
   }
   return direction;
}

void CheckM1Confirmation()
{
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 != LastM1Time){ LastM1Time = currentM1; M1BarsElapsed++; }
   if(M1BarsElapsed < ConfirmWaitBars) return;
   if(M1BarsElapsed > 3)
   {
      CandleDirection = "SKIP";
      Print("[SKIP] Too late in candle. M1 bars: ", M1BarsElapsed);
      return;
   }
   MqlRates m1[]; ArraySetAsSeries(m1, true); CopyRates(_Symbol, PERIOD_M1, 1, 1, m1);
   double m1Body = (m1[0].close - m1[0].open) / _Point; double m1AbsBody = MathAbs(m1Body);
   bool m1Bullish = (m1[0].close > m1[0].open); bool m1Bearish = (m1[0].close < m1[0].open);
   if(m1AbsBody < MinM1ConfirmBody) return;
   double m5Open = iOpen(_Symbol, PERIOD_M5, 0); double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID); double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
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

void ExecuteBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl, tp, safeSLDist, safeTPDist;
   GetSafeSLTP(true, ask, sl, tp, safeSLDist, safeTPDist);
   double lot = CalcLot(safeSLDist);
   Print("[BUY CHECK] Ask=", ask, " | lot=", lot, " | SL=", sl, " | TP=", tp, " | stopPts=", GetBrokerStopsLevelPoints(), " | freezePts=", GetBrokerFreezeLevelPoints());
   if(PlaceBuyWithFallback(lot, ask, sl, tp))
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] BUY ", lot, " lots | SL:", sl, " TP:", tp);
   }
}

void ExecuteSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl, tp, safeSLDist, safeTPDist;
   GetSafeSLTP(false, bid, sl, tp, safeSLDist, safeTPDist);
   double lot = CalcLot(safeSLDist);
   Print("[SELL CHECK] Bid=", bid, " | lot=", lot, " | SL=", sl, " | TP=", tp, " | stopPts=", GetBrokerStopsLevelPoints(), " | freezePts=", GetBrokerFreezeLevelPoints());
   if(PlaceSellWithFallback(lot, bid, sl, tp))
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      Print("[ENTRY] SELL ", lot, " lots | SL:", sl, " TP:", tp);
   }
}

void CheckProfitTarget()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double priceCurrent = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (type == POSITION_TYPE_BUY) ? (priceCurrent - priceOpen) / _Point : (priceOpen - priceCurrent) / _Point;
      double atr = GetATR() / _Point;
      double dynamicTP = atr * 2.0;
      if(profitPoints >= dynamicTP)
      {
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[DYNAMIC TP] Profit: ", IntegerToString((int)profitPoints), "pts | Closed at optimal level");
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
      {
         Print("[HOLD] Winner running (+", IntegerToString((int)profitPts), "pts). Trail buffer: ", IntegerToString((int)HoldTrailBuffer), "pts");
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
               SafePositionModify(ticket, type, newSL, curTP);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         if(profitPts >= Trail_StartPoints)
         {
            double newSL = NormalizeDouble(ask + trailDist, _Digits);
            if(newSL < curSL - trailStep || curSL == 0)
               SafePositionModify(ticket, type, newSL, curTP);
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
   ArraySetAsSeries(ma20, true); ArraySetAsSeries(ma50, true); ArraySetAsSeries(rsiH1, true);
   CopyBuffer(hMA20_H1, 0, 0, 1, ma20); CopyBuffer(hMA50_H1, 0, 0, 1, ma50); CopyBuffer(hRSI_H1, 0, 0, 3, rsiH1);
   MqlRates h1[]; ArraySetAsSeries(h1, true); CopyRates(_Symbol, PERIOD_H1, 0, 5, h1);
   string candles = "";
   for(int i = 0; i < 5; i++)
      candles += "H1[" + IntegerToString(i) + "] O=" + DoubleToString(h1[i].open, _Digits) + " H=" + DoubleToString(h1[i].high, _Digits) + " L=" + DoubleToString(h1[i].low, _Digits) + " C=" + DoubleToString(h1[i].close, _Digits) + "\\n";
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
   if(conf >= AI_ConfidenceThreshold) { AI_Bias = sig; AI_Confidence = conf; Print("[AI] ", AI_Bias, " (", conf, ")"); }
   else { AI_Bias = "NONE"; Print("[AI] Low confidence. No filter."); }
}

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
      CheckM1Confirmation();
}
//+------------------------------------------------------------------+
