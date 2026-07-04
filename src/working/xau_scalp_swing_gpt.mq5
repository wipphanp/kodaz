//+------------------------------------------------------------------+
//|                                          xau_scalp_swing_gpt.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== MODE SELECTION ===
enum ENUM_TRADE_MODE
{
   MODE_SWING = 0,     // Swing Trading (AI decides every trade)
   MODE_SCALP = 1      // Scalping (AI bias + fast EMA entries)
};
input ENUM_TRADE_MODE TradeMode = MODE_SCALP;

//=== COMMON PARAMETERS ===
input double LotSize = 0.10;
input long MagicNumber = 20260606;
input string OpenAI_ApiKey = "";
input string OpenAI_Model = "gpt-4o-mini";
input int ConfidenceThreshold = 70;

//=== SWING MODE PARAMETERS ===
input int Swing_SL_Points = 1000;
input int Swing_TP_Points = 2000;
input int Swing_RefreshSeconds = 300;

//=== SCALP MODE PARAMETERS ===
input int Scalp_SL_Points = 80;
input int Scalp_TP_Points = 120;
input int Scalp_AI_RefreshSeconds = 300;
input int Scalp_CooldownSeconds = 30;
input int Scalp_MaxTradesPerDay = 30;
input double Scalp_MaxSpreadPoints = 35.0;
input int EMA_Fast = 9;
input int EMA_Slow = 21;

//=== RSI FILTER PARAMETERS ===
input int RSI_Period = 14;
input double RSI_OverboughtLimit = 75.0;
input double RSI_OversoldLimit = 25.0;

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

//=== INDICATOR HANDLES ===
// Scalp indicators (M1/M5)
int hEMA_Fast_M1, hEMA_Slow_M1;
int hRSI_M5;
int hATR_M5;
// Swing/AI indicators (H1)
int hMA20_H1, hMA50_H1;
int hRSI_H1;
int hATR_H1;

//--------------------------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   Print("[INIT] EA started. Mode: ", EnumToString(TradeMode), " | Magic: ", MagicNumber);
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("[WARNING] Automated trading is disabled. Enable 'Allow Algo Trading'.");
   }
   
   // H1 indicators (used by both modes for AI prompt)
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
   
   // Scalp-specific indicators (M1/M5)
   if(TradeMode == MODE_SCALP)
   {
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
      Print("[INIT] Scalp indicators: EMA", EMA_Fast, "/EMA", EMA_Slow, " M1 + RSI M5");
   }
   
   Print("[INIT] All indicators initialized successfully.");
   return(INIT_SUCCEEDED);
}

//--------------------------------------------------
void OnDeinit(const int reason)
{
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1  != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
   if(hATR_H1  != INVALID_HANDLE) IndicatorRelease(hATR_H1);
   
   if(TradeMode == MODE_SCALP)
   {
      if(hEMA_Fast_M1 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M1);
      if(hEMA_Slow_M1 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M1);
      if(hRSI_M5 != INVALID_HANDLE) IndicatorRelease(hRSI_M5);
      if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   }
   
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
      LastTradeDay = dt.day;
      Print("[DAILY] New trading day. Trade counter reset.");
   }
   
   // Session filter
   if(UseSessionFilter && !IsAnySessionActive())
      return;
   
   // Route to appropriate mode
   if(TradeMode == MODE_SWING)
      OnTick_Swing();
   else
      OnTick_Scalp();
}

//==================================================
// SWING MODE - AI decides every trade
//==================================================
void OnTick_Swing()
{
   datetime currentTime = TimeCurrent();
   int elapsed = (int)(currentTime - LastAIRequest);
   
   if(elapsed < Swing_RefreshSeconds)
      return;

   Print("[SWING] --- New Analysis Cycle ---");
   LastAIRequest = currentTime;

   string prompt = BuildAIPrompt();
   string raw = OpenAIRequest(prompt);
   if(raw == "")
   {
      Print("[SWING ERROR] Empty API response. Aborting.");
      return;
   }

   int confidence = 0;
   string signal = ExtractOpenAIText(raw, confidence);
   Print("[SWING] Signal: ", signal, " | Confidence: ", confidence);

   if(confidence < ConfidenceThreshold)
   {
      Print("[SWING] Confidence below threshold. Treating as HOLD.");
      return;
   }

   // RSI safety filter
   double currentRSI = GetRSI_H1();
   StringToUpper(signal);
   
   if(signal == "BUY" && currentRSI > RSI_OverboughtLimit)
   {
      Print("[SWING FILTER] BUY blocked. RSI=", DoubleToString(currentRSI, 2), " > ", RSI_OverboughtLimit);
      return;
   }
   if(signal == "SELL" && currentRSI < RSI_OversoldLimit)
   {
      Print("[SWING FILTER] SELL blocked. RSI=", DoubleToString(currentRSI, 2), " < ", RSI_OversoldLimit);
      return;
   }

   ExecuteSwingSignal(signal);
}

//==================================================
// SCALP MODE - AI sets bias, EMA crossover enters
//==================================================
void OnTick_Scalp()
{
   datetime currentTime = TimeCurrent();
   
   // === Update AI bias periodically ===
   int elapsed = (int)(currentTime - LastAIRequest);
   if(elapsed >= Scalp_AI_RefreshSeconds)
   {
      Print("[SCALP AI] --- Updating Directional Bias ---");
      LastAIRequest = currentTime;
      
      string prompt = BuildAIPrompt();
      string raw = OpenAIRequest(prompt);
      
      if(raw != "")
      {
         int confidence = 0;
         string signal = ExtractOpenAIText(raw, confidence);
         
         if(confidence >= ConfidenceThreshold)
         {
            AI_Bias = signal;
            AI_Confidence = confidence;
            Print("[SCALP AI] Bias: ", AI_Bias, " | Confidence: ", AI_Confidence);
         }
         else
         {
            AI_Bias = "HOLD";
            AI_Confidence = confidence;
            Print("[SCALP AI] Low confidence (", confidence, "). Bias -> HOLD.");
         }
      }
      else
      {
         Print("[SCALP AI] API failed. Keeping bias: ", AI_Bias);
      }
   }
   
   // === Fast scalp entry logic (every tick) ===
   
   // Skip if HOLD
   if(AI_Bias == "HOLD")
      return;
   
   // Max trades limit
   if(TodayTradeCount >= Scalp_MaxTradesPerDay)
      return;
   
   // Already in position
   if(HasPosition())
      return;
   
   // Cooldown between scalps
   int scalpElapsed = (int)(currentTime - LastScalpEntry);
   if(scalpElapsed < Scalp_CooldownSeconds)
      return;
   
   // Spread filter
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > Scalp_MaxSpreadPoints)
      return;
   
   // === EMA crossover + RSI check ===
   CheckScalpEntry();
}

//--------------------------------------------------
void CheckScalpEntry()
{
   // Get EMA values on M1 (current, prev, prev-prev)
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   CopyBuffer(hEMA_Fast_M1, 0, 0, 3, emaFast);
   CopyBuffer(hEMA_Slow_M1, 0, 0, 3, emaSlow);
   
   // Get RSI on M5
   double rsi[];
   ArraySetAsSeries(rsi, true);
   CopyBuffer(hRSI_M5, 0, 0, 2, rsi);
   double currentRSI = rsi[0];
   
   // EMA crossover detection
   bool emaBullishCross = (emaFast[1] > emaSlow[1]) && (emaFast[2] <= emaSlow[2]);
   bool emaBearishCross = (emaFast[1] < emaSlow[1]) && (emaFast[2] >= emaSlow[2]);
   
   // EMA alignment
   bool emaAlignedBullish = (emaFast[0] > emaSlow[0]);
   bool emaAlignedBearish = (emaFast[0] < emaSlow[0]);
   
   // === SCALP BUY ===
   if(AI_Bias == "BUY")
   {
      if(currentRSI > RSI_OverboughtLimit) return;
      
      bool trigger = emaBullishCross || (emaAlignedBullish && currentRSI > 40 && currentRSI < 65);
      if(trigger)
      {
         Print("[SCALP] BUY trigger. Cross=", emaBullishCross, " Aligned=", emaAlignedBullish, 
               " RSI=", DoubleToString(currentRSI, 2), " Bias=", AI_Bias, "(", AI_Confidence, ")");
         OpenScalpBuy();
      }
   }
   
   // === SCALP SELL ===
   if(AI_Bias == "SELL")
   {
      if(currentRSI < RSI_OversoldLimit) return;
      
      bool trigger = emaBearishCross || (emaAlignedBearish && currentRSI > 35 && currentRSI < 60);
      if(trigger)
      {
         Print("[SCALP] SELL trigger. Cross=", emaBearishCross, " Aligned=", emaAlignedBearish,
               " RSI=", DoubleToString(currentRSI, 2), " Bias=", AI_Bias, "(", AI_Confidence, ")");
         OpenScalpSell();
      }
   }
}

//==================================================
// TRADE EXECUTION FUNCTIONS
//==================================================
void OpenScalpBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - Scalp_SL_Points * _Point, _Digits);
   double tp = NormalizeDouble(ask + Scalp_TP_Points * _Point, _Digits);

   if(!trade.Buy(LotSize, _Symbol, ask, sl, tp, "Scalp BUY"))
   {
      Print("[ERROR] Scalp BUY failed. Code: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[TRADE] Scalp BUY @ ", ask, " SL:", sl, " TP:", tp, " #", trade.ResultOrder());
      LastScalpEntry = TimeCurrent();
      TodayTradeCount++;
   }
}

//--------------------------------------------------
void OpenScalpSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + Scalp_SL_Points * _Point, _Digits);
   double tp = NormalizeDouble(bid - Scalp_TP_Points * _Point, _Digits);

   if(!trade.Sell(LotSize, _Symbol, bid, sl, tp, "Scalp SELL"))
   {
      Print("[ERROR] Scalp SELL failed. Code: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[TRADE] Scalp SELL @ ", bid, " SL:", sl, " TP:", tp, " #", trade.ResultOrder());
      LastScalpEntry = TimeCurrent();
      TodayTradeCount++;
   }
}

//--------------------------------------------------
void OpenSwingBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = (Swing_SL_Points > 0) ? NormalizeDouble(ask - Swing_SL_Points * _Point, _Digits) : 0;
   double tp = (Swing_TP_Points > 0) ? NormalizeDouble(ask + Swing_TP_Points * _Point, _Digits) : 0;

   if(!trade.Buy(LotSize, _Symbol, ask, sl, tp, "Swing BUY"))
   {
      Print("[ERROR] Swing BUY failed. Code: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[TRADE] Swing BUY @ ", ask, " SL:", sl, " TP:", tp, " #", trade.ResultOrder());
      TodayTradeCount++;
   }
}

//--------------------------------------------------
void OpenSwingSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (Swing_SL_Points > 0) ? NormalizeDouble(bid + Swing_SL_Points * _Point, _Digits) : 0;
   double tp = (Swing_TP_Points > 0) ? NormalizeDouble(bid - Swing_TP_Points * _Point, _Digits) : 0;

   if(!trade.Sell(LotSize, _Symbol, bid, sl, tp, "Swing SELL"))
   {
      Print("[ERROR] Swing SELL failed. Code: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[TRADE] Swing SELL @ ", bid, " SL:", sl, " TP:", tp, " #", trade.ResultOrder());
      TodayTradeCount++;
   }
}

//--------------------------------------------------
void ExecuteSwingSignal(string signal)
{
   StringToUpper(signal);
   Print("[SWING] Executing signal: ", signal);

   if(signal == "BUY")
   {
      if(!HasPosition())
      {
         OpenSwingBuy();
         return;
      }
      if(CurrentPositionType() == POSITION_TYPE_SELL)
      {
         CloseAllPositions();
         Sleep(1000);
         OpenSwingBuy();
      }
      return;
   }

   if(signal == "SELL")
   {
      if(!HasPosition())
      {
         OpenSwingSell();
         return;
      }
      if(CurrentPositionType() == POSITION_TYPE_BUY)
      {
         CloseAllPositions();
         Sleep(1000);
         OpenSwingSell();
      }
      return;
   }
}

//==================================================
// POSITION MANAGEMENT
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
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
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
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            if(!trade.PositionClose(ticket))
               success = false;
         }
      }
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

   // H1 MAs
   double ma20[], ma50[];
   ArraySetAsSeries(ma20, true);
   ArraySetAsSeries(ma50, true);
   CopyBuffer(hMA20_H1, 0, 0, 3, ma20);
   CopyBuffer(hMA50_H1, 0, 0, 3, ma50);

   // H1 RSI history (5 bars)
   double rsiH1[];
   ArraySetAsSeries(rsiH1, true);
   CopyBuffer(hRSI_H1, 0, 0, 5, rsiH1);

   // ATR
   double atr[];
   ArraySetAsSeries(atr, true);
   CopyBuffer(hATR_H1, 0, 0, 1, atr);

   // Last 10 H1 candles
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

   // Daily S/R
   MqlRates daily[];
   ArraySetAsSeries(daily, true);
   CopyRates(_Symbol, PERIOD_D1, 0, 1, daily);

   // MA trend
   string maTrend = "NEUTRAL";
   if(ma20[0] > ma50[0]) maTrend = "BULLISH";
   else if(ma20[0] < ma50[0]) maTrend = "BEARISH";

   // RSI history string (oldest->newest)
   string rsiHistory = "";
   for(int j = 4; j >= 0; j--)
   {
      rsiHistory += DoubleToString(rsiH1[j], 2);
      if(j > 0) rsiHistory += ", ";
   }

   // RSI trend
   string rsiTrend = "FLAT";
   if(rsiH1[0] > rsiH1[1] && rsiH1[1] > rsiH1[2]) rsiTrend = "RISING";
   else if(rsiH1[0] < rsiH1[1] && rsiH1[1] < rsiH1[2]) rsiTrend = "FALLING";

   // Position status
   string posStatus = "FLAT";
   if(HasPosition())
      posStatus = (CurrentPositionType() == POSITION_TYPE_BUY) ? "LONG" : "SHORT";

   string session = GetCurrentSession();
   string volatility = GetSessionVolatility();
   string modeStr = (TradeMode == MODE_SCALP) ? "SCALPING BIAS" : "SWING SIGNAL";

   string prompt =
      "=== " + modeStr + " REQUEST ===\\n"
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
   
   string modeContext = "";
   if(TradeMode == MODE_SCALP)
      modeContext = "You provide DIRECTIONAL BIAS for a scalping system using EMA9/21 on M1. "
                    "The scalper only takes trades in YOUR direction.\\n";
   else
      modeContext = "You provide direct trade signals for a swing trading system on H1.\\n";
   
   string systemPrompt = 
      "You are an expert XAUUSD trading analyst.\\n" + modeContext +
      "Rules:\\n"
      "- Reply: SIGNAL CONFIDENCE (e.g. BUY 82)\\n"
      "- BUY = bullish bias/signal\\n"
      "- SELL = bearish bias/signal\\n"
      "- HOLD = no clear direction, stand aside\\n"
      "- Analyze: MA trend, RSI momentum + divergence, price action, session volatility\\n"
      "- Bearish divergence (price higher highs + RSI lower highs) = SELL\\n"
      "- Bullish divergence (price lower lows + RSI higher lows) = BUY\\n"
      "- RSI > 75 = cautious about BUY. RSI < 25 = cautious about SELL\\n"
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

   // Parse signal
   string signal = "HOLD";
   if(StringFind(text, "BUY") >= 0) signal = "BUY";
   else if(StringFind(text, "SELL") >= 0) signal = "SELL";

   // Parse confidence
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

