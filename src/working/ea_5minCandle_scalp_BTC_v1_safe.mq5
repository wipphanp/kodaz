//+------------------------------------------------------------------+
//| ea_5minCandle_scalp_BTC_v1_safe.mq5                               |
//| Adapted from ea_5minCandle_scalp_v5_riskfixed.mq5 (XAUUSD)        |
//| Target: BTCUSD (Bitcoin CFD) — Safe-Trading Adaptation            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| WHY BTC NEEDS DIFFERENT HANDLING THAN XAUUSD (summary)            |
//|  1. BTC price scale varies wildly by broker (e.g. 60000-120000)   |
//|     so a fixed "points" SL floor is meaningless. We floor SL as   |
//|     a % of price instead, then convert to points internally.      |
//|  2. BTC can spike 3-5x its normal ATR in seconds (flash moves).   |
//|     A volatility-spike filter skips new entries in that regime.   |
//|  3. Spreads balloon during low-liquidity hours/weekends. A spread |
//|     filter blocks entries when spread is abnormally wide.         |
//|  4. Crypto trades 24/7 — weekend liquidity is thin and gappy.     |
//|     An optional "avoid weekend" switch keeps the bot flat then.   |
//|  5. Leverage/lot risk is amplified by volatility, so default risk |
//|     per trade and MaxRiskDollars are set more conservatively.     |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
input string SymbolToTrade = "BTCUSDT";  // Must match your broker's exact BTC symbol name
input double LotSize = 0.01;            // Fallback fixed lot if risk sizing disabled
input long   MagicNumber = 20260702;

//=== DYNAMIC SL/TP (ATR + % FLOOR) ===
input bool   UseDynamic_SLTP = true;
input double ATR_SL_Mult = 1.5;         // Wider than gold default (1.2) — BTC noise is bigger
input double ATR_TP_Mult = 2.5;
input double Min_RR_Ratio = 1.5;
input double Max_TP_Percent = 2.0;      // Cap TP at this % of price (avoid unrealistic targets)
input double Min_TP_Percent = 0.3;      // Minimum TP as % of price
input double Min_SL_Percent = 0.5;      // NEW: SL floor as % of price (e.g. 0.5% of 100000 = $500)

//=== RISK SIZING (DOLLAR-CAPPED, SAME LOGIC AS GOLD v5) ===
input bool   UseRiskSizing = true;
input double RiskPercent = 0.3;         // Lower default than gold (0.5%) due to higher volatility
input double MaxRiskDollars = 40.0;     // Hard per-trade loss ceiling
input double MaxLot = 0.20;             // Much lower than gold's 1.0 — BTC notional per lot is huge
input double MinLot = 0.01;
input double SkipTradeRiskMultiplier = 1.5;

//=== VOLATILITY SPIKE PROTECTION (NEW — crypto-specific) ===
input bool   UseVolatilitySpikeFilter = true;
input double VolatilitySpikeMult = 2.5;  // Skip entry if current ATR > X times its recent average
input int    ATR_AvgLookback = 20;       // Bars used to compute "normal" ATR baseline

//=== SPREAD PROTECTION (NEW — crypto-specific) ===
input bool   UseSpreadFilter = true;
input double MaxSpreadPercent = 0.15;    // Skip entry if spread > this % of price

//=== WEEKEND / LOW-LIQUIDITY GUARD (NEW — crypto-specific) ===
input bool   AvoidWeekendTrading = true; // Flat during Sat/Sun low-liquidity gaps
input bool   CloseOpenTradesBeforeWeekend = true;
input int    WeekendCloseHourUTC = 21;   // Friday hour (UTC) to start flattening positions

//=== HOLD WINNERS PAST CANDLE ===
input bool   HoldWinnersPastCandle = true;
input double HoldMinProfitPercent = 0.15; // As % of price instead of fixed points
input double HoldTrailBufferPercent = 0.08;

//=== TRAILING STOP ===
input bool   UseTrailingStop = true;
input double Trail_ATR_Mult = 1.0;
input double Trail_StartPercent = 0.2;   // Start trailing after this % move in favor
input double Trail_StepPercent = 0.08;

//=== MTF SCORING ===
input bool   UseMTF_Scoring = true;
input int    MTF_MinScore = 2;

//=== DAILY LIMITS ===
input bool   UseDailyLimits = true;      // Recommended ON for crypto (unlike gold default)
input double DailyProfitTarget = 80.0;
input double DailyLossLimit = 100.0;

//=== CONFIRMATION ENTRY SETTINGS ===
input int    ConfirmWaitBars = 1;
input double MinM1ConfirmBodyPercent = 0.03; // As % of price instead of fixed points
input bool   RequireM1BreakHigh = true;
input bool   RequireM1BreakLow = true;

//=== MULTI-TIMEFRAME FILTER ===
input bool   UseMTF_Filter = true;
input int    EMA_Fast_Period = 9;
input int    EMA_Slow_Period = 21;

//=== MOMENTUM & FILTERS ===
input int    MomentumCandles = 3;
input double MinAvgBodyPercent = 0.05;   // As % of price
input double MinATR_Percent = 0.08;      // As % of price
input double RSI_BuyAbove = 51.0;
input double RSI_SellBelow = 47.0;

//=== AI BIAS (optional) ===
input bool   UseAI_Bias = true;
input int    AI_RefreshSeconds = 60;
input string OpenAI_ApiKey = "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";         // Set at attach-time, never hardcode
input string OpenAI_Model = "gpt-4o-mini";
input int    AI_ConfidenceThreshold = 70;

//=== PROFIT TARGET (R-MULTIPLE, SAME LOGIC AS GOLD v5) ===
input double ProfitTarget_RMultiple = 1.0;
input double DynamicTP_ATR_Mult = 2.0;

//=== GLOBAL STATE ===
string   TradeSymbol;
datetime LastM5CandleTime = 0;
datetime LastAIRequest = 0;
string   AI_Bias = "NONE";
int      AI_Confidence = 0;
bool     TradeOpenThisCandle = false;
bool     DirectionDecided = false;
string   CandleDirection = "NONE";
int      M1BarsElapsed = 0;
datetime LastM1Time = 0;
int      TodayTrades = 0;
int      TodayWins = 0;
int      TodayLosses = 0;
int      LastTradeDay = -1;
double   DailyStartBalance = 0;
bool     DailyLimitHit = false;

int hEMA_Fast_M5, hEMA_Slow_M5;
int hEMA_Fast_M15, hEMA_Slow_M15;
int hRSI_M5;
int hATR_M5;
int hMA20_H1, hMA50_H1, hRSI_H1;
//+------------------------------------------------------------------+
int OnInit()
{
   TradeSymbol = (SymbolToTrade == "") ? _Symbol : SymbolToTrade;
   if(!SymbolSelect(TradeSymbol, true))
   {
      Print("[INIT ERROR] Symbol not found: ", TradeSymbol);
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);

   hEMA_Fast_M5 = iMA(TradeSymbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5 = iMA(TradeSymbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5 = iRSI(TradeSymbol, PERIOD_M5, 14, PRICE_CLOSE);
   hATR_M5 = iATR(TradeSymbol, PERIOD_M5, 14);

   hEMA_Fast_M15 = iMA(TradeSymbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15 = iMA(TradeSymbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);

   hMA20_H1 = iMA(TradeSymbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1 = iMA(TradeSymbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1 = iRSI(TradeSymbol, PERIOD_H1, 14, PRICE_CLOSE);

   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE)
      return(INIT_FAILED);

   Print("[INIT] BTC M5 Scalper v1 (Safe Edition) on ", TradeSymbol);
   Print("[INIT] SL=", DoubleToString(ATR_SL_Mult,2), "xATR | TP=", DoubleToString(ATR_TP_Mult,2), "xATR");
   Print("[INIT] MinSL%=", DoubleToString(Min_SL_Percent,2), " | MaxRiskDollars=", DoubleToString(MaxRiskDollars,2));

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
   Print("[STATS] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses);
}

//+------------------------------------------------------------------+
bool IsWeekendNow()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return true; // Sun=0, Sat=6
   if(dt.day_of_week == 5 && dt.hour >= WeekendCloseHourUTC) return true; // Friday cutover
   return false;
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

   if(UseDailyLimits && CheckDailyLimits()) return;

   // NEW: weekend / low-liquidity guard
   if(AvoidWeekendTrading && IsWeekendNow())
   {
      if(CloseOpenTradesBeforeWeekend && HasPosition())
      {
         Print("[WEEKEND GUARD] Flattening positions ahead of low-liquidity window.");
         CloseAllPositions();
      }
      return; // no new entries during weekend window
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

   datetime currentM5 = iTime(TradeSymbol, PERIOD_M5, 0);
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
// NEW: spread filter — blocks entries when spread is abnormally wide
//+------------------------------------------------------------------+
bool SpreadTooWide()
{
   if(!UseSpreadFilter) return false;
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   if(bid <= 0) return true;
   double spreadPct = (ask - bid) / bid * 100.0;
   if(spreadPct > MaxSpreadPercent)
   {
      Print("[SPREAD GUARD] Spread ", DoubleToString(spreadPct,3), "% exceeds max ", MaxSpreadPercent, "%. Skipping.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// NEW: volatility spike filter — blocks entries during abnormal ATR
// expansion (flash-move protection specific to crypto).
//+------------------------------------------------------------------+
bool VolatilitySpikeDetected()
{
   if(!UseVolatilitySpikeFilter) return false;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   int need = ATR_AvgLookback + 1;
   if(CopyBuffer(hATR_M5, 0, 0, need, atrBuf) < need) return false;

   double current = atrBuf[0];
   double sum = 0;
   for(int i = 1; i <= ATR_AvgLookback; i++) sum += atrBuf[i];
   double avg = sum / ATR_AvgLookback;

   if(avg <= 0) return false;
   if(current > avg * VolatilitySpikeMult)
   {
      Print("[VOL SPIKE] ATR ", DoubleToString(current,2), " vs avg ", DoubleToString(avg,2),
            " (", DoubleToString(current/avg,2), "x). Skipping new entries.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
string DecideDirection()
{
   if(SpreadTooWide() || VolatilitySpikeDetected()) return "SKIP";

   double price = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   if(price <= 0) return "SKIP";

   double atr[];
   ArraySetAsSeries(atr, true);
   CopyBuffer(hATR_M5, 0, 0, 1, atr);
   double atrPercent = (atr[0] / price) * 100.0;
   if(atrPercent < MinATR_Percent) return "SKIP";

   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   CopyRates(TradeSymbol, PERIOD_M5, 1, MomentumCandles, m5);

   int bullish = 0, bearish = 0;
   double totalBodyPercent = 0;
   for(int i = 0; i < MomentumCandles; i++)
   {
      double bodyPct = MathAbs(m5[i].close - m5[i].open) / m5[i].open * 100.0;
      totalBodyPercent += bodyPct;
      if(m5[i].close > m5[i].open) bullish++;
      else if(m5[i].close < m5[i].open) bearish++;
   }

   if(totalBodyPercent / MomentumCandles < MinAvgBodyPercent)
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
      if(m5_bullish) buyScore++; else if(m5_bearish) sellScore++;
      if(m15_bullish) buyScore++; else if(m15_bearish) sellScore++;
      if(h1_bullish) buyScore++; else if(h1_bearish) sellScore++;

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
   if(SpreadTooWide()) return;

   datetime currentM1 = iTime(TradeSymbol, PERIOD_M1, 0);
   if(currentM1 != LastM1Time)
   {
      LastM1Time = currentM1;
      M1BarsElapsed++;
   }

   if(M1BarsElapsed < ConfirmWaitBars) return;

   if(M1BarsElapsed > 3)
   {
      CandleDirection = "SKIP";
      Print("[SKIP] Too late in candle. M1 bars: ", M1BarsElapsed);
      return;
   }

   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   CopyRates(TradeSymbol, PERIOD_M1, 1, 1, m1);

   double m1BodyPct = MathAbs(m1[0].close - m1[0].open) / m1[0].open * 100.0;
   bool m1Bullish = (m1[0].close > m1[0].open);
   bool m1Bearish = (m1[0].close < m1[0].open);

   if(m1BodyPct < MinM1ConfirmBodyPercent) return;

   double m5Open = iOpen(TradeSymbol, PERIOD_M5, 0);
   double currentBid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

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
// SL/TP floors expressed as % of price (BTC-safe), converted to
// absolute price distance for order placement.
//+------------------------------------------------------------------+
void GetDynamicSLTP(double &sl_dist, double &tp_dist)
{
   double price = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double atr = GetATR();

   double sl_abs = atr * ATR_SL_Mult;
   double tp_abs = atr * ATR_TP_Mult;

   double minSLAbs = price * (Min_SL_Percent / 100.0);
   double minTPAbs = price * (Min_TP_Percent / 100.0);
   double maxTPAbs = price * (Max_TP_Percent / 100.0);

   if(sl_abs < minSLAbs) sl_abs = minSLAbs;
   if(tp_abs < minTPAbs) tp_abs = minTPAbs;
   if(tp_abs > maxTPAbs) tp_abs = maxTPAbs;

   if(tp_abs / sl_abs < Min_RR_Ratio)
      tp_abs = sl_abs * Min_RR_Ratio;

   sl_dist = sl_abs;
   tp_dist = tp_abs;

   Print("[SLTP] ATR=", DoubleToString(atr,2), " | SL=$", DoubleToString(sl_abs,2),
         " (", DoubleToString(sl_abs/price*100,3), "%) | TP=$", DoubleToString(tp_abs,2),
         " | RR=", DoubleToString(tp_abs/sl_abs,2));
}

//+------------------------------------------------------------------+
void GetSLTP(double &sl_dist, double &tp_dist)
{
   if(UseDynamic_SLTP)
      GetDynamicSLTP(sl_dist, tp_dist);
   else
   {
      double price = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
      double atr = GetATR();
      sl_dist = atr * ATR_SL_Mult;
      tp_dist = atr * ATR_TP_Mult;
      double minSLAbs = price * (Min_SL_Percent / 100.0);
      if(sl_dist < minSLAbs) sl_dist = minSLAbs;
   }
}

//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0)
   {
      double price = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
      return price * 0.003; // fallback ~0.3% if ATR unavailable
   }
   return atr[0];
}

//+------------------------------------------------------------------+
// Dollar-capped risk sizing (same principle as gold v5 fix).
// Works in absolute $ SL distance rather than "points" since BTC
// contract specs (tick value/size) vary a lot by broker.
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
   if(!UseRiskSizing) return LotSize;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = MathMin(balance * RiskPercent / 100.0, MaxRiskDollars);
   double tickVal = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0 || tickVal == 0) return LotSize;

   double lossPerLot = (sl_dist / tickSize) * tickVal;
   if(lossPerLot <= 0) return LotSize;

   double lot = riskAmt / lossPerLot;
   double step = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;

   if(lot < MinLot)
   {
      double minLotRisk = MinLot * lossPerLot;
      if(minLotRisk > MaxRiskDollars * SkipTradeRiskMultiplier)
      {
         Print("[SKIP TRADE] MinLot risk ($", DoubleToString(minLotRisk,2),
               ") exceeds cap ($", DoubleToString(MaxRiskDollars * SkipTradeRiskMultiplier,2), ")");
         return 0;
      }
      lot = MinLot;
   }
   if(lot > MaxLot) lot = MaxLot;

   double estRisk = lot * lossPerLot;
   Print("[LOTSIZE] lot=", DoubleToString(lot,3), " | estRisk=$", DoubleToString(estRisk,2),
         " | slDist=$", DoubleToString(sl_dist,2));

   return lot;
}

//+------------------------------------------------------------------+
void ExecuteBuy()
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = CalcLot(sl_dist);
   if(lot <= 0) { Print("[SKIP] BUY skipped - risk too high"); return; }

   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(ask - sl_dist, digits);
   double tp = NormalizeDouble(ask + tp_dist, digits);

   if(!trade.Buy(lot, TradeSymbol, ask, sl, tp, "BTCv1 BUY"))
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
   if(lot <= 0) { Print("[SKIP] SELL skipped - risk too high"); return; }

   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double sl = NormalizeDouble(bid + sl_dist, digits);
   double tp = NormalizeDouble(bid - tp_dist, digits);

   if(!trade.Sell(lot, TradeSymbol, bid, sl, tp, "BTCv1 SELL"))
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
      if(PositionGetSymbol(i) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double priceCurrent = (type == POSITION_TYPE_BUY) ?
         SymbolInfoDouble(TradeSymbol, SYMBOL_BID) : SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);

      double riskDist = MathAbs(priceOpen - sl);
      double gainDist = (type == POSITION_TYPE_BUY) ?
         (priceCurrent - priceOpen) : (priceOpen - priceCurrent);

      double rMultiple = (riskDist > 0) ? gainDist / riskDist : 0;

      double atr = GetATR();
      double dynamicTPAbs = atr * DynamicTP_ATR_Mult;

      bool rTargetHit = (riskDist > 0 && rMultiple >= ProfitTarget_RMultiple);
      bool atrTargetHit = (gainDist >= dynamicTPAbs);

      if(rTargetHit || atrTargetHit)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         double profit = PositionGetDouble(POSITION_PROFIT);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[DYNAMIC TP] +$", DoubleToString(profit, 2),
               " | R=", DoubleToString(rMultiple,2),
               " | Trigger=", (rTargetHit ? "R-multiple" : "ATR"));
      }
   }
}

//+------------------------------------------------------------------+
void HandleCandleEndClose()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
      double gainAbs = (type == POSITION_TYPE_BUY) ? (bid - openPrice) : (openPrice - ask);
      double gainPct = gainAbs / openPrice * 100.0;

      if(HoldWinnersPastCandle && gainPct >= HoldMinProfitPercent)
      {
         Print("[HOLD] Winner running (+", DoubleToString(gainPct,3), "%). Trail buffer: ",
               DoubleToString(HoldTrailBufferPercent,3), "%");
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
void ManageTrailing()
{
   double atr = GetATR();
   double trailDist = atr * Trail_ATR_Mult;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

      double trailStepAbs = openPrice * (Trail_StepPercent / 100.0);
      double trailStartAbs = openPrice * (Trail_StartPercent / 100.0);

      if(type == POSITION_TYPE_BUY)
      {
         double gainAbs = bid - openPrice;
         if(gainAbs >= trailStartAbs)
         {
            double newSL = NormalizeDouble(bid - trailDist, digits);
            if(newSL > curSL + trailStepAbs)
            {
               trade.PositionModify(ticket, newSL, curTP);
               Print("[TRAIL] BUY SL -> ", newSL, " | Gain: $", DoubleToString(gainAbs,2));
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double gainAbs = openPrice - ask;
         if(gainAbs >= trailStartAbs)
         {
            double newSL = NormalizeDouble(ask + trailDist, digits);
            if(newSL < curSL - trailStepAbs || curSL == 0)
            {
               trade.PositionModify(ticket, newSL, curTP);
               Print("[TRAIL] SELL SL -> ", newSL, " | Gain: $", DoubleToString(gainAbs,2));
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
      if(PositionGetSymbol(i) == TradeSymbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == TradeSymbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

//+------------------------------------------------------------------+
void UpdateAIBias()
{
   if(OpenAI_ApiKey == "") { AI_Bias = "NONE"; return; }

   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ma20[], ma50[], rsiH1[];
   ArraySetAsSeries(ma20, true);
   ArraySetAsSeries(ma50, true);
   ArraySetAsSeries(rsiH1, true);
   CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
   CopyBuffer(hMA50_H1, 0, 0, 1, ma50);
   CopyBuffer(hRSI_H1, 0, 0, 3, rsiH1);

   MqlRates h1[];
   ArraySetAsSeries(h1, true);
   CopyRates(TradeSymbol, PERIOD_H1, 0, 5, h1);

   string candles = "";
   for(int i = 0; i < 5; i++)
      candles += "H1[" + IntegerToString(i) + "] O=" + DoubleToString(h1[i].open, 2)
               + " H=" + DoubleToString(h1[i].high, 2)
               + " L=" + DoubleToString(h1[i].low, 2)
               + " C=" + DoubleToString(h1[i].close, 2) + "\\n";

   string trend = (ma20[0] > ma50[0]) ? "BULLISH" : (ma20[0] < ma50[0]) ? "BEARISH" : "NEUTRAL";

   string prompt =
      "=== BTC M5 SCALPER BIAS ===\\n"
      "Symbol: " + TradeSymbol + " | Bid: " + DoubleToString(bid, 2) + "\\n" +
      "H1 MA20: " + DoubleToString(ma20[0], 2) + " MA50: " + DoubleToString(ma50[0], 2) + "\\n" +
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

   string sys = "You are a BTCUSD M5 scalping bias analyst.\\n"
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
