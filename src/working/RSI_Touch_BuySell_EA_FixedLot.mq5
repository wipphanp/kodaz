//+------------------------------------------------------------------+
//|                RSI_Touch_BuySell_EA_FixedLot.mq5          |
//|                Copyright 2026, MetaQuotes Ltd.                  |
//|                                 https://www.mql5.com            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//------------------------------ INPUTS ------------------------------
input int    InpRSIPeriod      = 14;          // RSI period
input double InpBuyLevel       = 30.0;       // RSI level to trigger BUY entry (cross‑up)
input double InpSellLevel      = 70.0;       // RSI level to trigger SELL entry (cross‑up)
input double InpSellCloseLevel = 35.0;       // RSI level to close SELL (cross‑down)
input double InpBuyCloseLevel  = 63.0;       // RSI level to close BUY  (cross‑down)
input double InpStopLoss       = 0;          // Stop‑loss in points (0 = disabled)
input double InpTakeProfit     = 0;          // Take‑profit in points (0 = disabled)
input int    InpMagicNumber    = 987654;     // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // chart timeframe for RSI

//--------------------------- GLOBALS -------------------------------
int      rsiHandle   = INVALID_HANDLE;   // iRSI indicator handle
double   prevRSI     = 0.0;              // RSI value from previous tick
bool     firstTick   = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create the RSI indicator handle (no shift parameter)
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create iRSI handle. Error=", GetLastError());
      return(INIT_FAILED);
   }
   prevRSI = 0.0;
   firstTick = true;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1️⃣ Get latest RSI value from the indicator buffer
   double rsiBuffer[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
   {
      Print("CopyBuffer failed. Error=", GetLastError());
      return;
   }
   double rsi = rsiBuffer[0];

   //--- 2️⃣ Initialise on first tick
   if(firstTick)
   {
      prevRSI = rsi;
      firstTick = false;
      return;
   }

   //--- 3️⃣ Helper: any position already opened by this EA?
   bool positionExists = PositionExists();

   //--- 4️⃣ ENTRY LOGIC (only when flat)
   if(!positionExists)
   {
      // BUY entry: RSI crosses **up** through InpBuyLevel
      bool crossUpBuy   = (prevRSI < InpBuyLevel) && (rsi >= InpBuyLevel);
      // SELL entry: RSI crosses **up** through InpSellLevel
      bool crossUpSell  = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);

      if(crossUpBuy)   OpenBuyPosition();
      if(crossUpSell)  OpenSellPosition();
   }

   //--- 5️⃣ EXIT LOGIC (only if we have a position)
   if(positionExists)
   {
      ENUM_POSITION_TYPE posType = PositionGetInteger(POSITION_TYPE);

      // BUY exit: RSI crosses **down** through InpBuyCloseLevel
      bool crossDownBuyExit = (prevRSI > InpBuyCloseLevel) && (rsi <= InpBuyCloseLevel);
      // SELL exit: RSI crosses **down** through InpSellCloseLevel
      bool crossDownSellExit= (prevRSI > InpSellCloseLevel) && (rsi <= InpSellCloseLevel);

      if(posType==POSITION_TYPE_BUY && crossDownBuyExit)  ClosePosition();
      if(posType==POSITION_TYPE_SELL && crossDownSellExit)ClosePosition();
   }

   //--- 6️⃣ Store current RSI for next tick
   prevRSI = rsi;
}

//+------------------------------------------------------------------+
//| Helper: check if we already have a position opened by this EA   |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Helper: open a BUY market order (fixed lot 0.05)                 |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   const double lot = 0.05;               // <-- FIXED LOT SIZE
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl    = (InpStopLoss>0) ? price - InpStopLoss*_Point : 0.0;
   double tp    = (InpTakeProfit>0)? price + InpTakeProfit*_Point: 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.type     = ORDER_TYPE_BUY;
   req.price    = price;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = InpMagicNumber;
   req.comment  = "RSI_Touch_EA_BUY";
   req.type_time= ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("BUY OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("BUY order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Helper: open a SELL market order (fixed lot 0.05)                |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
   const double lot = 0.05;               // <-- FIXED LOT SIZE
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (InpStopLoss>0) ? price + InpStopLoss*_Point : 0.0;
   double tp    = (InpTakeProfit>0)? price - InpTakeProfit*_Point: 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.type     = ORDER_TYPE_SELL;
   req.price    = price;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = InpMagicNumber;
   req.comment  = "RSI_Touch_EA_SELL";
   req.type_time= ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("SELL OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("SELL order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Helper: close the current position (market)                      |
//+------------------------------------------------------------------+
void ClosePosition()
{
   ulong ticket = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
      { ticket = t; break; }
   }
   if(ticket==0) return;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   double lot = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.type     = (type==POSITION_TYPE_BUY)? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.position = ticket;
   req.price    = (type==POSITION_TYPE_BUY)?
                  SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.magic    = InpMagicNumber;
   req.comment  = "RSI_Touch_EA_Close";
   req.type_time= ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("Close OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("Close order not filled. Retcode=%d", res.retcode);
}
//+------------------------------------------------------------------+