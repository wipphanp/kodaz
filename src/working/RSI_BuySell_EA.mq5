//+------------------------------------------------------------------+
//|                RSI_BuySell_EA.mq5                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.05"
#property strict

//------------------------------ INPUTS ------------------------------
input int    InpRSIPeriod      = 14;          // RSI period
input double InpBuyLevel       = 30.0;       // RSI level to trigger BUY entry (cross‑up)
input double InpSellLevel      = 70.0;       // RSI level to trigger SELL entry (cross‑up)
input double InpSellCloseLevel = 35.0;       // RSI level to help close SELL (optional filter)
input double InpBuyCloseLevel  = 63.0;       // RSI level to help close BUY  (optional filter)
input double InpStopLoss       = 0;          // Stop‑loss in points (0 = disabled)
input double InpTakeProfit     = 0;          // Take‑profit in points (0 = disabled, basket TP used)
input int    InpMagicNumber    = 987654;     // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // chart timeframe for RSI

// --- Grid / basket inputs
input int    InpMaxBuyPositions      = 3;     // Max BUY positions in basket
input int    InpMaxSellPositions     = 3;     // Max SELL positions in basket
input int    InpGridPoints           = 150;   // Distance between entries (points)
input int    InpBasketProfitPoints   = 80;    // Basket TP in points
input bool   InpUseRsiBasketFilter   = true;  // Use RSI as filter for basket close

//--------------------------- GLOBALS -------------------------------
int      rsiHandle   = INVALID_HANDLE;   // iRSI indicator handle
double   prevRSI     = 0.0;              // RSI value from previous tick
bool     firstTick   = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create iRSI handle. Error=" +
            IntegerToString(GetLastError()));
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
//| Helper: check if any position exists for this EA                 |
//+------------------------------------------------------------------+
bool PositionExists()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Count BUY positions                                              |
//+------------------------------------------------------------------+
int CountBuyPositions()
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Count SELL positions                                             |
//+------------------------------------------------------------------+
int CountSellPositions()
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
         count++;
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Get price of most recent BUY                                     |
//+------------------------------------------------------------------+
double LastBuyPrice()
{
   double   lastPrice = 0.0;
   datetime lastTime  = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
      {
         datetime opentime = (datetime)PositionGetInteger(POSITION_TIME);
         if(opentime >= lastTime)
         {
            lastTime  = opentime;
            lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }
   return(lastPrice);
}

//+------------------------------------------------------------------+
//| Get price of most recent SELL                                    |
//+------------------------------------------------------------------+
double LastSellPrice()
{
   double   lastPrice = 0.0;
   datetime lastTime  = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
      {
         datetime opentime = (datetime)PositionGetInteger(POSITION_TIME);
         if(opentime >= lastTime)
         {
            lastTime  = opentime;
            lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }
   return(lastPrice);
}

//+------------------------------------------------------------------+
//| Basket floating profit BUY in points                             |
//+------------------------------------------------------------------+
double BasketProfitPointsBuy()
{
   double profitMoney = 0.0;
   double volume      = 0.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
      {
         profitMoney += PositionGetDouble(POSITION_PROFIT);
         volume      += PositionGetDouble(POSITION_VOLUME);
      }
   }

   if(volume <= 0.0)
      return(0.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);

   double pointsPerTick = tickSize / _Point;
   double profitPoints  = profitMoney / (tickValue * volume) * pointsPerTick;

   return(profitPoints);
}

//+------------------------------------------------------------------+
//| Basket floating profit SELL in points                            |
//+------------------------------------------------------------------+
double BasketProfitPointsSell()
{
   double profitMoney = 0.0;
   double volume      = 0.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
      {
         profitMoney += PositionGetDouble(POSITION_PROFIT);
         volume      += PositionGetDouble(POSITION_VOLUME);
      }
   }

   if(volume <= 0.0)
      return(0.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);

   double pointsPerTick = tickSize / _Point;
   double profitPoints  = profitMoney / (tickValue * volume) * pointsPerTick;

   return(profitPoints);
}

//+------------------------------------------------------------------+
//| Close all BUY positions                                          |
//+------------------------------------------------------------------+
void CloseAllBuyPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
      {
         double lot   = PositionGetDouble(POSITION_VOLUME);
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         MqlTradeRequest  req;
         MqlTradeResult   res;
         ZeroMemory(req); ZeroMemory(res);

         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = _Symbol;
         req.volume       = lot;
         req.type         = ORDER_TYPE_SELL;
         req.position     = ticket;
         req.price        = price;
         req.magic        = InpMagicNumber;
         req.type_time    = ORDER_TIME_GTC;
         req.type_filling = ORDER_FILLING_IOC;

         if(!OrderSend(req,res))
         {
            Print("CloseAllBuyPositions: OrderSend failed, error=" +
                  IntegerToString(GetLastError()));
         }
         else if(res.retcode!=TRADE_RETCODE_DONE)
         {
            Print("CloseAllBuyPositions: order not done, retcode=" +
                  IntegerToString((int)res.retcode));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all SELL positions                                         |
//+------------------------------------------------------------------+
void CloseAllSellPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
      {
         double lot   = PositionGetDouble(POSITION_VOLUME);
         double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         MqlTradeRequest  req;
         MqlTradeResult   res;
         ZeroMemory(req); ZeroMemory(res);

         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = _Symbol;
         req.volume       = lot;
         req.type         = ORDER_TYPE_BUY;
         req.position     = ticket;
         req.price        = price;
         req.magic        = InpMagicNumber;
         req.type_time    = ORDER_TIME_GTC;
         req.type_filling = ORDER_FILLING_IOC;

         if(!OrderSend(req,res))
         {
            Print("CloseAllSellPositions: OrderSend failed, error=" +
                  IntegerToString(GetLastError()));
         }
         else if(res.retcode!=TRADE_RETCODE_DONE)
         {
            Print("CloseAllSellPositions: order not done, retcode=" +
                  IntegerToString((int)res.retcode));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open BUY (same lot as original)                                  |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   const double lot = 0.05;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl    = (InpStopLoss>0)  ? price - InpStopLoss*_Point : 0.0;
   double tp    = (InpTakeProfit>0)? price + InpTakeProfit*_Point: 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

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

   if(!OrderSend(req,res))
   {
      Print("OpenBuyPosition: OrderSend failed, error=" +
            IntegerToString(GetLastError()));
   }
   else if(res.retcode!=TRADE_RETCODE_DONE)
   {
      Print("OpenBuyPosition: order not done, retcode=" +
            IntegerToString((int)res.retcode));
   }
}

//+------------------------------------------------------------------+
//| Open SELL (same lot as original)                                 |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
   const double lot = 0.05;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (InpStopLoss>0)  ? price + InpStopLoss*_Point : 0.0;
   double tp    = (InpTakeProfit>0)? price - InpTakeProfit*_Point: 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

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

   if(!OrderSend(req,res))
   {
      Print("OpenSellPosition: OrderSend failed, error=" +
            IntegerToString(GetLastError()));
   }
   else if(res.retcode!=TRADE_RETCODE_DONE)
   {
      Print("OpenSellPosition: order not done, retcode=" +
            IntegerToString((int)res.retcode));
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) RSI
   double rsiBuffer[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
   {
      Print("CopyBuffer failed. Error=" +
            IntegerToString(GetLastError()));
      return;
   }
   double rsi = rsiBuffer[0];

   // 2) First tick init
   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   int  buyCount  = CountBuyPositions();
   int  sellCount = CountSellPositions();
   bool anyPos    = PositionExists();

   // 3) ENTRY LOGIC: only when flat
   if(!anyPos)
   {
      bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
      bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);

      if(crossUpBuy)
         OpenBuyPosition();
      else if(crossUpSell)
         OpenSellPosition();
   }
   else
   {
      // 4) BUY grid add
      if(buyCount > 0 && buyCount < InpMaxBuyPositions)
      {
         double lastBuy = LastBuyPrice();
         if(lastBuy > 0.0 && bid <= lastBuy - InpGridPoints*_Point)
            OpenBuyPosition();
      }

      // 5) SELL grid add
      if(sellCount > 0 && sellCount < InpMaxSellPositions)
      {
         double lastSell = LastSellPrice();
         if(lastSell > 0.0 && ask >= lastSell + InpGridPoints*_Point)
            OpenSellPosition();
      }

      // 6) Basket TP BUY
      if(buyCount > 0)
      {
         double basketBuyPoints = BasketProfitPointsBuy();
         bool rsiOkBuy = (!InpUseRsiBasketFilter) || (rsi >= InpBuyCloseLevel);

         if(basketBuyPoints >= InpBasketProfitPoints && rsiOkBuy)
            CloseAllBuyPositions();
      }

      // 7) Basket TP SELL
      if(sellCount > 0)
      {
         double basketSellPoints = BasketProfitPointsSell();
         bool rsiOkSell = (!InpUseRsiBasketFilter) || (rsi <= InpSellCloseLevel);

         if(basketSellPoints >= InpBasketProfitPoints && rsiOkSell)
            CloseAllSellPositions();
      }
   }

   // 8) Store RSI for next tick
   prevRSI = rsi;
}
//+------------------------------------------------------------------+