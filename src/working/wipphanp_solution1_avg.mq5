//+------------------------------------------------------------------+
//|                                           wipphanp_solution1_avg.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.30"
#property strict

//------------------------------ INPUTS ------------------------------
// Original RSI-touch and trade inputs
input int    InpRSIPeriod        = 14;          // RSI period
input double InpBuyLevel         = 31.0;        // RSI level to trigger first BUY (cross-up)
input double InpSellLevel        = 69.0;        // RSI level to trigger first SELL (cross-up)
input double InpSellCloseLevel   = 35.0;        // RSI level to close SELL (cross-down)
input double InpBuyCloseLevel    = 63.0;        // RSI level to close BUY  (cross-down)
input double InpStopLoss         = 0;           // Stop-loss in points (0 = disabled)
input double InpTakeProfit       = 0;           // Take-profit in points (0 = disabled)
input int    InpMagicNumber      = 987654;      // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // chart timeframe for RSI

// New inputs for second RSI-based entries (pyramiding)
input double InpBaseLot          = 0.06;        // Base lot for first entry
input double InpSecondLotFactor  = 1.5;         // Multiplier for second entry lot
input double InpBuySecondRSI     = 18.0;        // Second BUY when RSI falls below this
input double InpSellSecondRSI    = 81.0;        // Second SELL when RSI rises above this

//--------------------------- GLOBALS -------------------------------
int      rsiHandle      = INVALID_HANDLE;   // iRSI indicator handle
double   prevRSI        = 0.0;              // RSI value from previous tick
bool     firstTick      = true;             // First tick flag

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
   // Create RSI handle for selected timeframe and period
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
//| Compute volume-weighted average entry price for type (BUY/SELL)  |
//| Only for this symbol and this magic number                       |
//+------------------------------------------------------------------+
bool GetAverageEntryPrice(ENUM_POSITION_TYPE typeWanted, double &avgPrice)
{
   double sumPriceVolume = 0.0;
   double sumVolume      = 0.0;

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

      double volume = PositionGetDouble(POSITION_VOLUME);
      double price  = PositionGetDouble(POSITION_PRICE_OPEN);

      sumPriceVolume += price * volume;
      sumVolume      += volume;
   }

   if(sumVolume <= 0.0)
      return(false);

   avgPrice = sumPriceVolume / sumVolume;
   return(true);
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

   //--- 3) Get counts of BUY/SELL positions
   int buyCount  = 0;
   int sellCount = 0;
   GetPositionCounts(buyCount, sellCount);

   //===============================================================
   // 4) AVERAGE-PRICE EXIT LOGIC WHEN TWO POSITIONS EXIST
   //    - If two BUYs exist: compute average BUY entry price.
   //      Exit all BUYs when current Bid goes ABOVE that average.
   //    - If two SELLs exist: compute average SELL entry price.
   //      Exit all SELLs when current Ask goes BELOW that average.
   //    - This works in addition to the original RSI-based exits.
   //===============================================================
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // BUY side: if we have exactly 2 BUY positions, check average exit
   if(buyCount == 2)
   {
      double avgBuyPrice = 0.0;
      if(GetAverageEntryPrice(POSITION_TYPE_BUY, avgBuyPrice))
      {
         // For BUYs: exit all when current Bid > average entry price
         if(bid > avgBuyPrice)
         {
            CloseAllPositionsOfType(POSITION_TYPE_BUY);
            // After this, BUY count becomes 0. New entries will be
            // taken again based on the normal RSI logic below.
         }
      }
   }

   // SELL side: if we have exactly 2 SELL positions, check average exit
   if(sellCount == 2)
   {
      double avgSellPrice = 0.0;
      if(GetAverageEntryPrice(POSITION_TYPE_SELL, avgSellPrice))
      {
         // For SELLs: exit all when current Ask < average entry price
         if(ask < avgSellPrice)
         {
            CloseAllPositionsOfType(POSITION_TYPE_SELL);
            // After this, SELL count becomes 0. New entries will be
            // taken again based on the normal RSI logic below.
         }
      }
   }

   // Recount after potential average-price exits
   GetPositionCounts(buyCount, sellCount);

   //===============================================================
   // 5) FIRST ENTRY LOGIC (original RSI "touch" entries)
   //    - First BUY when RSI crosses up InpBuyLevel from below.
   //    - First SELL when RSI crosses up InpSellLevel from below.
   //    - Only if no existing position of that direction.
   //===============================================================
   bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
   bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);

   // First BUY at RSI ~31 (cross up) – only if no existing BUYs
   if(crossUpBuy && buyCount == 0)
      OpenBuyPosition(InpBaseLot);

   // First SELL at RSI ~69 (cross up) – only if no existing SELLs
   if(crossUpSell && sellCount == 0)
      OpenSellPosition(InpBaseLot);

   //===============================================================
   // 6) SECOND ENTRY LOGIC (RSI goes further against first trade)
   //    - Second BUY: when we already have 1 BUY and RSI <= InpBuySecondRSI.
   //    - Second SELL: when we already have 1 SELL and RSI >= InpSellSecondRSI.
   //    - Only one extra entry per side (max 2 positions per direction).
   //===============================================================
   if(buyCount == 1 && rsi <= InpBuySecondRSI)
   {
      double lot2 = InpBaseLot * InpSecondLotFactor;
      OpenBuyPosition(lot2);
      // BUY count becomes 2 (max). No more BUYs beyond this.
   }

   if(sellCount == 1 && rsi >= InpSellSecondRSI)
   {
      double lot2 = InpBaseLot * InpSecondLotFactor;
      OpenSellPosition(lot2);
      // SELL count becomes 2 (max). No more SELLs beyond this.
   }

   //===============================================================
   // 7) ORIGINAL RSI-BASED EXIT LOGIC
   //    - Close all BUYs when RSI crosses down InpBuyCloseLevel (63).
   //    - Close all SELLs when RSI crosses down InpSellCloseLevel (35).
   //    - Works regardless of whether there is 1 or 2 positions.
   //===============================================================
   bool crossDownBuyExit  = (prevRSI > InpBuyCloseLevel)  && (rsi <= InpBuyCloseLevel);
   bool crossDownSellExit = (prevRSI > InpSellCloseLevel) && (rsi <= InpSellCloseLevel);

   if(buyCount > 0 && crossDownBuyExit)
      CloseAllPositionsOfType(POSITION_TYPE_BUY);

   if(sellCount > 0 && crossDownSellExit)
      CloseAllPositionsOfType(POSITION_TYPE_SELL);

   //--- 8) Store current RSI for next-tick cross detection
   prevRSI = rsi;
}
//+------------------------------------------------------------------+