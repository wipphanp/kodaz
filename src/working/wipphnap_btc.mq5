//+------------------------------------------------------------------+
//|                                                 wipphnap_btc.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//|                               wipphanp_solution1_avg_ext.mq5     |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.52"
#property strict

//------------------------------ INPUTS ------------------------------
// Original RSI-touch and trade inputs
input int    InpRSIPeriod        = 14;          // RSI period
input double InpBuyLevel         = 32.4;        // RSI level to trigger first BUY (cross-up)
input double InpSellLevel        = 68.81;       // RSI level to trigger first SELL (cross-up)
input double InpSellCloseLevel   = 36.36;       // RSI level to close SELL (cross-down)
input double InpBuyCloseLevel    = 63.63;       // RSI level to close BUY  (cross-down)
input double InpStopLoss         = 0;           // Stop-loss in points (0 = disabled)
input double InpTakeProfit       = 0;           // Take-profit in points (0 = disabled)
input int    InpMagicNumber      = 987654;      // EA identifier (magic for EA trades)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // chart timeframe for RSI

// New inputs for second RSI-based entries (pyramiding)
// First entry fixed 0.3; second entry = 2x first (0.6)
input double InpBaseLot          = 0.3;         // Base lot for first entry
input double InpSecondLotFactor  = 2.0;         // Multiplier for second entry lot (2x base)
input double InpBuySecondRSI     = 18.18;       // Second BUY when RSI falls below this
input double InpSellSecondRSI    = 81.81;       // Second SELL when RSI rises above this

// Manual-trade TP input (money-based)
input double InpManualTPMoney    = 18.18;       // Target profit in account currency per manual/other position

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
//| Get counts of BUY/SELL positions for this symbol & EA magic      |
//| Manual trades (different magic, typically 0) are ignored here.   |
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

      // Only count EA trades (by magic)
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
//| Compute volume-weighted average entry price for EA trades        |
//| Only for this symbol and this EA's magic number                  |
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

      // Only EA positions (manual trades excluded)
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
//| Close all EA positions of given type (this symbol & magic)       |
//| Manual positions are not touched here.                           |
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

      // Only EA positions (manual trades excluded)
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
//| Open a BUY market order with specified lot (EA trade)            |
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
   req.magic        = InpMagicNumber;           // EA magic
   req.comment      = "RSI_Touch_EA_BUY";
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      PrintFormat("BUY OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode != TRADE_RETCODE_DONE)
      PrintFormat("BUY order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Open a SELL market order with specified lot (EA trade)           |
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
   req.magic        = InpMagicNumber;           // EA magic
   req.comment      = "RSI_Touch_EA_SELL";
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req, res))
      PrintFormat("SELL OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode != TRADE_RETCODE_DONE)
      PrintFormat("SELL order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Handle non-EA trades: TP in account currency                     |
//| Here: any trade with magic != InpMagicNumber is managed          |
//| with money-based TP InpManualTPMoney and closed at target.       |
//+------------------------------------------------------------------+
void ManageManualTrades()
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      string sym  = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol)
         continue;

      long magic  = (long)PositionGetInteger(POSITION_MAGIC);

      // Skip EA trades; only process others (manual / other EAs)
      if(magic == InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double volume = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap   = PositionGetDouble(POSITION_SWAP);

      // Net profit excluding commission
      double netProfit = profit + swap;

      if(netProfit >= InpManualTPMoney)
      {
         double closePrice;
         if(type == POSITION_TYPE_BUY)
            closePrice = SymbolInfoDouble(sym, SYMBOL_BID);
         else
            closePrice = SymbolInfoDouble(sym, SYMBOL_ASK);

         MqlTradeRequest  clsReq;
         MqlTradeResult   clsRes;
         ZeroMemory(clsReq);
         ZeroMemory(clsRes);

         clsReq.action   = TRADE_ACTION_DEAL;
         clsReq.symbol   = sym;
         clsReq.position = ticket;
         clsReq.volume   = volume;
         clsReq.type     = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL
                                                       : ORDER_TYPE_BUY;
         clsReq.price    = closePrice;
         clsReq.type_time    = ORDER_TIME_GTC;
         clsReq.type_filling = ORDER_FILLING_IOC;
         clsReq.comment      = "Manual_MoneyTP_Close";

         if(!OrderSend(clsReq, clsRes))
            PrintFormat("Manual close failed. Ticket=%I64u Error=%d", ticket, GetLastError());
         else if(clsRes.retcode != TRADE_RETCODE_DONE)
            PrintFormat("Manual close not filled. Ticket=%I64u Retcode=%d", ticket, clsRes.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- A) ALWAYS HANDLE NON-EA TRADES FIRST (manual / other magic)
   ManageManualTrades();

   //--- 1) Get latest RSI value (for EA logic)
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

   //--- 3) Get counts of BUY/SELL positions for EA only
   int buyCount  = 0;
   int sellCount = 0;
   GetPositionCounts(buyCount, sellCount);

   //===============================================================
   // 4) AVERAGE-PRICE EXIT LOGIC WHEN TWO EA POSITIONS EXIST
   //===============================================================
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(buyCount == 2)
   {
      double avgBuyPrice = 0.0;
      if(GetAverageEntryPrice(POSITION_TYPE_BUY, avgBuyPrice))
      {
         if(bid > avgBuyPrice)
            CloseAllPositionsOfType(POSITION_TYPE_BUY);
      }
   }

   if(sellCount == 2)
   {
      double avgSellPrice = 0.0;
      if(GetAverageEntryPrice(POSITION_TYPE_SELL, avgSellPrice))
      {
         if(ask < avgSellPrice)
            CloseAllPositionsOfType(POSITION_TYPE_SELL);
      }
   }

   // Recount after potential average-price exits
   GetPositionCounts(buyCount, sellCount);

   //===============================================================
   // 5) FIRST ENTRY LOGIC (RSI "touch" entries for EA)
   //    First lot = InpBaseLot (0.3 as per your request).
   //===============================================================
   bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
   bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);

   if(crossUpBuy && buyCount == 0)
      OpenBuyPosition(InpBaseLot);

   if(crossUpSell && sellCount == 0)
      OpenSellPosition(InpBaseLot);

   //===============================================================
   // 6) SECOND ENTRY LOGIC (RSI goes further against first EA trade)
   //    Second lot = InpBaseLot * InpSecondLotFactor = 0.3 * 2 = 0.6.
   //===============================================================
   if(buyCount == 1 && rsi <= InpBuySecondRSI)
   {
      double lot2 = InpBaseLot * InpSecondLotFactor;
      OpenBuyPosition(lot2);
   }

   if(sellCount == 1 && rsi >= InpSellSecondRSI)
   {
      double lot2 = InpBaseLot * InpSecondLotFactor;
      OpenSellPosition(lot2);
   }

   //===============================================================
   // 7) RSI-BASED EXIT LOGIC FOR EA TRADES
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