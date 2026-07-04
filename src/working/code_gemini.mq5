//+------------------------------------------------------------------+
//|                                                  code_gemini.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

input double LotSize = 0.10;
input int StopLossPoints = 1000;
input int TakeProfitPoints = 2000;
input int RefreshSeconds = 60;

datetime LastRequest = 0;

input string GeminiApiKey = "AQ.Ab8RN6LoTc45ok1MEaALOQRvJuZVsI53r1MU3QlIXZogAgTNNA"; 
input long MagicNumber = 20260606;

//--------------------------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   
   Print("[DEBUG] Initialization started. MagicNumber set to: ", MagicNumber);
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("[WARNING] Automated trading is disabled in terminal settings. Enable 'Allow Algo Trading'.");
   }
   else 
   {
      Print("[DEBUG] Terminal algorithmic trading permissions verified.");
   }
   
   return(INIT_SUCCEEDED);
}

//--------------------------------------------------
void OnTick()
{
   datetime currentTime = TimeCurrent();
   int elapsed = (int)(currentTime - LastRequest);
   
   if(elapsed < RefreshSeconds)
   {
      // Optional: uncomment below line if you want to track every single tick skip
      // Print("[DEBUG] Tick skipped. Seconds remaining until next request: ", RefreshSeconds - elapsed);
      return;
   }

   Print("[DEBUG] --- New Analysis Cycle Started ---");
   Print("[DEBUG] Elapsed time (", elapsed, "s) >= Refresh period (", RefreshSeconds, "s). Querying Gemini.");

   LastRequest = currentTime;

   string prompt = BuildPrompt();
   Print("[DEBUG] Formatted Prompt Message:\n", prompt);

   string raw = GeminiRequest(prompt);
   if(raw == "")
   {
      Print("[ERROR] Empty response returned from Gemini API request. Aborting cycle.");
      return;
   }

   string signal = ExtractGeminiText(raw);
   Print("[DEBUG] Final Parsed Execution Signal: ", signal);

   ExecuteSignal(
      signal,
      LotSize,
      StopLossPoints,
      TakeProfitPoints);
}

//--------------------------------------------------
bool HasPosition()
{
   int matchedPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            matchedPositions++;
         }
      }
   }
   
   Print("[DEBUG] HasPosition check: Found ", matchedPositions, " existing position(s) matching Symbol=", _Symbol, " and Magic=", MagicNumber);
   return (matchedPositions > 0);
}

//--------------------------------------------------
ENUM_POSITION_TYPE CurrentPositionType()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            Print("[DEBUG] Current active position type determined as: ", EnumToString(type));
            return type;
         }
      }
   }
   Print("[DEBUG] CurrentPositionType check: No matching active position found.");
   return WRONG_VALUE;
}

//--------------------------------------------------
bool ClosePosition()
{
   bool success = true;
   Print("[DEBUG] Attempting to close all positions matching Symbol=", _Symbol, " and Magic=", MagicNumber);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            Print("[DEBUG] Sending close request for Position Ticket #", ticket);
            
            if(!trade.PositionClose(ticket))
            {
               Print("[ERROR] Failed to close position ticket #", ticket, ". Result Code: ", trade.ResultRetcode(), " Description: ", trade.ResultRetcodeDescription());
               success = false;
            }
            else
            {
               Print("[DEBUG] Close request executed for Ticket #", ticket, ". Result Code: ", trade.ResultRetcode());
            }
         }
      }
   }
   return success;
}

//--------------------------------------------------
void OpenBuy(double lot, int sl_points, int tp_points)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = (sl_points > 0) ? NormalizeDouble(ask - sl_points * _Point, _Digits) : 0;
   double tp = (tp_points > 0) ? NormalizeDouble(ask + tp_points * _Point, _Digits) : 0;

   Print("[DEBUG] Executing BUY order initialization...");
   Print("[DEBUG] Parameters -> Symbol: ", _Symbol, " | Lot: ", lot, " | Price: ", ask, " | SL: ", sl, " | TP: ", tp);

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, "Gemini BUY"))
   {
      Print("[ERROR] BUY execution encountered a terminal rejection. Code: ", trade.ResultRetcode(), " | Details: ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[DEBUG] BUY sequence completed. Server response ticket: #", trade.ResultOrder());
   }
}

//--------------------------------------------------
void OpenSell(double lot, int sl_points, int tp_points)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (sl_points > 0) ? NormalizeDouble(bid + sl_points * _Point, _Digits) : 0;
   double tp = (tp_points > 0) ? NormalizeDouble(bid - tp_points * _Point, _Digits) : 0;

   Print("[DEBUG] Executing SELL order initialization...");
   Print("[DEBUG] Parameters -> Symbol: ", _Symbol, " | Lot: ", lot, " | Price: ", bid, " | SL: ", sl, " | TP: ", tp);

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, "Gemini SELL"))
   {
      Print("[ERROR] SELL execution encountered a terminal rejection. Code: ", trade.ResultRetcode(), " | Details: ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("[DEBUG] SELL sequence completed. Server response ticket: #", trade.ResultOrder());
   }
}

//--------------------------------------------------
void ExecuteSignal(string signal, double lot, int sl_points, int tp_points)
{
   StringToUpper(signal);
   Print("[DEBUG] Processing incoming signal action rules for: '", signal, "'");

   if(signal == "BUY")
   {
      if(!HasPosition())
      {
         Print("[DEBUG] Scenario: BUY signal with no active positions. Opening pure BUY.");
         OpenBuy(lot, sl_points, tp_points);
         return;
      }

      if(CurrentPositionType() == POSITION_TYPE_SELL)
      {
         Print("[DEBUG] Scenario: BUY signal found opposing SELL position. Initiating reversal sequence.");
         ClosePosition();
         Print("[DEBUG] Reversal: Pausing 1000ms for clearing state context.");
         Sleep(1000); 
         OpenBuy(lot, sl_points, tp_points);
      }
      else
      {
         Print("[DEBUG] Scenario: BUY signal but already in a matching BUY position. Skipping repeat allocation.");
      }
      return;
   }

   if(signal == "SELL")
   {
      if(!HasPosition())
      {
         Print("[DEBUG] Scenario: SELL signal with no active positions. Opening pure SELL.");
         OpenSell(lot, sl_points, tp_points);
         return;
      }

      if(CurrentPositionType() == POSITION_TYPE_BUY)
      {
         Print("[DEBUG] Scenario: SELL signal found opposing BUY position. Initiating reversal sequence.");
         ClosePosition();
         Print("[DEBUG] Reversal: Pausing 1000ms for clearing state context.");
         Sleep(1000); 
         OpenSell(lot, sl_points, tp_points);
      }
      else
      {
         Print("[DEBUG] Scenario: SELL signal but already in a matching SELL position. Skipping repeat allocation.");
      }
      return;
   }
   
   Print("[DEBUG] Scenario: Signal resolved to 'HOLD' or was unidentifiable. No trade tasks dispatched.");
}

//--------------------------------------------------
string BuildPrompt()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   string prompt =
      "Symbol=" + _Symbol + "\\n" +
      "Bid=" + DoubleToString(bid, _Digits) + "\\n" +
      "Ask=" + DoubleToString(ask, _Digits) + "\\n" +
      "Reply ONLY with one single word: BUY, SELL or HOLD. No punctuation.";

   return prompt;
}

//--------------------------------------------------
string GeminiRequest(string prompt)
{
   string url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=" + GeminiApiKey;

   StringReplace(prompt, "\"", "'");
   string body = "{\"contents\":[{\"parts\":[{\"text\":\"" + prompt + "\"}]}]}";
   
   Print("[DEBUG] Prepared API request raw JSON payload body: ", body);

   char post[];
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);

   char result[];
   string result_headers;
   string headers = "Content-Type: application/json\r\n";
   int timeout = 30000;

   ResetLastError();

   Print("[DEBUG] Dispatching WebRequest to endpoint...");
   int responseCode = WebRequest("POST", url, headers, timeout, post, result, result_headers);

   if(responseCode == -1)
   {
      Print("[ERROR] WebRequest structural error code: ", GetLastError(), ". Double check terminal options permissions!");
      return "";
   }

   Print("[DEBUG] HTTP Endpoint Response Status Code Received: ", responseCode);
   string rawJsonResult = CharArrayToString(result);
   Print("[DEBUG] Raw Response String Content from API:\n", rawJsonResult);

   return rawJsonResult;
}

//--------------------------------------------------
string ExtractGeminiText(string jsonText)
{
   CJAVal json;
   Print("[DEBUG] Deserializing JSON text response block via JAson...");

   if(!json.Deserialize(jsonText))
   {
      Print("[ERROR] JAson core parsing operation failed on target response context.");
      return "HOLD";
   }

   // Extract specific JSON array elements down to structural parts field
   string text = json["candidates"][0]["content"]["parts"][0]["text"].ToStr();
   Print("[DEBUG] Extracted text layer raw component value: \"", text, "\"");

   StringTrimLeft(text);
   StringTrimRight(text);
   StringToUpper(text);

   Print("[DEBUG] Cleaned and tokenized query parameter text string: \"", text, "\"");

   if(StringFind(text, "BUY") >= 0)
   {
      Print("[DEBUG] Signal keyword match identified as: BUY");
      return "BUY";
   }

   if(StringFind(text, "SELL") >= 0)
   {
      Print("[DEBUG] Signal keyword match identified as: SELL");
      return "SELL";
   }

   Print("[DEBUG] No tactical match found or text evaluated explicitly to HOLD.");
   return "HOLD";
}