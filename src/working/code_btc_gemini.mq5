//+------------------------------------------------------------------+
//|                                                  code_gemini.mq5 |
//|                        BTC Scalping EA - Gemini AI Enhanced       |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//--- Symbol & Core Settings
input string TradeSymbol = "BTCUSDT";        // BTC symbol on your broker
input double LotSize = 0.05;                // Position size
input int StopLossPoints = 5000;            // Initial SL distance
input int TakeProfitPoints = 7500;          // TP distance
input int RefreshSeconds = 15;              // Scalping: query interval

//--- API Settings
input string GeminiApiKey = "AQ.Ab8RN6LoTc45ok1MEaALOQRvJuZVsI53r1MU3QlIXZogAgTNNA";
input long MagicNumber = 20260608;

//--- Trailing & Breakeven
input int TrailingStopPoints = 3000;        // Trail distance
input int BreakevenPoints = 2000;           // Move SL to entry after this profit

//--- Spread Filter
input int MaxSpreadPoints = 5000;            // Max allowed spread to trade

//--- Session Filter (UTC hours)
input int TradingStartHour = 7;             // Start trading hour (UTC)
input int TradingEndHour = 22;              // Stop trading hour (UTC)

//--- Risk Management
input double MaxDailyLossUSD = 200.0;       // Max daily loss before shutdown
input int MaxTradesPerDay = 30;             // Max trades per day
input int CooldownAfterLoss = 2;            // Skip N cycles after a losing trade

//--- Confidence Filter
input int MinConfidence = 65;               // Min confidence to execute (0-100)

//--- Partial Close
input int TP1Points = 4000;                 // Close 50% at this profit level
input bool UsePartialClose = true;          // Enable partial close at TP1

//--- State Variables
datetime LastRequest = 0;
int DailyTradeCount = 0;
double DailyPnL = 0.0;
int DayOfLastReset = -1;
int CooldownCounter = 0;
bool TP1Hit[];                              // Track partial close per ticket

//--- Indicator Handles
int HandleRSI_M1 = INVALID_HANDLE;
int HandleEMA9_M1 = INVALID_HANDLE;
int HandleEMA21_M1 = INVALID_HANDLE;
int HandleATR_M1 = INVALID_HANDLE;
int HandleEMA50_M15 = INVALID_HANDLE;
int HandleRSI_M15 = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   
   Print("[INIT] === BTC SCALPING EA - ENHANCED ===");
   Print("[INIT] Symbol: ", TradeSymbol, " | Refresh: ", RefreshSeconds,
         "s | MaxSpread: ", MaxSpreadPoints, " | Session: ", 
         TradingStartHour, "-", TradingEndHour, " UTC");
   Print("[INIT] Risk: MaxDailyLoss=$", MaxDailyLossUSD, 
         " | MaxTrades=", MaxTradesPerDay, 
         " | Cooldown=", CooldownAfterLoss, " cycles");
   
   // Verify the BTC symbol is available
   if(!SymbolInfoInteger(TradeSymbol, SYMBOL_EXIST))
   {
      Print("[ERROR] Symbol ", TradeSymbol, " not found. Check name.");
      return(INIT_FAILED);
   }
   
   SymbolSelect(TradeSymbol, true);

   // Initialize indicator handles
   HandleRSI_M1 = iRSI(TradeSymbol, PERIOD_M1, 14, PRICE_CLOSE);
   HandleEMA9_M1 = iMA(TradeSymbol, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
   HandleEMA21_M1 = iMA(TradeSymbol, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
   HandleATR_M1 = iATR(TradeSymbol, PERIOD_M1, 14);
   HandleEMA50_M15 = iMA(TradeSymbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   HandleRSI_M15 = iMA(TradeSymbol, PERIOD_M15, 14, 0, MODE_EMA, PRICE_CLOSE);
   
   if(HandleRSI_M1 == INVALID_HANDLE || HandleEMA9_M1 == INVALID_HANDLE ||
      HandleEMA21_M1 == INVALID_HANDLE || HandleATR_M1 == INVALID_HANDLE ||
      HandleEMA50_M15 == INVALID_HANDLE)
   {
      Print("[ERROR] Failed to create indicator handles.");
      return(INIT_FAILED);
   }
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("[WARNING] Algo Trading disabled in terminal.");
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   if(HandleRSI_M1 != INVALID_HANDLE) IndicatorRelease(HandleRSI_M1);
   if(HandleEMA9_M1 != INVALID_HANDLE) IndicatorRelease(HandleEMA9_M1);
   if(HandleEMA21_M1 != INVALID_HANDLE) IndicatorRelease(HandleEMA21_M1);
   if(HandleATR_M1 != INVALID_HANDLE) IndicatorRelease(HandleATR_M1);
   if(HandleEMA50_M15 != INVALID_HANDLE) IndicatorRelease(HandleEMA50_M15);
   if(HandleRSI_M15 != INVALID_HANDLE) IndicatorRelease(HandleRSI_M15);
   
   Print("[DEINIT] EA removed. Daily PnL: $", DoubleToString(DailyPnL, 2),
         " | Trades today: ", DailyTradeCount);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Daily reset check
   ResetDailyCounters();
   
   // Trailing stop & partial close run every tick
   ManageTrailingStop();
   ManagePartialClose();
   
   // Time gate
   datetime currentTime = TimeCurrent();
   int elapsed = (int)(currentTime - LastRequest);
   if(elapsed < RefreshSeconds) return;

   // --- PRE-TRADE FILTERS ---
   
   // 1. Session filter
   if(!IsWithinTradingSession())
   {
      return;
   }
   
   // 2. Daily loss limit
   if(DailyPnL <= -MaxDailyLossUSD)
   {
      Print("[RISK] Daily loss limit hit ($", DoubleToString(DailyPnL, 2), 
            "). No more trades today.");
      return;
   }
   
   // 3. Max trades per day
   if(DailyTradeCount >= MaxTradesPerDay)
   {
      Print("[RISK] Max trades per day reached (", DailyTradeCount, "). Stopping.");
      return;
   }
   
   // 4. Cooldown after loss
   if(CooldownCounter > 0)
   {
      CooldownCounter--;
      Print("[RISK] Cooldown active. Cycles remaining: ", CooldownCounter);
      LastRequest = currentTime;
      return;
   }
   
   // 5. Spread filter
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double spreadPts = (ask - bid) / point;
   
   if(spreadPts > MaxSpreadPoints)
   {
      Print("[FILTER] Spread too wide: ", (int)spreadPts, " > ", MaxSpreadPoints, " pts. Skipping.");
      LastRequest = currentTime;
      return;
   }

   // --- SIGNAL GENERATION ---
   Print("[SCALP] --- New Cycle | Spread: ", (int)spreadPts, 
         " pts | DailyPnL: $", DoubleToString(DailyPnL, 2),
         " | Trades: ", DailyTradeCount, "/", MaxTradesPerDay, " ---");

   LastRequest = currentTime;

   string prompt = BuildPrompt();
   
   string raw = GeminiRequest(prompt);
   if(raw == "")
   {
      // Retry once on failure
      Print("[WARN] First API call failed. Retrying in 2s...");
      Sleep(2000);
      raw = GeminiRequest(prompt);
      if(raw == "")
      {
         Print("[ERROR] Retry also failed. Aborting cycle.");
         return;
      }
   }

   string signal = "";
   int confidence = 0;
   ExtractSignalAndConfidence(raw, signal, confidence);
   
   Print("[SIGNAL] Direction: ", signal, " | Confidence: ", confidence, "%");

   // 6. Confidence filter
   if(confidence < MinConfidence && signal != "HOLD")
   {
      Print("[FILTER] Confidence too low (", confidence, " < ", MinConfidence, "). Treating as HOLD.");
      signal = "HOLD";
   }
   
   // 7. Multi-timeframe confirmation
   if(signal != "HOLD" && !ConfirmWithHigherTF(signal))
   {
      Print("[FILTER] M15 trend does not confirm ", signal, " signal. Treating as HOLD.");
      signal = "HOLD";
   }

   ExecuteSignal(signal, LotSize, StopLossPoints, TakeProfitPoints);
}

//+------------------------------------------------------------------+
// SESSION & DAILY MANAGEMENT
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;  // Server time - adjust if not UTC
   
   if(TradingStartHour < TradingEndHour)
      return (hour >= TradingStartHour && hour < TradingEndHour);
   else  // Handles overnight sessions (e.g., 22-6)
      return (hour >= TradingStartHour || hour < TradingEndHour);
}

//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   if(dt.day != DayOfLastReset)
   {
      Print("[DAILY] New day detected. Resetting counters. Yesterday PnL: $", 
            DoubleToString(DailyPnL, 2), " | Trades: ", DailyTradeCount);
      DailyPnL = 0.0;
      DailyTradeCount = 0;
      CooldownCounter = 0;
      DayOfLastReset = dt.day;
   }
}

//+------------------------------------------------------------------+
// MULTI-TIMEFRAME CONFIRMATION
//+------------------------------------------------------------------+
bool ConfirmWithHigherTF(string signal)
{
   double ema50_m15[];
   ArraySetAsSeries(ema50_m15, true);
   if(CopyBuffer(HandleEMA50_M15, 0, 0, 2, ema50_m15) < 2) return true; // Allow if data unavailable
   
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   
   if(signal == "BUY")
      return (bid > ema50_m15[0]);   // Price above M15 EMA50 = uptrend
   
   if(signal == "SELL")
      return (bid < ema50_m15[0]);   // Price below M15 EMA50 = downtrend
   
   return true;
}

//+------------------------------------------------------------------+
// POSITION MANAGEMENT
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == TradeSymbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
ENUM_POSITION_TYPE CurrentPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == TradeSymbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }
   }
   return WRONG_VALUE;
}

//+------------------------------------------------------------------+
bool ClosePosition()
{
   bool success = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == TradeSymbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            if(!trade.PositionClose(ticket))
            {
               Print("[ERROR] Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
               success = false;
            }
            else
            {
               double profit = PositionGetDouble(POSITION_PROFIT);
               DailyPnL += profit;
               DailyTradeCount++;
               if(profit < 0) CooldownCounter = CooldownAfterLoss;
               Print("[TRADE] Closed #", ticket, " P&L: $", DoubleToString(profit, 2));
               LogTrade(ticket, "CLOSE", profit, 0);
            }
         }
      }
   }
   return success;
}

//+------------------------------------------------------------------+
// TRAILING STOP
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(TrailingStopPoints <= 0) return;
   
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
         double profitDist = bid - openPrice;
         
         // Breakeven
         if(BreakevenPoints > 0 && profitDist >= BreakevenPoints * point)
         {
            double beLevel = NormalizeDouble(openPrice + 100 * point, digits);
            if(currentSL < beLevel)
            {
               trade.PositionModify(ticket, beLevel, currentTP);
            }
         }
         
         // Trail
         double trailLevel = NormalizeDouble(bid - TrailingStopPoints * point, digits);
         if(profitDist >= TrailingStopPoints * point && trailLevel > currentSL)
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double askPrice = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
         double profitDist = openPrice - askPrice;
         
         // Breakeven
         if(BreakevenPoints > 0 && profitDist >= BreakevenPoints * point)
         {
            double beLevel = NormalizeDouble(openPrice - 100 * point, digits);
            if(currentSL > beLevel || currentSL == 0)
            {
               trade.PositionModify(ticket, beLevel, currentTP);
            }
         }
         
         // Trail
         double trailLevel = NormalizeDouble(askPrice + TrailingStopPoints * point, digits);
         if(profitDist >= TrailingStopPoints * point && (trailLevel < currentSL || currentSL == 0))
         {
            trade.PositionModify(ticket, trailLevel, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
// PARTIAL CLOSE AT TP1
//+------------------------------------------------------------------+
void ManagePartialClose()
{
   if(!UsePartialClose || TP1Points <= 0) return;
   
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != TradeSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      // Only partial close if volume is still full (hasn't been partially closed yet)
      double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
      double halfLot = NormalizeDouble(volume / 2.0, 2);
      if(halfLot < minLot) continue;  // Can't split further
      if(volume <= LotSize * 0.6) continue;  // Already partially closed
      
      double profitDist = 0;
      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
         profitDist = bid - openPrice;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double askPrice = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
         profitDist = openPrice - askPrice;
      }
      
      if(profitDist >= TP1Points * point)
      {
         if(trade.PositionClosePartial(ticket, halfLot))
         {
            Print("[SCALP] Partial close at TP1 for #", ticket, 
                  " | Closed: ", halfLot, " lots | Remaining: ", 
                  NormalizeDouble(volume - halfLot, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
// ORDER EXECUTION
//+------------------------------------------------------------------+
void OpenBuy(double lot, int sl_points, int tp_points)
{
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double sl = (sl_points > 0) ? NormalizeDouble(ask - sl_points * point, digits) : 0;
   double tp = (tp_points > 0) ? NormalizeDouble(ask + tp_points * point, digits) : 0;

   if(!trade.Buy(lot, TradeSymbol, ask, sl, tp, "Gemini BTC SCALP BUY"))
   {
      Print("[ERROR] BUY rejected: ", trade.ResultRetcodeDescription());
   }
   else
   {
      DailyTradeCount++;
      Print("[TRADE] BUY opened #", trade.ResultOrder(), 
            " | Lot: ", lot, " | Entry: ", ask, " | SL: ", sl, " | TP: ", tp);
      LogTrade(trade.ResultOrder(), "BUY", 0, 0);
   }
}

//+------------------------------------------------------------------+
void OpenSell(double lot, int sl_points, int tp_points)
{
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double sl = (sl_points > 0) ? NormalizeDouble(bid + sl_points * point, digits) : 0;
   double tp = (tp_points > 0) ? NormalizeDouble(bid - tp_points * point, digits) : 0;

   if(!trade.Sell(lot, TradeSymbol, bid, sl, tp, "Gemini BTC SCALP SELL"))
   {
      Print("[ERROR] SELL rejected: ", trade.ResultRetcodeDescription());
   }
   else
   {
      DailyTradeCount++;
      Print("[TRADE] SELL opened #", trade.ResultOrder(), 
            " | Lot: ", lot, " | Entry: ", bid, " | SL: ", sl, " | TP: ", tp);
      LogTrade(trade.ResultOrder(), "SELL", 0, 0);
   }
}

//+------------------------------------------------------------------+
// SIGNAL EXECUTION LOGIC
//+------------------------------------------------------------------+
void ExecuteSignal(string signal, double lot, int sl_points, int tp_points)
{
   StringToUpper(signal);

   if(signal == "BUY")
   {
      if(!HasPosition())
      {
         OpenBuy(lot, sl_points, tp_points);
         return;
      }
      if(CurrentPositionType() == POSITION_TYPE_SELL)
      {
         ClosePosition();
         Sleep(300);
         OpenBuy(lot, sl_points, tp_points);
      }
      return;
   }

   if(signal == "SELL")
   {
      if(!HasPosition())
      {
         OpenSell(lot, sl_points, tp_points);
         return;
      }
      if(CurrentPositionType() == POSITION_TYPE_BUY)
      {
         ClosePosition();
         Sleep(300);
         OpenSell(lot, sl_points, tp_points);
      }
      return;
   }
   
   // HOLD - no action
}

//+------------------------------------------------------------------+
// ENHANCED PROMPT WITH INDICATORS
//+------------------------------------------------------------------+
string BuildPrompt()
{
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double spread = (ask - bid) / point;

   // --- M1 Candles ---
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(TradeSymbol, PERIOD_M1, 0, 10, rates);

   string candle_info = "";
   if(copied >= 10)
   {
      for(int i = 0; i < 10; i++)
      {
         candle_info += "M1[" + IntegerToString(i) + "] O=" + DoubleToString(rates[i].open, digits) +
                        " H=" + DoubleToString(rates[i].high, digits) +
                        " L=" + DoubleToString(rates[i].low, digits) +
                        " C=" + DoubleToString(rates[i].close, digits) +
                        " V=" + IntegerToString(rates[i].tick_volume) + "\\n";
      }
   }

   // --- Technical Indicators ---
   double rsi[], ema9[], ema21[], atr[], ema50_m15[];
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(ema9, true);
   ArraySetAsSeries(ema21, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(ema50_m15, true);
   
   CopyBuffer(HandleRSI_M1, 0, 0, 3, rsi);
   CopyBuffer(HandleEMA9_M1, 0, 0, 3, ema9);
   CopyBuffer(HandleEMA21_M1, 0, 0, 3, ema21);
   CopyBuffer(HandleATR_M1, 0, 0, 3, atr);
   CopyBuffer(HandleEMA50_M15, 0, 0, 2, ema50_m15);

   string indicators = "";
   if(ArraySize(rsi) >= 3 && ArraySize(ema9) >= 3 && 
      ArraySize(ema21) >= 3 && ArraySize(atr) >= 3)
   {
      indicators = "--- Technical Indicators (M1) ---\\n" +
         "RSI(14): " + DoubleToString(rsi[0], 1) + 
         " (prev: " + DoubleToString(rsi[1], 1) + ")\\n" +
         "EMA9: " + DoubleToString(ema9[0], digits) + "\\n" +
         "EMA21: " + DoubleToString(ema21[0], digits) + "\\n" +
         "EMA Cross: " + (ema9[0] > ema21[0] ? "BULLISH (EMA9 > EMA21)" : "BEARISH (EMA9 < EMA21)") + "\\n" +
         "ATR(14): " + DoubleToString(atr[0], digits) + " (volatility)\\n";
   }
   
   string htf_info = "";
   if(ArraySize(ema50_m15) >= 2)
   {
      htf_info = "--- Higher Timeframe (M15) ---\\n" +
         "EMA50_M15: " + DoubleToString(ema50_m15[0], digits) + "\\n" +
         "Price vs M15 EMA50: " + (bid > ema50_m15[0] ? "ABOVE (uptrend)" : "BELOW (downtrend)") + "\\n";
   }

   // --- Position context ---
   string pos_info = "Current position: ";
   if(HasPosition())
   {
      ENUM_POSITION_TYPE ptype = CurrentPositionType();
      pos_info += (ptype == POSITION_TYPE_BUY ? "LONG" : "SHORT");
   }
   else
   {
      pos_info += "NONE";
   }
   pos_info += "\\n";

   string prompt =
      "You are an expert Bitcoin scalping AI. Capture small, quick moves on M1 timeframe.\\n" +
      "Symbol=" + TradeSymbol + "\\n" +
      "Bid=" + DoubleToString(bid, digits) + "\\n" +
      "Ask=" + DoubleToString(ask, digits) + "\\n" +
      "Spread=" + DoubleToString(spread, 0) + " points\\n" +
      pos_info +
      "\\n" + indicators +
      "\\n" + htf_info +
      "\\nLast 10 M1 candles (0=current, 9=oldest):\\n" + candle_info +
      "\\nRules:\\n" +
      "- Only BUY/SELL with clear short-term momentum AND indicator confirmation.\\n" +
      "- RSI above 70 = overbought (favor SELL), below 30 = oversold (favor BUY).\\n" +
      "- EMA9 crossing above EMA21 = bullish, below = bearish.\\n" +
      "- Trade WITH the M15 trend, not against it.\\n" +
      "- If unsure or conflicting signals, say HOLD.\\n" +
      "\\nReply format: SIGNAL CONFIDENCE\\n" +
      "Example: BUY 85 or SELL 72 or HOLD 50\\n" +
      "SIGNAL must be BUY, SELL, or HOLD. CONFIDENCE is 0-100.";

   return prompt;
}

//+------------------------------------------------------------------+
// GEMINI API COMMUNICATION
//+------------------------------------------------------------------+
string GeminiRequest(string prompt)
{
   string url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=" + GeminiApiKey;

   StringReplace(prompt, "\"", "'");
   string body = "{\"contents\":[{\"parts\":[{\"text\":\"" + prompt + "\"}]}]}";

   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);

   char result[];
   string result_headers;
   string headers = "Content-Type: application/json\r\n";
   int timeout = 15000;  // Faster timeout for scalping

   ResetLastError();
   int responseCode = WebRequest("POST", url, headers, timeout, post, result, result_headers);

   if(responseCode == -1)
   {
      Print("[ERROR] WebRequest failed. Error: ", GetLastError());
      return "";
   }

   if(responseCode != 200)
   {
      Print("[ERROR] API returned HTTP ", responseCode);
      return "";
   }

   return CharArrayToString(result);
}

//+------------------------------------------------------------------+
// PARSE SIGNAL + CONFIDENCE FROM GEMINI RESPONSE
//+------------------------------------------------------------------+
void ExtractSignalAndConfidence(string jsonText, string &signal, int &confidence)
{
   signal = "HOLD";
   confidence = 0;
   
   CJAVal json;
   if(!json.Deserialize(jsonText))
   {
      Print("[ERROR] JSON parse failed.");
      return;
   }

   string text = json["candidates"][0]["content"]["parts"][0]["text"].ToStr();
   StringTrimLeft(text);
   StringTrimRight(text);
   StringToUpper(text);

   // Parse direction
   if(StringFind(text, "BUY") >= 0)
      signal = "BUY";
   else if(StringFind(text, "SELL") >= 0)
      signal = "SELL";
   else
   {
      signal = "HOLD";
      confidence = 50;
      return;
   }
   
   // Parse confidence number from response
   // Expected format: "BUY 85" or "SELL 72"
   confidence = 50;  // Default if no number found
   
   for(int i = 0; i < StringLen(text); i++)
   {
      ushort ch = StringGetCharacter(text, i);
      if(ch >= '0' && ch <= '9')
      {
         string numStr = "";
         while(i < StringLen(text))
         {
            ch = StringGetCharacter(text, i);
            if(ch >= '0' && ch <= '9')
            {
               numStr += ShortToString(ch);
               i++;
            }
            else break;
         }
         int parsed = (int)StringToInteger(numStr);
         if(parsed >= 0 && parsed <= 100)
         {
            confidence = parsed;
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
// TRADE JOURNAL - CSV LOGGING
//+------------------------------------------------------------------+
void LogTrade(ulong ticket, string action, double profit, int confidence)
{
   string filename = "ScalpLog_" + TradeSymbol + "_" + IntegerToString(MagicNumber) + ".csv";
   
   int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("[LOG] Cannot open log file: ", filename);
      return;
   }
   
   // If file is new/empty, write header
   if(FileSize(handle) == 0)
   {
      FileWrite(handle, "DateTime", "Ticket", "Action", "Symbol", "Profit", 
                "DailyPnL", "DailyTrades", "Confidence");
   }
   
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, 
      TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
      IntegerToString(ticket),
      action,
      TradeSymbol,
      DoubleToString(profit, 2),
      DoubleToString(DailyPnL, 2),
      IntegerToString(DailyTradeCount),
      IntegerToString(confidence));
   
   FileClose(handle);
}

//+------------------------------------------------------------------+
// TRADE TRANSACTION HANDLER - Track closed trade results
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.symbol == TradeSymbol)
      {
         // Check if this is an exit deal
         if(HistoryDealSelect(trans.deal))
         {
            long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
            ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            
            if(dealMagic == MagicNumber && dealEntry == DEAL_ENTRY_OUT)
            {
               double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
               double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
               double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
               double netPnL = profit + commission + swap;
               
               DailyPnL += netPnL;
               
               if(netPnL < 0)
               {
                  CooldownCounter = CooldownAfterLoss;
                  Print("[RISK] Loss detected: $", DoubleToString(netPnL, 2), 
                        " | Activating cooldown: ", CooldownAfterLoss, " cycles");
               }
               
               Print("[PNL] Deal #", trans.deal, " Net: $", DoubleToString(netPnL, 2),
                     " | Daily total: $", DoubleToString(DailyPnL, 2));
            }
         }
      }
   }
}
