//+------------------------------------------------------------------+
//| ea_5minCandle_scalp_v6_Fixed18SL_stops_fixed.mq5                  |
//| Patched to handle broker stop/freeze levels and invalid stops     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.01"

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
input string OpenAI_ApiKey = "";
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

long GetBrokerStopsLevelPoints(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
long GetBrokerFreezeLevelPoints(){ return SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL); }

double GetMinStopDistancePrice()
{
   long stopsLevel  = GetBrokerStopsLevelPoints();
   long freezeLevel = GetBrokerFreezeLevelPoints();
   long minLevel    = (long)MathMax(stopsLevel, freezeLevel);
   return (double)minLevel * _Point;
}

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
   double atrBuff[];
   ArraySetAsSeries(atrBuff, true);
   double atr = (CopyBuffer(hATR_M5, 0, 0, 1, atrBuff) <= 0) ? 30 * _Point : atrBuff[0];
   double atrPoints = atr / _Point;
   double tp_pts = atrPoints * ATR_TP_Mult;
   if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
   if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;
   tp_dist = tp_pts * _Point;
}

void BuildSafeSLTP(bool isBuy, double entryPrice, double &sl, double &tp, double &usedSLDist, double &usedTPDist)
{
   double reqSL, reqTP;
   GetSLTP(reqSL, reqTP);
   double minStopDist = GetMinStopDistancePrice();
   double extraBuf = 5 * _Point;
   usedSLDist = MathMax(reqSL, minStopDist + extraBuf);
   usedTPDist = MathMax(reqTP, minStopDist + extraBuf);
   if(isBuy)
   {
      sl = NormalizeDouble(entryPrice - usedSLDist, _Digits);
      tp = NormalizeDouble(entryPrice + usedTPDist, _Digits);
   }
   else
   {
      sl = NormalizeDouble(entryPrice + usedSLDist, _Digits);
      tp = NormalizeDouble(entryPrice - usedTPDist, _Digits);
   }
}

double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 30 * _Point;
   return atr[0];
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
   return NormalizeLot(riskAmt / lossPerLot);
}

bool PlaceBuyWithFallback(double lot, double ask, double sl, double tp)
{
   if(trade.Buy(lot, _Symbol, ask, sl, tp, "M5v6 BUY")) return true;
   Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_STOPS) return false;
   if(!trade.Buy(lot, _Symbol, ask, 0.0, 0.0, "M5v6 BUY")) return false;
   if(!PositionSelect(_Symbol)) return false;
   return trade.PositionModify(_Symbol, sl, tp);
}

bool PlaceSellWithFallback(double lot, double bid, double sl, double tp)
{
   if(trade.Sell(lot, _Symbol, bid, sl, tp, "M5v6 SELL")) return true;
   Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   if(trade.ResultRetcode() != TRADE_RETCODE_INVALID_STOPS) return false;
   if(!trade.Sell(lot, _Symbol, bid, 0.0, 0.0, "M5v6 SELL")) return false;
   if(!PositionSelect(_Symbol)) return false;
   return trade.PositionModify(_Symbol, sl, tp);
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
   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE || hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE || hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE) return(INIT_FAILED);
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("[INIT] patched EA | stopPts=", GetBrokerStopsLevelPoints(), " freezePts=", GetBrokerFreezeLevelPoints());
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
}

string DecideDirection()
{
   double atr[]; ArraySetAsSeries(atr, true); CopyBuffer(hATR_M5, 0, 0, 1, atr); if(atr[0] / _Point < MinATR_Points) return "SKIP";
   MqlRates m5[]; ArraySetAsSeries(m5, true); CopyRates(_Symbol, PERIOD_M5, 1, MomentumCandles, m5);
   int bullish = 0, bearish = 0; double totalBody = 0;
   for(int i = 0; i < MomentumCandles; i++){ double body = (m5[i].close - m5[i].open) / _Point; totalBody += MathAbs(body); if(m5[i].close > m5[i].open) bullish++; else if(m5[i].close < m5[i].open) bearish++; }
   if(totalBody / MomentumCandles < MinAvgBody_Points) return "SKIP";
   double emaF5[], emaS5[]; ArraySetAsSeries(emaF5, true); ArraySetAsSeries(emaS5, true); CopyBuffer(hEMA_Fast_M5, 0, 0, 2, emaF5); CopyBuffer(hEMA_Slow_M5, 0, 0, 2, emaS5);
   bool m5_bullish = (emaF5[0] > emaS5[0]), m5_bearish = (emaF5[0] < emaS5[0]);
   double rsi5[]; ArraySetAsSeries(rsi5, true); CopyBuffer(hRSI_M5, 0, 0, 2, rsi5);
   bool m15_bullish = true, m15_bearish = true, h1_bullish = true, h1_bearish = true;
   if(UseMTF_Filter){ double emaF15[], emaS15[]; ArraySetAsSeries(emaF15, true); ArraySetAsSeries(emaS15, true); CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15); CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15); m15_bullish = (emaF15[0] > emaS15[0]); m15_bearish = (emaF15[0] < emaS15[0]); double ma20[], ma50[]; ArraySetAsSeries(ma20, true); ArraySetAsSeries(ma50, true); CopyBuffer(hMA20_H1, 0, 0, 1, ma20); CopyBuffer(hMA50_H1, 0, 0, 1, ma50); h1_bullish = (ma20[0] > ma50[0]); h1_bearish = (ma20[0] < ma50[0]); }
   string direction = "SKIP";
   if(UseMTF_Scoring){ int buyScore = 0, sellScore = 0; if(m5_bullish) buyScore++; else if(m5_bearish) sellScore++; if(m15_bullish) buyScore++; else if(m15_bearish) sellScore++; if(h1_bullish) buyScore++; else if(h1_bearish) sellScore++; if(bullish >= 2 && rsi5[0] > RSI_BuyAbove && buyScore >= MTF_MinScore) direction = "BUY"; else if(bearish >= 2 && rsi5[0] < RSI_SellBelow && sellScore >= MTF_MinScore) direction = "SELL"; }
   else { if(bullish >= 2 && m5_bullish && rsi5[0] > RSI_BuyAbove && m15_bullish && h1_bullish) direction = "BUY"; else if(bearish >= 2 && m5_bearish && rsi5[0] < RSI_SellBelow && m15_bearish && h1_bearish) direction = "SELL"; }
   if(UseAI_Bias && AI_Bias != "NONE" && direction != "SKIP"){ if(direction == "BUY" && AI_Bias == "SELL") return "SKIP"; if(direction == "SELL" && AI_Bias == "BUY") return "SKIP"; }
   return direction;
}

void ExecuteBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, tp, usedSLDist, usedTPDist;
   BuildSafeSLTP(true, ask, sl, tp, usedSLDist, usedTPDist);
   double lot = CalcLot(usedSLDist);
   Print("[BUY CHECK] Ask=", ask, " lot=", lot, " SL=", sl, " TP=", tp, " stopPts=", GetBrokerStopsLevelPoints(), " freezePts=", GetBrokerFreezeLevelPoints());
   if(PlaceBuyWithFallback(lot, ask, sl, tp)){ TradeOpenThisCandle = true; TodayTrades++; Print("[ENTRY] BUY ", lot, " lots | SL:", sl, " TP:", tp); }
}

void ExecuteSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, tp, usedSLDist, usedTPDist;
   BuildSafeSLTP(false, bid, sl, tp, usedSLDist, usedTPDist);
   double lot = CalcLot(usedSLDist);
   Print("[SELL CHECK] Bid=", bid, " lot=", lot, " SL=", sl, " TP=", tp, " stopPts=", GetBrokerStopsLevelPoints(), " freezePts=", GetBrokerFreezeLevelPoints());
   if(PlaceSellWithFallback(lot, bid, sl, tp)){ TradeOpenThisCandle = true; TodayTrades++; Print("[ENTRY] SELL ", lot, " lots | SL:", sl, " TP:", tp); }
}

void CheckM1Confirmation()
{
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0); if(currentM1 != LastM1Time){ LastM1Time = currentM1; M1BarsElapsed++; }
   if(M1BarsElapsed < ConfirmWaitBars) return;
   if(M1BarsElapsed > 3){ CandleDirection = "SKIP"; Print("[SKIP] Too late in candle. M1 bars: ", M1BarsElapsed); return; }
   MqlRates m1[]; ArraySetAsSeries(m1, true); CopyRates(_Symbol, PERIOD_M1, 1, 1, m1);
   double m1Body = (m1[0].close - m1[0].open) / _Point, m1AbsBody = MathAbs(m1Body); bool m1Bullish = (m1[0].close > m1[0].open), m1Bearish = (m1[0].close < m1[0].open); if(m1AbsBody < MinM1ConfirmBody) return;
   double m5Open = iOpen(_Symbol, PERIOD_M5, 0), currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID), currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(CandleDirection == "BUY"){ if(!m1Bullish) return; if(RequireM1BreakHigh && currentBid <= m5Open) return; ExecuteBuy(); }
   if(CandleDirection == "SELL"){ if(!m1Bearish) return; if(RequireM1BreakLow && currentAsk >= m5Open) return; ExecuteSell(); }
}

void CheckProfitTarget()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--){ if(PositionGetSymbol(i) != _Symbol) continue; if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue; ulong ticket = PositionGetInteger(POSITION_TICKET); double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN); ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE); double priceCurrent = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK); double profitPoints = (type == POSITION_TYPE_BUY) ? (priceCurrent - priceOpen) / _Point : (priceOpen - priceCurrent) / _Point; double dynamicTP = (GetATR() / _Point) * 2.0; if(profitPoints >= dynamicTP){ trade.PositionClose(ticket); TodayWins++; TradeOpenThisCandle = false; } }
}

void HandleCandleEndClose()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--){ if(PositionGetSymbol(i) != _Symbol) continue; if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue; ulong ticket = PositionGetInteger(POSITION_TICKET); double profit = PositionGetDouble(POSITION_PROFIT); double openPrice = PositionGetDouble(POSITION_PRICE_OPEN); ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE); double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID); double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK); double profitPts = (type == POSITION_TYPE_BUY) ? (bid - openPrice)/_Point : (openPrice - ask)/_Point; if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints) continue; if(profit >= -1.00){ trade.PositionClose(ticket); if(profit > 0) TodayWins++; else TodayLosses++; } }
}

void ManageTrailing()
{
   double atr = GetATR(), trailDist = atr * Trail_ATR_Mult, trailStep = Trail_StepPoints * _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--){ if(PositionGetSymbol(i) != _Symbol) continue; if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue; ulong ticket = PositionGetInteger(POSITION_TICKET); double openPrice = PositionGetDouble(POSITION_PRICE_OPEN), curSL = PositionGetDouble(POSITION_SL), curTP = PositionGetDouble(POSITION_TP); ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE); double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK); if(type == POSITION_TYPE_BUY){ double profitPts = (bid - openPrice)/_Point; if(profitPts >= Trail_StartPoints){ double newSL = NormalizeDouble(bid - trailDist, _Digits); if(newSL > curSL + trailStep) trade.PositionModify(ticket, newSL, curTP); }} else if(type == POSITION_TYPE_SELL){ double profitPts = (openPrice - ask)/_Point; if(profitPts >= Trail_StartPoints){ double newSL = NormalizeDouble(ask + trailDist, _Digits); if(newSL < curSL - trailStep || curSL == 0) trade.PositionModify(ticket, newSL, curTP); }} }
}

bool CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY), dailyPL = equity - DailyStartBalance;
   if(dailyPL >= DailyProfitTarget){ if(!DailyLimitHit){ CloseAllPositions(); DailyLimitHit = true; } return true; }
   if(dailyPL <= -DailyLossLimit){ if(!DailyLimitHit){ CloseAllPositions(); DailyLimitHit = true; } return true; }
   return false;
}

void CloseAllPositions(){ for(int i = PositionsTotal() - 1; i >= 0; i--) if(PositionGetSymbol(i) == _Symbol) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) trade.PositionClose(PositionGetInteger(POSITION_TICKET)); }
bool HasPosition(){ for(int i = PositionsTotal() - 1; i >= 0; i--) if(PositionGetSymbol(i) == _Symbol) if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) return true; return false; }

void UpdateAIBias(){ AI_Bias = "NONE"; }
string OpenAIRequest(string prompt){ return ""; }
string ExtractSignal(string jsonText, int &confidence){ confidence = 50; return "HOLD"; }

void OnTick()
{
   MqlDateTime dt; TimeLocal(dt);
   if(dt.day != LastTradeDay){ TodayTrades = 0; TodayWins = 0; TodayLosses = 0; LastTradeDay = dt.day; DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); DailyLimitHit = false; }
   if(HasPosition()){ CheckProfitTarget(); if(UseTrailingStop) ManageTrailing(); }
   datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5 != LastM5CandleTime){ if(HasPosition()) HandleCandleEndClose(); LastM5CandleTime = currentM5; TradeOpenThisCandle = HasPosition(); DirectionDecided = false; CandleDirection = "NONE"; M1BarsElapsed = 0; LastM1Time = 0; if(!HasPosition()){ CandleDirection = DecideDirection(); DirectionDecided = true; } }
   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition() && CandleDirection != "SKIP") CheckM1Confirmation();
}
//+------------------------------------------------------------------+
