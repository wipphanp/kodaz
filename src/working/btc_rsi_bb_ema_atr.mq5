//+------------------------------------------------------------------+
//| BTCUSD RSI + Bollinger + EMA EA (M1 Optimized)                   |
//| - Symbol: BTCUSD only                                            |
//| - Entries: RSI "judicious" + 8 EMA vs BB mid + 19 EMA            |
//| - Risk: ATR-based SL/TP                                          |
//| - Management: flip on opposite signal, ATR trailing stop         |
//+------------------------------------------------------------------+
#property strict

//--- User inputs
input double Lots              = 0.10;       // Fixed lot size (can be replaced by risk-based sizing)
input ENUM_TIMEFRAMES WorkTF   = PERIOD_M1;  // Working timeframe (optimized for M1)

input int    BB_Period         = 20;
input double BB_Deviation      = 2.0;

input int    EMA_Fast_Period   = 8;
input int    EMA_Slow_Period   = 19;

input int    RSI_Period        = 14;
input int    RSI_OversoldLevel = 30;
input int    RSI_OverboughtLevel = 70;

// ATR-based risk management
input int    ATR_Period        = 14;
input double SL_ATR_Multiplier = 2.0;        // Stop loss = SL_ATR_Multiplier * ATR
input double TP_ATR_Multiplier = 4.0;        // Take profit = TP_ATR_Multiplier * ATR

// Trailing stop
input double TrailStart_ATR    = 1.0;        // Start trailing when profit >= 1 * ATR
input double TrailStep_ATR     = 0.7;        // Distance of trailing SL from price in ATR units

//--- Indicator handles
int hBands  = INVALID_HANDLE;
int hEMA8   = INVALID_HANDLE;
int hEMA19  = INVALID_HANDLE;
int hRSI    = INVALID_HANDLE;
int hATR    = INVALID_HANDLE;

//--- Buffers
double bbMid[];
double ema8[];
double ema19[];
double rsi[];
double atr[];

//--- RSI state flags (judicious entry behaviour)
bool rsiOversoldFlag   = false; // true after RSI <= oversold, until first buy after recovery + structure
bool rsiOverboughtFlag = false; // true after RSI >= overbought, until first sell after recovery + structure

//+------------------------------------------------------------------+
//| OnInit: create indicators, set arrays                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "BTCUSD")
      Print("Warning: EA is designed for BTCUSD. Current symbol: ", _Symbol);

   hBands = iBands(_Symbol, WorkTF, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   if(hBands == INVALID_HANDLE)
      return(INIT_FAILED);

   hEMA8  = iMA(_Symbol, WorkTF, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA19 = iMA(_Symbol, WorkTF, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA8 == INVALID_HANDLE || hEMA19 == INVALID_HANDLE)
      return(INIT_FAILED);

   hRSI = iRSI(_Symbol, WorkTF, RSI_Period, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE)
      return(INIT_FAILED);

   hATR = iATR(_Symbol, WorkTF, ATR_Period);
   if(hATR == INVALID_HANDLE)
      return(INIT_FAILED);

   ArraySetAsSeries(bbMid, true);
   ArraySetAsSeries(ema8,  true);
   ArraySetAsSeries(ema19, true);
   ArraySetAsSeries(rsi,   true);
   ArraySetAsSeries(atr,   true);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit: release indicator handles                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hBands != INVALID_HANDLE) IndicatorRelease(hBands);
   if(hEMA8  != INVALID_HANDLE) IndicatorRelease(hEMA8);
   if(hEMA19 != INVALID_HANDLE) IndicatorRelease(hEMA19);
   if(hRSI   != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR   != INVALID_HANDLE) IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//| OnTick: main loop - new bar processing on WorkTF                 |
//+------------------------------------------------------------------+
void OnTick()
{
   if(_Symbol != "BTCUSD")
      return;

   if(Bars(_Symbol, WorkTF) < 100)
      return;

   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, WorkTF, 0);
   if(curBarTime == lastBarTime)
   {
      // Trailing can still update inside the bar
      ManageTrailingStops();
      return;
   }
   lastBarTime = curBarTime;

   if(!UpdateIndicators())
      return;

   UpdateRSIStateFlags();
   ManageTrailingStops();
   CheckSignals();
}

//+------------------------------------------------------------------+
//| UpdateIndicators: copy latest values into buffers                |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   int copied;

   copied = CopyBuffer(hBands, 1, 0, 3, bbMid);
   if(copied < 3) return(false);

   copied = CopyBuffer(hEMA8,  0, 0, 3, ema8);
   if(copied < 3) return(false);

   copied = CopyBuffer(hEMA19, 0, 0, 3, ema19);
   if(copied < 3) return(false);

   copied = CopyBuffer(hRSI,   0, 0, 3, rsi);
   if(copied < 3) return(false);

   copied = CopyBuffer(hATR,   0, 0, 3, atr);
   if(copied < 3) return(false);

   return(true);
}

//+------------------------------------------------------------------+
//| UpdateRSIStateFlags: mark oversold/overbought states             |
//+------------------------------------------------------------------+
void UpdateRSIStateFlags()
{
   double rsi1 = rsi[1];

   if(rsi1 <= RSI_OversoldLevel)
      rsiOversoldFlag = true;

   if(rsi1 >= RSI_OverboughtLevel)
      rsiOverboughtFlag = true;
}

//+------------------------------------------------------------------+
//| CheckSignals: generate buy/sell signals and manage positions     |
//+------------------------------------------------------------------+
void CheckSignals()
{
   int idxCurr = 1;
   int idxPrev = 2;

   double ema8_curr  = ema8[idxCurr];
   double ema8_prev  = ema8[idxPrev];
   double ema19_curr = ema19[idxCurr];
   double bbMid_curr = bbMid[idxCurr];
   double bbMid_prev = bbMid[idxPrev];
   double rsi_curr   = rsi[idxCurr];

   bool crossUp      = (ema8_prev < bbMid_prev && ema8_curr > bbMid_curr);
   bool emaFilterUp  = (ema8_curr > ema19_curr);

   bool crossDown    = (ema8_prev > bbMid_prev && ema8_curr < bbMid_curr);
   bool emaFilterDn  = (ema8_curr < ema19_curr);

   bool hasBuy  = (CountPositions(ORDER_TYPE_BUY)  > 0);
   bool hasSell = (CountPositions(ORDER_TYPE_SELL) > 0);

   bool buySignal =
      rsiOversoldFlag &&
      rsi_curr > RSI_OversoldLevel &&
      crossUp &&
      emaFilterUp;

   bool sellSignal =
      rsiOverboughtFlag &&
      rsi_curr < RSI_OverboughtLevel &&
      crossDown &&
      emaFilterDn;

   if(buySignal)
   {
      CloseAllPositionsOfType(ORDER_TYPE_SELL);
      hasSell = false;

      if(!hasBuy)
      {
         OpenPosition(ORDER_TYPE_BUY);
         rsiOversoldFlag = false;
      }
   }
   else if(sellSignal)
   {
      CloseAllPositionsOfType(ORDER_TYPE_BUY);
      hasBuy = false;

      if(!hasSell)
      {
         OpenPosition(ORDER_TYPE_SELL);
         rsiOverboughtFlag = false;
      }
   }
}

//+------------------------------------------------------------------+
//| CountPositions: count BTCUSD positions of given type             |
//+------------------------------------------------------------------+
int CountPositions(ENUM_ORDER_TYPE type)
{
   int total = PositionsTotal();
   int count = 0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != "BTCUSD")
         continue;

      long ptype = PositionGetInteger(POSITION_TYPE);
      if((ENUM_ORDER_TYPE)ptype == type)
         count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| CloseAllPositionsOfType: close all BTCUSD positions by type      |
//+------------------------------------------------------------------+
void CloseAllPositionsOfType(ENUM_ORDER_TYPE type)
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   ptype = PositionGetInteger(POSITION_TYPE);

      if(sym == "BTCUSD" && (ENUM_ORDER_TYPE)ptype == type)
      {
         ClosePositionByTicket(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| ClosePositionByTicket: send opposite order to close position     |
//+------------------------------------------------------------------+
void ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;

   long   ptype  = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   double price;
   if(ptype == POSITION_TYPE_BUY)
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.position = ticket;
   req.volume   = volume;
   req.type     = (ptype == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   req.price    = price;
   req.deviation= 50;
   req.magic    = 987654;

   OrderSend(req, res);
}

//+------------------------------------------------------------------+
//| OpenPosition: open buy/sell with ATR-based SL and TP             |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type)
{
   double atrValue = atr[1];
   if(atrValue <= 0)
      return;

   double price, sl, tp;

   if(type == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = price - SL_ATR_Multiplier * atrValue;
      tp    = price + TP_ATR_Multiplier * atrValue;
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = price + SL_ATR_Multiplier * atrValue;
      tp    = price - TP_ATR_Multiplier * atrValue;
   }

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = _Symbol;
   req.type        = type;
   req.volume      = Lots;
   req.price       = price;
   req.sl          = sl;
   req.tp          = tp;
   req.deviation   = 50;
   req.magic       = 987654;
   req.type_filling= ORDER_FILLING_RETURN;

   OrderSend(req, res);
}

//+------------------------------------------------------------------+
//| ManageTrailingStops: ATR-based trailing once in profit           |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   double atrValue = atr[1];
   if(atrValue <= 0)
      return;

   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != "BTCUSD")
         continue;

      long   ptype     = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentPrice = (ptype == POSITION_TYPE_BUY ? bid : ask);

      double profitDistance = (ptype == POSITION_TYPE_BUY ?
                               currentPrice - openPrice :
                               openPrice - currentPrice);

      double minProfit = TrailStart_ATR * atrValue;
      if(profitDistance < minProfit)
         continue;

      double trailDistance = TrailStep_ATR * atrValue;
      double newSL;

      if(ptype == POSITION_TYPE_BUY)
      {
         newSL = currentPrice - trailDistance;
         if(newSL <= curSL)
            continue;
      }
      else
      {
         newSL = currentPrice + trailDistance;
         if(curSL != 0.0 && newSL >= curSL)
            continue;
      }

      MqlTradeRequest  req;
      MqlTradeResult   res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = _Symbol;
      req.position = ticket;
      req.sl       = newSL;
      req.tp       = curTP;
      req.magic    = 987654;

      OrderSend(req, res);
   }
}
//+------------------------------------------------------------------+
