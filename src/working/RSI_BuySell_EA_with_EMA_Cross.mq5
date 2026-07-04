//+------------------------------------------------------------------+
//|                RSI_BuySell_EA_with_EMA_Cross.mq5                 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict

//------------------------------ INPUTS ------------------------------
input int    InpRSIPeriod      = 14;          // RSI period
input double InpBuyLevel       = 30.0;        // RSI level to trigger BUY entry (cross-up)
input double InpSellLevel      = 70.0;        // RSI level to trigger SELL entry (cross-up)
input double InpSellCloseLevel = 35.0;        // RSI level to close SELL (cross-down)
input double InpBuyCloseLevel  = 63.0;        // RSI level to close BUY  (cross-down)
input double InpStopLoss       = 0;           // Stop-loss in points (0 = disabled)
input double InpTakeProfit     = 0;           // Take-profit in points (0 = disabled)
input int    InpMagicNumber    = 987654;      // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // timeframe for RSI & EMAs

// EMA crossover parameters
input int    InpEMAPeriodFast  = 9;           // fast EMA (e.g. 9)
input int    InpEMAPeriodSlow  = 18;          // slow EMA (e.g. 18)
input double InpEMALot         = 0.03;        // lot size for EMA crossover trades

//--------------------------- GLOBALS -------------------------------
int      rsiHandle   = INVALID_HANDLE;   // iRSI indicator handle
int      emaFastHandle = INVALID_HANDLE; // fast EMA handle
int      emaSlowHandle = INVALID_HANDLE; // slow EMA handle

double   prevRSI     = 0.0;              // RSI value from previous tick
bool     firstTick   = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // RSI handle
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create iRSI handle. Error=", GetLastError());
      return(INIT_FAILED);
   }

   // EMA handles
   emaFastHandle = iMA(_Symbol, InpTimeframe, InpEMAPeriodFast, 0, MODE_EMA, PRICE_CLOSE);
   if(emaFastHandle == INVALID_HANDLE)
   {
      Print("Failed to create fast EMA handle. Error=", GetLastError());
      return(INIT_FAILED);
   }
   emaSlowHandle = iMA(_Symbol, InpTimeframe, InpEMAPeriodSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(emaSlowHandle == INVALID_HANDLE)
   {
      Print("Failed to create slow EMA handle. Error=", GetLastError());
      return(INIT_FAILED);
   }

   prevRSI   = 0.0;
   firstTick = true;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle     != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- RSI
   double rsiBuffer[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
   {
      Print("CopyBuffer RSI failed. Error=", GetLastError());
      return;
   }
   double rsi = rsiBuffer[0];

   //--- EMAs (fast & slow, current and previous bar for cross)
   double emaFast[2], emaSlow[2];
   if(CopyBuffer(emaFastHandle, 0, 0, 2, emaFast) <= 0 ||
      CopyBuffer(emaSlowHandle, 0, 0, 2, emaSlow) <= 0)
   {
      Print("CopyBuffer EMA failed. Error=", GetLastError());
      return;
   }
   // emaFast[0], emaSlow[0] = current bar
   // emaFast[1], emaSlow[1] = previous bar

   //--- first tick init
   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   //===========================================================
   // 1) RSI-BASED LOGIC (original)
   //===========================================================
   bool positionExists = PositionExistsRSI();

   if(!positionExists)
   {
      bool crossUpBuy   = (prevRSI < InpBuyLevel)      && (rsi >= InpBuyLevel);
      bool crossUpSell  = (prevRSI < InpSellLevel)     && (rsi >= InpSellLevel);

      if(crossUpBuy)   OpenBuyPositionRSI();
      if(crossUpSell)  OpenSellPositionRSI();
   }

   if(positionExists)
   {
      ENUM_POSITION_TYPE posType = GetRSIPositionType();

      bool crossDownBuyExit  = (prevRSI > InpBuyCloseLevel)  && (rsi <= InpBuyCloseLevel);
      bool crossDownSellExit = (prevRSI > InpSellCloseLevel) && (rsi <= InpSellCloseLevel);

      if(posType==POSITION_TYPE_BUY  && crossDownBuyExit)  CloseRSIPosition();
      if(posType==POSITION_TYPE_SELL && crossDownSellExit) CloseRSIPosition();
   }

   //===========================================================
   // 2) EMA-CROSSOVER LOGIC (new, separate, single position)
   //===========================================================
   bool emaExists = PositionExistsEMA();
   ENUM_POSITION_TYPE emaType = POSITION_TYPE_BUY;

   if(emaExists)
      emaType = GetEMAPositionType();

   // Conditions:
   // - Bullish cross: 9 EMA crosses above 18 EMA => buy
   // - Bearish cross: 9 EMA crosses below 18 EMA => sell
   bool emaBullCross = (emaFast[1] <= emaSlow[1]) && (emaFast[0] > emaSlow[0]);
   bool emaBearCross = (emaFast[1] >= emaSlow[1]) && (emaFast[0] < emaSlow[0]);

   if(!emaExists)
   {
      // no EMA position: open one according to cross
      if(emaBullCross) OpenBuyPositionEMA(InpEMALot);
      if(emaBearCross) OpenSellPositionEMA(InpEMALot);
   }
   else
   {
      // EMA position exists: manage according to side and new crosses
      if(emaType == POSITION_TYPE_BUY)
      {
         // if bullish regime breaks (9 EMA goes below 18 EMA) -> close buy and open sell
         if(emaBearCross)
         {
            CloseEMAPosition();
            OpenSellPositionEMA(InpEMALot);
         }
      }
      else if(emaType == POSITION_TYPE_SELL)
      {
         // if bearish regime breaks (9 EMA goes above 18 EMA) -> close sell and open buy
         if(emaBullCross)
         {
            CloseEMAPosition();
            OpenBuyPositionEMA(InpEMALot);
         }
      }
   }

   //--- store RSI for next tick
   prevRSI = rsi;
}

//+------------------------------------------------------------------+
//| Helper: check RSI position (using main magic number)             |
//+------------------------------------------------------------------+
bool PositionExistsRSI()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Get type of current RSI position                                 |
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetRSIPositionType()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   }
   return POSITION_TYPE_BUY; // default
}

//+------------------------------------------------------------------+
//| Open BUY (RSI logic)                                             |
//+------------------------------------------------------------------+
void OpenBuyPositionRSI()
{
   const double lot = 0.05;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl    = (InpStopLoss>0) ? price - InpStopLoss*_Point : 0.0;
   double tp    = (InpTakeProfit>0)? price + InpTakeProfit*_Point: 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = _Symbol;
   req.volume      = lot;
   req.type        = ORDER_TYPE_BUY;
   req.price       = price;
   req.sl          = sl;
   req.tp          = tp;
   req.magic       = InpMagicNumber;
   req.comment     = "RSI_EA_BUY";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("RSI BUY OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("RSI BUY order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Open SELL (RSI logic)                                            |
//+------------------------------------------------------------------+
void OpenSellPositionRSI()
{
   const double lot = 0.05;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (InpStopLoss>0) ? price + InpStopLoss*_Point : 0.0;
   double tp    = (InpTakeProfit>0)? price - InpTakeProfit*_Point: 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = _Symbol;
   req.volume      = lot;
   req.type        = ORDER_TYPE_SELL;
   req.price       = price;
   req.sl          = sl;
   req.tp          = tp;
   req.magic       = InpMagicNumber;
   req.comment     = "RSI_EA_SELL";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("RSI SELL OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("RSI SELL order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Close RSI position                                               |
//+------------------------------------------------------------------+
void CloseRSIPosition()
{
   ulong ticket = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
      { ticket = t; break; }
   }
   if(ticket==0) return;

   double lot = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.position = ticket;
   req.type     = (type==POSITION_TYPE_BUY)? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price    = (type==POSITION_TYPE_BUY)?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.magic    = InpMagicNumber;
   req.comment  = "RSI_EA_Close";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("RSI Close OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("RSI Close not filled. Retcode=%d", res.retcode);
}

//====================================================================
// EMA CROSSOVER POSITION MANAGEMENT (SEPARATE MAGIC)
//====================================================================
int EMAMagic() { return(InpMagicNumber + 1000); } // distinct magic for EMA trades

//+------------------------------------------------------------------+
//| Check EMA position                                                |
//+------------------------------------------------------------------+
bool PositionExistsEMA()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==EMAMagic())
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Get EMA position type                                             |
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetEMAPositionType()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==EMAMagic())
         return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   }
   return POSITION_TYPE_BUY;
}

//+------------------------------------------------------------------+
//| Open EMA BUY                                                      |
//+------------------------------------------------------------------+
void OpenBuyPositionEMA(double lot)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = _Symbol;
   req.volume      = lot;
   req.type        = ORDER_TYPE_BUY;
   req.price       = price;
   req.sl          = 0.0;  // managed by your own logic if needed
   req.tp          = 0.0;
   req.magic       = EMAMagic();
   req.comment     = "EMA_X_BUY";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("EMA BUY OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("EMA BUY order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Open EMA SELL                                                     |
//+------------------------------------------------------------------+
void OpenSellPositionEMA(double lot)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action      = TRADE_ACTION_DEAL;
   req.symbol      = _Symbol;
   req.volume      = lot;
   req.type        = ORDER_TYPE_SELL;
   req.price       = price;
   req.sl          = 0.0;
   req.tp          = 0.0;
   req.magic       = EMAMagic();
   req.comment     = "EMA_X_SELL";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("EMA SELL OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("EMA SELL order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Close EMA position                                                |
//+------------------------------------------------------------------+
void CloseEMAPosition()
{
   ulong ticket = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==EMAMagic())
      { ticket = t; break; }
   }
   if(ticket==0) return;

   double lot = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.position = ticket;
   req.type     = (type==POSITION_TYPE_BUY)? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price    = (type==POSITION_TYPE_BUY)?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.magic    = EMAMagic();
   req.comment  = "EMA_X_Close";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("EMA Close OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("EMA Close not filled. Retcode=%d", res.retcode);
}
//+------------------------------------------------------------------+