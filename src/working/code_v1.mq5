//+------------------------------------------------------------------+
//|                                                      code_v1.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== MODE SELECTION (SWING COMMENTED OUT) ===
// enum ENUM_TRADE_MODE { MODE_SWING=0, MODE_SCALP=1 };
// input ENUM_TRADE_MODE TradeMode = MODE_SCALP;

//=== COMMON PARAMETERS ===
input double LotSize = 0.10;
input long MagicNumber = 20260606;
input string OpenAI_ApiKey = "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";
input string OpenAI_Model = "gpt-4o-mini";
input int ConfidenceThreshold = 70;

//=== SWING MODE PARAMETERS (COMMENTED OUT) ===
// input int Swing_SL_Points = 1000;
// input int Swing_TP_Points = 2000;
// input int Swing_RefreshSeconds = 300;

//=== SCALP MODE PARAMETERS ===
input double ATR_SL_Multiplier = 1.5;     // SL = ATR * this (wider = fewer SL hits)
input double ATR_TP_Multiplier = 2.5;     // TP = ATR * this (TP > SL for positive R:R)
input int Scalp_MinSL_Points = 60;        // Minimum SL floor (never tighter than this)
input int Scalp_MaxSL_Points = 200;       // Maximum SL cap
input int Scalp_AI_RefreshSeconds = 300;
input int Scalp_CooldownSeconds = 45;     // Slightly longer cooldown to avoid overtrading
input int Scalp_MaxTradesPerDay = 20;     // Reduced from 30 to focus on quality
input double Scalp_MaxSpreadPoints = 30.0;
input int EMA_Fast = 9;
input int EMA_Slow = 21;

//=== TRAILING STOP & BREAKEVEN ===
input bool UseTrailingStop = true;
input double Trail_ATR_Multiplier = 1.0;  // Trail distance = ATR * this
input bool UseBreakeven = true;
input int Breakeven_TriggerPoints = 60;   // Move SL to breakeven after this much profit
input int Breakeven_LockPoints = 10;      // Lock this many points above entry

//=== RSI FILTER PARAMETERS ===
input int RSI_Period = 14;
input double RSI_OverboughtLimit = 70.0;  // Tightened from 75 - more conservative
input double RSI_OversoldLimit = 30.0;    // Tightened from 25

//=== ENTRY QUALITY FILTERS ===
input double MinCandleBodyPoints = 15.0;  // Skip entries on tiny/doji candles
input bool RequireRSIMomentum = true;     // RSI must be moving in trade direction
input bool RequireMomentumAccel = true;   // EMA gap must be widening (#4)
input bool RequireVolSpike = true;        // Tick volume must exceed average (#6)
input double VolSpike_Multiplier = 1.5;   // Volume must be X times 20-bar average

//=== PARTIAL TAKE PROFIT (#1) ===
input bool UsePartialTP = true;           // Close half at TP1, trail the rest
input double PartialTP_ATR_Mult = 1.2;    // TP1 (partial close) = ATR * this
input double PartialTP_Percent = 50.0;    // Percentage of position to close at TP1

//=== LOSS STREAK CIRCUIT BREAKER (#2) ===
input bool UseCircuitBreaker = true;      // Pause after consecutive losses
input int MaxConsecutiveLosses = 3;       // Pause trading after this many losses in a row
input int CircuitBreaker_PauseMin = 15;   // Pause duration in minutes

//=== NEWS/ATR SPIKE PAUSE (#8) ===
input bool UseATRSpikePause = true;       // Pause entries when ATR spikes (likely news event)
input double ATR_Spike_Multiplier = 3.0;  // Pause if current ATR > average ATR * this

//=== NEWS TIME AVOIDANCE ===
input bool UseNewsFilter = true;          // Avoid trading around high-impact news times
input int News_PauseBeforeMin = 5;        // Stop trading X minutes before news
input int News_PauseAfterMin = 5;         // Resume trading X minutes after news
// High-impact news times (IST hours). Format: hour*100 + minute
// NFP=18:00 IST (1st Fri), FOMC=00:00 IST, CPI=18:00 IST, Core PCE=18:00 IST
// These cover most USD-moving events that impact gold
input string NewsTimesIST = "1800,1830,2000,2030,0000,0030";  // Comma-separated HHMM times

//=== ADAPTIVE CONFIDENCE THRESHOLD (#9) ===
input bool UseAdaptiveConfidence = true;  // Adjust confidence threshold per session
input int Confidence_HighVol = 65;        // Threshold during London-NY overlap (many setups)
input int Confidence_MedVol = 70;         // Threshold during London/NY/Tokyo alone
input int Confidence_LowVol = 85;         // Threshold during Sydney (few setups, need strong signal)

//=== SESSION FILTER (IST) ===
input bool UseSessionFilter = true;
input int Sydney_StartHour = 3;
input int Sydney_EndHour = 12;
input int Tokyo_StartHour = 5;
input int Tokyo_EndHour = 14;
input int London_StartHour = 12;
input int London_EndHour = 21;
input int NY_StartHour = 17;
input int NY_EndHour = 2;

//=== GLOBAL STATE ===
datetime LastAIRequest = 0;
datetime LastScalpEntry = 0;
string AI_Bias = "HOLD";
int AI_Confidence = 0;
int TodayTradeCount = 0;
int LastTradeDay = -1;
int ConsecutiveLosses = 0;              // Circuit breaker: loss streak counter
datetime CircuitBreaker_ResumeTime = 0; // When to resume after pause
bool PartialTP_Done = false;            // Track if partial close already executed

//=== INDICATOR HANDLES ===
int hEMA_Fast_M1, hEMA_Slow_M1;
int hRSI_M5;
int hATR_M5;
int hMA20_H1, hMA50_H1;
int hRSI_H1;
int hATR_H1;

//--------------------------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   Print("[INIT] EA started. Mode: SCALP | Magic: ", MagicNumber);
   Print("[INIT] ATR-based SL/TP: SL=ATR*", ATR_SL_Multiplier, " TP=ATR*", ATR_TP_Multiplier);
   Print("[INIT] Trailing=", UseTrailingStop, " Breakeven=", UseBreakeven);
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("[WARNING] Automated trading disabled. Enable 'Allow Algo Trading'.");
   
   // H1 indicators (AI prompt)
   hMA20_H1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1  = iRSI(_Symbol, PERIOD_H1, RSI_Period, PRICE_CLOSE);
   hATR_H1  = iATR(_Symbol, PERIOD_H1, 14);
   
   if(hMA20_H1 == INVALID_HANDLE || hMA50_H1 == INVALID_HANDLE || 
      hRSI_H1 == INVALID_HANDLE || hATR_H1 == INVALID_HANDLE)
   {
      Print("[ERROR] Failed to create H1 indicator handles.");
      return(INIT_FAILED);
   }
   
   // Scalp indicators (M1/M5)
   hEMA_Fast_M1 = iMA(_Symbol, PERIOD_M1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M1 = iMA(_Symbol, PERIOD_M1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5      = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   hATR_M5      = iATR(_Symbol, PERIOD_M5, 14);
   
   if(hEMA_Fast_M1 == INVALID_HANDLE || hEMA_Slow_M1 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE)
   {
      Print("[ERROR] Failed to create scalp indicator handles.");
      return(INIT_FAILED);
   }
   
   Print("[INIT] All indicators initialized. EMA", EMA_Fast, "/EMA", EMA_Slow, " M1 + RSI/ATR M5");
   return(INIT_SUCCEEDED);
}

//--------------------------------------------------
void OnDeinit(const int reason)
{
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1  != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
   if(hATR_H1  != INVALID_HANDLE) IndicatorRelease(hATR_H1);
   if(hEMA_Fast_M1 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M1);
   if(hEMA_Slow_M1 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M1);
   if(hRSI_M5 != INVALID_HANDLE) IndicatorRelease(hRSI_M5);
   if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   Print("[DEINIT] EA stopped. Reason: ", reason);
}

//--------------------------------------------------
void OnTick()
{
   // Reset daily trade counter
   MqlDateTime dt;
   TimeLocal(dt);
   if(dt.day != LastTradeDay)
   {
      TodayTradeCount = 0;
      ConsecutiveLosses = 0;
      LastTradeDay = dt.day;
      Print("[DAILY] New trading day. Trade counter and loss streak reset.");
   }
   
   // Session filter
   if(UseSessionFilter && !IsAnySessionActive())
      return;
   
   // === Circuit Breaker: pause after consecutive losses ===
   if(UseCircuitBreaker && ConsecutiveLosses >= MaxConsecutiveLosses)
   {
      if(TimeCurrent() < CircuitBreaker_ResumeTime)
         return;  // Still in pause
      else
      {
         ConsecutiveLosses = 0;
         Print("[CIRCUIT BREAKER] Pause ended. Resuming trading.");
      }
   }
   
   // === Manage existing positions (trailing stop + breakeven + partial TP) ===
   if(HasPosition())
   {
      ManageOpenPosition();
      return;
   }
   
   // === Check if last trade was a loss (for circuit breaker) ===
   CheckLastTradeResult();
   
   // === Update AI bias periodically ===
   datetime currentTime = TimeCurrent();
   int elapsed = (int)(currentTime - LastAIRequest);
   if(elapsed >= Scalp_AI_RefreshSeconds)
   {
      UpdateAIBias();
      LastAIRequest = currentTime;
   }
   
   // === Fast scalp entry logic ===
   if(AI_Bias == "HOLD") return;
   if(TodayTradeCount >= Scalp_MaxTradesPerDay) return;
   
   int scalpElapsed = (int)(currentTime - LastScalpEntry);
   if(scalpElapsed < Scalp_CooldownSeconds) return;
   
   // Spread filter
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > Scalp_MaxSpreadPoints) return;
   
   // === NEWS TIME AVOIDANCE - Skip near high-impact news ===
   if(UseNewsFilter && IsNearNewsTime())
   {
      return;
   }
   
   // === ATR SPIKE PAUSE (#8) - Skip during abnormal volatility (news events) ===
   if(UseATRSpikePause && IsATRSpiking())
   {
      Print("[ATR SPIKE] Volatility abnormally high. Likely news event. Skipping entry.");
      return;
   }
   
   CheckScalpEntry();
}

//==================================================
// POSITION MANAGEMENT - TRAILING STOP & BREAKEVEN
//==================================================
void ManageOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // Get current ATR for trail distance
      double atrVal = GetATR_M5();
      double trailDistance = atrVal * Trail_ATR_Multiplier;
      
      if(type == POSITION_TYPE_BUY)
      {
         double profit = bid - openPrice;
         double profitPoints = profit / _Point;
         
         // === PARTIAL TAKE PROFIT (#1) ===
         if(UsePartialTP && !PartialTP_Done)
         {
            double atrForTP1 = GetATR_M5();
            double tp1Distance = atrForTP1 * PartialTP_ATR_Mult;
            if(profit >= tp1Distance)
            {
               double closeVolume = NormalizeDouble(PositionGetDouble(POSITION_VOLUME) * PartialTP_Percent / 100.0, 2);
               if(closeVolume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
               {
                  trade.PositionClosePartial(ticket, closeVolume);
                  PartialTP_Done = true;
                  Print("[PARTIAL TP] BUY closed ", closeVolume, " lots at profit=", DoubleToString(profitPoints, 0), "pts");
               }
            }
         }
         
         // Breakeven logic
         if(UseBreakeven && profitPoints >= Breakeven_TriggerPoints)
         {
            double beLevel = NormalizeDouble(openPrice + Breakeven_LockPoints * _Point, _Digits);
            if(currentSL < beLevel)
            {
               trade.PositionModify(ticket, beLevel, currentTP);
               Print("[BE] BUY moved SL to breakeven+", Breakeven_LockPoints, " @ ", beLevel);
            }
         }
         
         // Trailing stop logic
         if(UseTrailingStop && profit > trailDistance)
         {
            double newSL = NormalizeDouble(bid - trailDistance, _Digits);
            if(newSL > currentSL)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("[TRAIL] BUY SL moved to ", newSL, " (trail=", DoubleToString(trailDistance/_Point, 0), "pts)");
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profit = openPrice - ask;
         double profitPoints = profit / _Point;
         
         // === PARTIAL TAKE PROFIT (#1) ===
         if(UsePartialTP && !PartialTP_Done)
         {
            double atrForTP1 = GetATR_M5();
            double tp1Distance = atrForTP1 * PartialTP_ATR_Mult;
            if(profit >= tp1Distance)
            {
               double closeVolume = NormalizeDouble(PositionGetDouble(POSITION_VOLUME) * PartialTP_Percent / 100.0, 2);
               if(closeVolume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
               {
                  trade.PositionClosePartial(ticket, closeVolume);
                  PartialTP_Done = true;
                  Print("[PARTIAL TP] SELL closed ", closeVolume, " lots at profit=", DoubleToString(profitPoints, 0), "pts");
               }
            }
         }
         
         // Breakeven logic
         if(UseBreakeven && profitPoints >= Breakeven_TriggerPoints)
         {
            double beLevel = NormalizeDouble(openPrice - Breakeven_LockPoints * _Point, _Digits);
            if(currentSL > beLevel || currentSL == 0)
            {
               trade.PositionModify(ticket, beLevel, currentTP);
               Print("[BE] SELL moved SL to breakeven+", Breakeven_LockPoints, " @ ", beLevel);
            }
         }
         
         // Trailing stop logic
         if(UseTrailingStop && profit > trailDistance)
         {
            double newSL = NormalizeDouble(ask + trailDistance, _Digits);
            if(newSL < currentSL || currentSL == 0)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("[TRAIL] SELL SL moved to ", newSL, " (trail=", DoubleToString(trailDistance/_Point, 0), "pts)");
            }
         }
      }
   }
}

//==================================================
// CIRCUIT BREAKER - CHECK LAST TRADE RESULT (#2)
//==================================================
void CheckLastTradeResult()
{
   // Check recent deal history for losses
   if(!UseCircuitBreaker) return;
   
   // Look at last closed deal
   if(HistorySelect(TimeCurrent() - 86400, TimeCurrent()))  // Last 24h
   {
      int totalDeals = HistoryDealsTotal();
      if(totalDeals == 0) return;
      
      // Find the most recent deal for our symbol+magic
      for(int i = totalDeals - 1; i >= MathMax(0, totalDeals - 5); i--)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber) continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         
         double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         
         if(dealProfit < 0)
         {
            // This check runs repeatedly so we use a static to track last processed deal
            static ulong lastProcessedDeal = 0;
            if(dealTicket == lastProcessedDeal) return;
            lastProcessedDeal = dealTicket;
            
            ConsecutiveLosses++;
            Print("[CIRCUIT BREAKER] Loss detected. Streak: ", ConsecutiveLosses, "/", MaxConsecutiveLosses);
            
            if(ConsecutiveLosses >= MaxConsecutiveLosses)
            {
               CircuitBreaker_ResumeTime = TimeCurrent() + CircuitBreaker_PauseMin * 60;
               Print("[CIRCUIT BREAKER] ", MaxConsecutiveLosses, " consecutive losses! Pausing for ", CircuitBreaker_PauseMin, " minutes.");
            }
         }
         else if(dealProfit > 0)
         {
            static ulong lastWinDeal = 0;
            if(dealTicket == lastWinDeal) return;
            lastWinDeal = dealTicket;
            
            ConsecutiveLosses = 0;  // Reset on win
         }
         return;  // Only check most recent deal
      }
   }
}

//==================================================
// AI BIAS UPDATE
//==================================================
void UpdateAIBias()
{
   Print("[AI] --- Updating Directional Bias ---");
   
   string prompt = BuildAIPrompt();
   string raw = OpenAIRequest(prompt);
   
   if(raw != "")
   {
      int confidence = 0;
      string signal = ExtractOpenAIText(raw, confidence);
      
      // === ADAPTIVE CONFIDENCE (#9) ===
      int activeThreshold = GetAdaptiveConfidence();
      
      if(confidence >= activeThreshold)
      {
         AI_Bias = signal;
         AI_Confidence = confidence;
         Print("[AI] Bias: ", AI_Bias, " | Confidence: ", AI_Confidence, " | Threshold: ", activeThreshold);
      }
      else
      {
         AI_Bias = "HOLD";
         AI_Confidence = confidence;
         Print("[AI] Low confidence (", confidence, " < ", activeThreshold, "). Bias -> HOLD.");
      }
   }
   else
   {
      Print("[AI] API failed. Keeping bias: ", AI_Bias);
   }
}

//==================================================
// SCALP ENTRY - STRICTER CONDITIONS
//==================================================
void CheckScalpEntry()
{
   // Get EMA values on M1 (need 3 bars for crossover detection)
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   CopyBuffer(hEMA_Fast_M1, 0, 0, 3, emaFast);
   CopyBuffer(hEMA_Slow_M1, 0, 0, 3, emaSlow);
   
   // Get RSI on M5 (2 bars for momentum direction)
   double rsi[];
   ArraySetAsSeries(rsi, true);
   CopyBuffer(hRSI_M5, 0, 0, 3, rsi);
   double currentRSI = rsi[0];
   double prevRSI = rsi[1];
   
   // EMA crossover detection ONLY (removed loose "alignment" trigger)
   bool emaBullishCross = (emaFast[1] > emaSlow[1]) && (emaFast[2] <= emaSlow[2]);
   bool emaBearishCross = (emaFast[1] < emaSlow[1]) && (emaFast[2] >= emaSlow[2]);
   
   // === MOMENTUM ACCELERATION CHECK (#4) ===
   // EMA gap must be widening (accelerating, not decelerating)
   if(RequireMomentumAccel)
   {
      double currentGap = emaFast[0] - emaSlow[0];
      double prevGap = emaFast[1] - emaSlow[1];
      
      // For BUY: gap should be positive and widening
      if(AI_Bias == "BUY" && emaBullishCross)
      {
         if(MathAbs(currentGap) <= MathAbs(prevGap))
         {
            return;  // Momentum decelerating - skip
         }
      }
      // For SELL: gap should be negative and widening
      if(AI_Bias == "SELL" && emaBearishCross)
      {
         if(MathAbs(currentGap) <= MathAbs(prevGap))
         {
            return;  // Momentum decelerating - skip
         }
      }
   }
   
   // === VOLUME SPIKE CHECK (#6) ===
   // Tick volume on crossover candle must exceed average
   if(RequireVolSpike)
   {
      MqlRates volRates[];
      ArraySetAsSeries(volRates, true);
      CopyRates(_Symbol, PERIOD_M1, 0, 22, volRates);  // 20 bars + current + trigger bar
      
      long triggerVolume = volRates[1].tick_volume;  // Volume of the crossover candle
      
      // Calculate 20-bar average volume (bars 2-21)
      long totalVol = 0;
      for(int v = 2; v < 22; v++)
         totalVol += volRates[v].tick_volume;
      double avgVolume = (double)totalVol / 20.0;
      
      if(triggerVolume < avgVolume * VolSpike_Multiplier)
      {
         return;  // Low volume crossover - likely fake
      }
   }
   
   // === CANDLE BODY CHECK - skip doji/indecision candles ===
   MqlRates m1Rates[];
   ArraySetAsSeries(m1Rates, true);
   CopyRates(_Symbol, PERIOD_M1, 0, 2, m1Rates);
   double candleBody = MathAbs(m1Rates[1].close - m1Rates[1].open) / _Point;
   
   if(candleBody < MinCandleBodyPoints)
      return;  // Skip tiny candles - no conviction
   
   // === SCALP BUY ===
   if(AI_Bias == "BUY" && emaBullishCross)
   {
      // RSI must not be overbought
      if(currentRSI > RSI_OverboughtLimit) return;
      
      // RSI momentum check: RSI should be rising for BUY
      if(RequireRSIMomentum && currentRSI <= prevRSI) return;
      
      // Candle should be bullish (close > open)
      if(m1Rates[1].close <= m1Rates[1].open) return;
      
      Print("[SCALP] BUY entry confirmed. Cross=true RSI=", DoubleToString(currentRSI, 2),
            " RSI_rising=true Body=", DoubleToString(candleBody, 0), "pts Bias=", AI_Bias, "(", AI_Confidence, ")");
      OpenScalpBuy();
   }
   
   // === SCALP SELL ===
   if(AI_Bias == "SELL" && emaBearishCross)
   {
      // RSI must not be oversold
      if(currentRSI < RSI_OversoldLimit) return;
      
      // RSI momentum check: RSI should be falling for SELL
      if(RequireRSIMomentum && currentRSI >= prevRSI) return;
      
      // Candle should be bearish (close < open)
      if(m1Rates[1].close >= m1Rates[1].open) return;
      
      Print("[SCALP] SELL entry confirmed. Cross=true RSI=", DoubleToString(currentRSI, 2),
            " RSI_falling=true Body=", DoubleToString(candleBody, 0), "pts Bias=", AI_Bias, "(", AI_Confidence, ")");
      OpenScalpSell();
   }
}

//==================================================
// NEWS TIME AVOIDANCE
//==================================================
bool IsNearNewsTime()
{
   MqlDateTime dt;
   TimeLocal(dt);  // IST
   int currentMinuteOfDay = dt.hour * 60 + dt.min;  // Convert to minutes since midnight
   
   // Parse the news times string
   string timeEntries[];
   int count = StringSplit(NewsTimesIST, ',', timeEntries);
   
   for(int i = 0; i < count; i++)
   {
      StringTrimLeft(timeEntries[i]);
      StringTrimRight(timeEntries[i]);
      
      int hhmm = (int)StringToInteger(timeEntries[i]);
      int newsHour = hhmm / 100;
      int newsMin = hhmm % 100;
      int newsMinuteOfDay = newsHour * 60 + newsMin;
      
      // Calculate distance in minutes (handle midnight wrap)
      int diff = currentMinuteOfDay - newsMinuteOfDay;
      
      // Handle wrap-around (e.g., current=23:55, news=00:00)
      if(diff > 720) diff -= 1440;   // 720 = half day
      if(diff < -720) diff += 1440;
      
      // Check if within pause window
      if(diff >= -News_PauseBeforeMin && diff <= News_PauseAfterMin)
      {
         Print("[NEWS FILTER] Near high-impact news time ", timeEntries[i], 
               " IST. Pausing entries (", diff, " min from news).");
         return true;
      }
   }
   
   return false;
}

//==================================================
// ATR SPIKE DETECTION (#8)
//==================================================
bool IsATRSpiking()
{
   // Compare current M5 ATR to its 20-bar average
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR_M5, 0, 0, 21, atrBuf) < 21) return false;
   
   double currentATR = atrBuf[0];
   
   // Calculate 20-bar average ATR (bars 1-20)
   double totalATR = 0;
   for(int i = 1; i <= 20; i++)
      totalATR += atrBuf[i];
   double avgATR = totalATR / 20.0;
   
   if(currentATR > avgATR * ATR_Spike_Multiplier)
   {
      Print("[ATR SPIKE] Current ATR=", DoubleToString(currentATR/_Point, 0), 
            "pts vs Avg=", DoubleToString(avgATR/_Point, 0), 
            "pts (", DoubleToString(currentATR/avgATR, 1), "x)");
      return true;
   }
   return false;
}

//==================================================
// ADAPTIVE CONFIDENCE THRESHOLD (#9)
//==================================================
int GetAdaptiveConfidence()
{
   if(!UseAdaptiveConfidence)
      return ConfidenceThreshold;  // Use fixed threshold if disabled
   
   MqlDateTime dt;
   TimeLocal(dt);
   int hour = dt.hour;
   
   bool isLondon = IsWithinSession(hour, London_StartHour, London_EndHour);
   bool isNY = IsWithinSession(hour, NY_StartHour, NY_EndHour);
   bool isTokyo = IsWithinSession(hour, Tokyo_StartHour, Tokyo_EndHour);
   bool isSydney = IsWithinSession(hour, Sydney_StartHour, Sydney_EndHour);
   
   // London-NY overlap = highest quality setups, can be more lenient
   if(isLondon && isNY) return Confidence_HighVol;
   
   // Single high-vol session = moderate
   if(isLondon || isNY) return Confidence_MedVol;
   
   // Tokyo-London overlap = moderate
   if(isTokyo && isLondon) return Confidence_MedVol;
   
   // Tokyo alone = moderate
   if(isTokyo) return Confidence_MedVol;
   
   // Sydney or off-market = strict (only trade the best signals)
   return Confidence_LowVol;
}

//==================================================
// ATR-BASED DYNAMIC SL/TP CALCULATION
//==================================================
double GetATR_M5()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 100 * _Point;
   return atr[0];
}

//--------------------------------------------------
void CalculateDynamicSLTP(double &sl_distance, double &tp_distance)
{
   double atr = GetATR_M5();
   
   // SL = ATR * multiplier (clamped to min/max)
   sl_distance = atr * ATR_SL_Multiplier;
   double minSL = Scalp_MinSL_Points * _Point;
   double maxSL = Scalp_MaxSL_Points * _Point;
   
   if(sl_distance < minSL) sl_distance = minSL;
   if(sl_distance > maxSL) sl_distance = maxSL;
   
   // TP = ATR * multiplier (always bigger than SL for positive R:R)
   tp_distance = atr * ATR_TP_Multiplier;
   
   // Ensure TP is always at least 1.5x SL
   if(tp_distance < sl_distance * 1.5)
      tp_distance = sl_distance * 1.5;
   
   Print("[SL/TP] ATR=", DoubleToString(atr/_Point, 0), "pts | SL=", 
         DoubleToString(sl_distance/_Point, 0), "pts | TP=", DoubleToString(tp_distance/_Point, 0), 
         "pts | R:R=1:", DoubleToString(tp_distance/sl_distance, 1));
}

//==================================================
// TRADE EXECUTION WITH DYNAMIC SL/TP
//==================================================
void OpenScalpBuy()
{
   double sl_dist, tp_dist;
   CalculateDynamicSLTP(sl_dist, tp_dist);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - sl_dist, _Digits);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);

   if(!trade.Buy(LotSize, _Symbol, ask, sl, tp, "Scalp BUY"))
   {
      Print("[ERROR] Scalp BUY failed. Code: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[TRADE] Scalp BUY @ ", ask, " SL:", sl, " TP:", tp, " #", trade.ResultOrder());
      LastScalpEntry = TimeCurrent();
      TodayTradeCount++;
      PartialTP_Done = false;  // Reset partial TP flag for new trade
   }
}

//--------------------------------------------------
void OpenScalpSell()
{
   double sl_dist, tp_dist;
   CalculateDynamicSLTP(sl_dist, tp_dist);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + sl_dist, _Digits);
   double tp = NormalizeDouble(bid - tp_dist, _Digits);

   if(!trade.Sell(LotSize, _Symbol, bid, sl, tp, "Scalp SELL"))
   {
      Print("[ERROR] Scalp SELL failed. Code: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[TRADE] Scalp SELL @ ", bid, " SL:", sl, " TP:", tp, " #", trade.ResultOrder());
      LastScalpEntry = TimeCurrent();
      TodayTradeCount++;
      PartialTP_Done = false;  // Reset partial TP flag for new trade
   }
}

//==================================================
// POSITION MANAGEMENT HELPERS
//==================================================
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   }
   return false;
}

//--------------------------------------------------
ENUM_POSITION_TYPE CurrentPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   }
   return WRONG_VALUE;
}

//--------------------------------------------------
bool CloseAllPositions()
{
   bool success = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            if(!trade.PositionClose(PositionGetInteger(POSITION_TICKET)))
               success = false;
   }
   return success;
}

//==================================================
// INDICATOR HELPERS
//==================================================
double GetRSI_H1()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hRSI_H1, 0, 0, 1, buf) <= 0) return 50.0;
   return buf[0];
}

//==================================================
// SESSION FILTER (IST)
//==================================================
bool IsWithinSession(int currentHour, int startHour, int endHour)
{
   if(startHour > endHour)
      return (currentHour >= startHour || currentHour < endHour);
   else
      return (currentHour >= startHour && currentHour < endHour);
}

//--------------------------------------------------
bool IsAnySessionActive()
{
   MqlDateTime dt;
   TimeLocal(dt);
   int hour = dt.hour;
   return (IsWithinSession(hour, Sydney_StartHour, Sydney_EndHour) ||
           IsWithinSession(hour, Tokyo_StartHour, Tokyo_EndHour) ||
           IsWithinSession(hour, London_StartHour, London_EndHour) ||
           IsWithinSession(hour, NY_StartHour, NY_EndHour));
}

//--------------------------------------------------
string GetCurrentSession()
{
   MqlDateTime dt;
   TimeLocal(dt);
   int hour = dt.hour;
   string sessions = "";
   if(IsWithinSession(hour, Sydney_StartHour, Sydney_EndHour))
   { if(sessions != "") sessions += "+"; sessions += "SYDNEY"; }
   if(IsWithinSession(hour, Tokyo_StartHour, Tokyo_EndHour))
   { if(sessions != "") sessions += "+"; sessions += "TOKYO"; }
   if(IsWithinSession(hour, London_StartHour, London_EndHour))
   { if(sessions != "") sessions += "+"; sessions += "LONDON"; }
   if(IsWithinSession(hour, NY_StartHour, NY_EndHour))
   { if(sessions != "") sessions += "+"; sessions += "NEW YORK"; }
   if(sessions == "") sessions = "OFF-MARKET";
   return sessions;
}

//--------------------------------------------------
string GetSessionVolatility()
{
   MqlDateTime dt;
   TimeLocal(dt);
   int hour = dt.hour;
   bool isLondon = IsWithinSession(hour, London_StartHour, London_EndHour);
   bool isNY = IsWithinSession(hour, NY_StartHour, NY_EndHour);
   bool isTokyo = IsWithinSession(hour, Tokyo_StartHour, Tokyo_EndHour);
   bool isSydney = IsWithinSession(hour, Sydney_StartHour, Sydney_EndHour);
   if(isLondon && isNY) return "VERY HIGH (London-NY overlap)";
   if(isTokyo && isLondon) return "HIGH (Tokyo-London overlap)";
   if(isLondon) return "HIGH (London)";
   if(isNY) return "HIGH (New York)";
   if(isTokyo) return "MODERATE (Tokyo)";
   if(isSydney) return "LOW (Sydney)";
   return "VERY LOW (off-market)";
}

//==================================================
// AI PROMPT & API
//==================================================
string BuildAIPrompt()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask - bid) / _Point;

   double ma20[], ma50[];
   ArraySetAsSeries(ma20, true);
   ArraySetAsSeries(ma50, true);
   CopyBuffer(hMA20_H1, 0, 0, 3, ma20);
   CopyBuffer(hMA50_H1, 0, 0, 3, ma50);

   double rsiH1[];
   ArraySetAsSeries(rsiH1, true);
   CopyBuffer(hRSI_H1, 0, 0, 5, rsiH1);

   double atr[];
   ArraySetAsSeries(atr, true);
   CopyBuffer(hATR_H1, 0, 0, 1, atr);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   CopyRates(_Symbol, PERIOD_H1, 0, 10, rates);

   string candles = "";
   for(int i = 0; i < 10; i++)
   {
      candles += "H1[" + IntegerToString(i) + "] O=" + DoubleToString(rates[i].open, _Digits)
               + " H=" + DoubleToString(rates[i].high, _Digits)
               + " L=" + DoubleToString(rates[i].low, _Digits)
               + " C=" + DoubleToString(rates[i].close, _Digits) + "\\n";
   }

   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   CopyRates(_Symbol, PERIOD_D1, 0, 1, daily);

   string maTrend = "NEUTRAL";
   if(ma20[0] > ma50[0]) maTrend = "BULLISH";
   else if(ma20[0] < ma50[0]) maTrend = "BEARISH";

   string rsiHistory = "";
   for(int j = 4; j >= 0; j--)
   {
      rsiHistory += DoubleToString(rsiH1[j], 2);
      if(j > 0) rsiHistory += ", ";
   }

   string rsiTrend = "FLAT";
   if(rsiH1[0] > rsiH1[1] && rsiH1[1] > rsiH1[2]) rsiTrend = "RISING";
   else if(rsiH1[0] < rsiH1[1] && rsiH1[1] < rsiH1[2]) rsiTrend = "FALLING";

   string posStatus = "FLAT";
   if(HasPosition())
      posStatus = (CurrentPositionType() == POSITION_TYPE_BUY) ? "LONG" : "SHORT";

   string session = GetCurrentSession();
   string volatility = GetSessionVolatility();

   string prompt =
      "=== SCALPING BIAS REQUEST ===\\n"
      "Symbol: " + _Symbol + "\\n" +
      "Bid: " + DoubleToString(bid, _Digits) + " | Ask: " + DoubleToString(ask, _Digits) + "\\n" +
      "Spread: " + DoubleToString(spread, 1) + " pts\\n" +
      "\\n=== H1 INDICATORS ===\\n" +
      "MA20: " + DoubleToString(ma20[0], _Digits) + " | MA50: " + DoubleToString(ma50[0], _Digits) + "\\n" +
      "Trend: " + maTrend + "\\n" +
      "RSI(14) Current: " + DoubleToString(rsiH1[0], 2) + "\\n" +
      "RSI History [old->new]: [" + rsiHistory + "]\\n" +
      "RSI Trend: " + rsiTrend + "\\n" +
      "ATR(14): " + DoubleToString(atr[0], _Digits) + "\\n" +
      "\\n=== DIVERGENCE ===\\n" +
      "Price higher highs + RSI lower highs = BEARISH DIVERGENCE -> SELL\\n" +
      "Price lower lows + RSI higher lows = BULLISH DIVERGENCE -> BUY\\n" +
      "\\n=== LEVELS ===\\n" +
      "Daily High: " + DoubleToString(daily[0].high, _Digits) + "\\n" +
      "Daily Low: " + DoubleToString(daily[0].low, _Digits) + "\\n" +
      "\\n=== H1 CANDLES ===\\n" + candles +
      "\\n=== CONTEXT ===\\n" +
      "Position: " + posStatus + "\\n" +
      "Session: " + session + " | Volatility: " + volatility + "\\n" +
      "\\n=== REPLY FORMAT ===\\n" +
      "SIGNAL CONFIDENCE (e.g. BUY 82)\\n" +
      "BUY / SELL / HOLD + number 0-100. One line only.";

   return prompt;
}

//--------------------------------------------------
string OpenAIRequest(string prompt)
{
   string url = "https://api.openai.com/v1/chat/completions";
   StringReplace(prompt, "\"", "'");
   
   string systemPrompt = 
      "You are an expert XAUUSD scalping bias analyst.\\n"
      "You provide DIRECTIONAL BIAS for a scalping system using EMA9/21 on M1.\\n"
      "The scalper only takes trades in YOUR direction.\\n\\n"
      "Rules:\\n"
      "- Reply: SIGNAL CONFIDENCE (e.g. BUY 82)\\n"
      "- BUY = bullish bias\\n"
      "- SELL = bearish bias\\n"
      "- HOLD = no clear direction, stand aside\\n"
      "- Analyze: MA trend, RSI momentum + divergence, price action, session volatility\\n"
      "- Bearish divergence (price higher highs + RSI lower highs) = SELL\\n"
      "- Bullish divergence (price lower lows + RSI higher lows) = BUY\\n"
      "- RSI > 70 = cautious about BUY. RSI < 30 = cautious about SELL\\n"
      "- Low volatility (Sydney alone) = prefer HOLD\\n"
      "- CONFIDENCE: 85+ strong, 70-84 moderate, <70 weak\\n"
      "- One line only. No explanation.";

   string body = "{\"model\":\"" + OpenAI_Model + "\","
                 "\"messages\":[{\"role\":\"system\",\"content\":\"" + systemPrompt + "\"},"
                 "{\"role\":\"user\",\"content\":\"" + prompt + "\"}],"
                 "\"max_tokens\":10,\"temperature\":0.0}";

   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);

   char result[];
   string result_headers;
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + OpenAI_ApiKey + "\r\n";

   ResetLastError();
   int responseCode = WebRequest("POST", url, headers, 30000, post, result, result_headers);

   if(responseCode == -1)
   {
      Print("[API ERROR] WebRequest failed. Error: ", GetLastError());
      return "";
   }

   string rawResult = CharArrayToString(result);
   if(responseCode != 200)
      Print("[API ERROR] HTTP ", responseCode, ": ", rawResult);
   return rawResult;
}

//--------------------------------------------------
string ExtractOpenAIText(string jsonText, int &confidence)
{
   CJAVal json;
   confidence = 0;

   if(!json.Deserialize(jsonText))
   {
      Print("[API ERROR] JSON parse failed.");
      return "HOLD";
   }

   string text = json["choices"][0]["message"]["content"].ToStr();
   StringTrimLeft(text);
   StringTrimRight(text);
   StringToUpper(text);

   string signal = "HOLD";
   if(StringFind(text, "BUY") >= 0) signal = "BUY";
   else if(StringFind(text, "SELL") >= 0) signal = "SELL";

   string parts[];
   int numParts = StringSplit(text, ' ', parts);
   
   if(numParts >= 2)
   {
      int parsed = (int)StringToInteger(parts[1]);
      if(parsed > 0 && parsed <= 100)
         confidence = parsed;
      else
      {
         parsed = (int)StringToInteger(parts[numParts - 1]);
         if(parsed > 0 && parsed <= 100)
            confidence = parsed;
         else
            confidence = 50;
      }
   }
   else
      confidence = 50;

   return signal;
}
