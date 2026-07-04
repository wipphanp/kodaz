//+------------------------------------------------------------------+
//|                RSI_Touch_BuySell_EA_MultiPosition.mq5            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.11"
#property strict

//------------------------------ INPUTS ------------------------------
input int    InpRSIPeriod        = 14;          // RSI period
input double InpBuyLevel         = 30.0;        // RSI level to trigger BUY entry (cross-up)
input double InpSellLevel        = 70.0;        // RSI level to trigger SELL entry (cross-up)
input double InpSellCloseLevel   = 35.0;        // RSI level to close SELL (cross-down)
input double InpBuyCloseLevel    = 63.0;        // RSI level to close BUY  (cross-down)
input double InpStopLoss         = 0;           // Stop-loss in points (0 = disabled)
input double InpTakeProfit       = 0;           // Take-profit in points (0 = disabled)
input int    InpMagicNumber      = 987654;      // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // chart timeframe for RSI

// New inputs for multi-position logic
input double InpBaseLot          = 0.05;        // Base lot for first entry
input double InpSecondLotFactor  = 1.5;         // Multiplier for second entry lot
input double InpAddDistancePts   = 10.0;        // Distance in points to add 2nd position

//--------------------------- GLOBALS -------------------------------
int      rsiHandle   = INVALID_HANDLE;   // iRSI indicator handle
double   prevRSI     = 0.0;              // RSI value from previous tick
bool     firstTick   = true;

//+------------------------------------------------------------------+
//| Normalize lot to broker's step/min/max                           |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   if(stepLot > 0.0)
      lot = MathFloor(lot / stepLot) * stepLot;

   return(lot);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create iRSI handle. Error=", GetLastError());
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
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1) Get latest RSI value
   double rsiBuffer[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
   {
      Print("CopyBuffer failed. Error=", GetLastError());
      return;
   }
   double rsi = rsiBuffer[0];

   //--- 2) Initialise on first tick
   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   //--- 3) Get count of positions for this EA and symbol
   int buyCount  = 0;
   int sellCount = 0;
   GetPositionCounts(buyCount, sellCount);

   //--- 4) ENTRY LOGIC (first entries on RSI touch)
   bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
   bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);

   if(crossUpBuy && buyCount == 0)
      OpenBuyPosition(InpBaseLot);

   if(crossUpSell && sellCount == 0)
      OpenSellPosition(InpBaseLot);

   //--- 5) SECOND ENTRY LOGIC (averaging in)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Second BUY if price moved down by InpAddDistancePts from first BUY
   if(buyCount == 1)
   {
      double firstBuyPrice = GetFirstEntryPrice(POSITION_TYPE_BUY);
      if(firstBuyPrice > 0.0)
      {
         double distancePts = (firstBuyPrice - ask) / _Point;
         if(distancePts >= InpAddDistancePts)
         {
            double lot2 = InpBaseLot * InpSecondLotFactor;
            OpenBuyPosition(lot2);
         }
      }
   }

   // Second SELL if price moved up by InpAddDistancePts from first SELL
   if(sellCount == 1)
   {
      double firstSellPrice = GetFirstEntryPrice(POSITION_TYPE_SELL);
      if(firstSellPrice > 0.0)
      {
         double distancePts = (bid - firstSellPrice) / _Point;
         if(distancePts >= InpAddDistancePts)
         {
            double lot2 = InpBaseLot * InpSecondLotFactor;
            OpenSellPosition(lot2);
         }
      }
   }

   //--- 6) EXIT LOGIC (RSI cross-down)
   if(buyCount > 0 || sellCount > 0)
   {
      bool crossDownBuyExit  = (prevRSI > InpBuyCloseLevel)  && (rsi <= InpBuyCloseLevel);
      bool crossDownSellExit = (prevRSI > InpSellCloseLevel) && (rsi <= InpSellCloseLevel);

      if(buyCount > 0 && crossDownBuyExit)
         CloseAllPositionsOfType(POSITION_TYPE_BUY);

      if(sellCount > 0 && crossDownSellExit)
         CloseAllPositionsOfType(POSITION_TYPE_SELL);
   }

   //--- 7) Store current RSI
   prevRSI = rsi;
}

//+------------------------------------------------------------------+
//| Get counts of BUY/SELL positions for this symbol & magic         |
//+------------------------------------------------------------------+
void GetPositionCounts(int &buyCount, int &sellCount)
{
   buyCount  = 0;
   sellCount = 0;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
         buyCount++;
      else if(type == POSITION_TYPE_SELL)
         sellCount++;
   }
}

//+------------------------------------------------------------------+
//| Get entry price of the first position of given type              |
//+------------------------------------------------------------------+
double GetFirstEntryPrice(ENUM_POSITION_TYPE typeWanted)
{
   double   price      = 0.0;
   datetime oldestTime = INT_MAX;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type != typeWanted)
         continue;

      datetime opentime   = (datetime)PositionGetInteger(POSITION_TIME);
      double   entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(opentime < oldestTime)
      {
         oldestTime = opentime;
         price      = entryPrice;
      }
   }
   return(price);
}

//+------------------------------------------------------------------+
//| Open a BUY market order with specified lot                       |
//+------------------------------------------------------------------+
void OpenBuyPosition(double lot)
{
   if(lot <= 0.0)
      return;

   lot = NormalizeLot(lot);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl    = (InpStopLoss  > 0) ? price - InpStopLoss  * _Point : 0.0;
   double tp    = (InpTakeProfit> 0) ? price + InpTakeProfit* _Point : 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = ORDER_TYPE_BUY;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.magic        = InpMagicNumber;
   req.comment      = "RSI_Touch_EA_BUY";
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      PrintFormat("BUY OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode != TRADE_RETCODE_DONE)
      PrintFormat("BUY order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Open a SELL market order with specified lot                      |
//+------------------------------------------------------------------+
void OpenSellPosition(double lot)
{
   if(lot <= 0.0)
      return;

   lot = NormalizeLot(lot);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (InpStopLoss  > 0) ? price + InpStopLoss  * _Point : 0.0;
   double tp    = (InpTakeProfit> 0) ? price - InpTakeProfit* _Point : 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = ORDER_TYPE_SELL;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.magic        = InpMagicNumber;
   req.comment      = "RSI_Touch_EA_SELL";
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      PrintFormat("SELL OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode != TRADE_RETCODE_DONE)
      PrintFormat("SELL order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Close all positions of given type for this symbol & magic        |
//+------------------------------------------------------------------+
void CloseAllPositionsOfType(ENUM_POSITION_TYPE typeWanted)
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type != typeWanted)
         continue;

      double lot = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest  req;
      MqlTradeResult   res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = lot;
      req.position     = ticket;
      req.type         = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL
                                                     : ORDER_TYPE_BUY;
      req.price        = (type == POSITION_TYPE_BUY)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.magic        = InpMagicNumber;
      req.comment      = "RSI_Touch_EA_Close";
      req.type_time    = ORDER_TIME_GTC;
      req.type_filling = ORDER_FILLING_IOC;

      if(!OrderSend(req, res))
         PrintFormat("Close OrderSend failed. Error=%d", GetLastError());
      else if(res.retcode != TRADE_RETCODE_DONE)
         PrintFormat("Close order not filled. Retcode=%d", res.retcode);
   }
}
//+------------------------------------------------------------------+