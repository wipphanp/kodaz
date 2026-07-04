//+------------------------------------------------------------------+
//|                RSI_BuySell_EA_V2.mq5                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property strict

//------------------------------ INPUTS ------------------------------
input int    InpRSIPeriod      = 14;          // RSI period
input double InpBuyLevel       = 30.0;       // RSI level to trigger FIRST BUY (cross-up)
input double InpSellLevel      = 69.0;       // RSI level to trigger FIRST SELL (cross-up)
input double InpBuyAddLevel    = 18.0;       // RSI level to trigger SECOND BUY (<=)
input double InpSellAddLevel   = 85.0;       // RSI level to trigger SECOND SELL (>=)
input double InpSellCloseLevel = 36.0;       // RSI level to close SELL basket (cross-down)
input double InpBuyCloseLevel  = 63.0;       // RSI level to close BUY basket (cross-down)
input double InpStopLoss       = 0;          // Stop-loss in points (0 = disabled)
input double InpTakeProfit     = 0;          // Take-profit in points (0 = disabled)
input int    InpMagicNumber    = 987654;     // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // RSI timeframe

//--------------------------- GLOBALS -------------------------------
int      rsiHandle   = INVALID_HANDLE;   // iRSI indicator handle
double   prevRSI     = 0.0;              // previous RSI value
bool     firstTick   = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create iRSI handle. Error=",
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
//| Count positions for this EA                                      |
//+------------------------------------------------------------------+
int CountPositionsByType(ENUM_POSITION_TYPE type)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==type)
      {
         count++;
      }
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Count all positions for this EA (any direction)                  |
//+------------------------------------------------------------------+
int CountAllPositions()
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
      {
         count++;
      }
   }
   return(count);
}

//+------------------------------------------------------------------+
//| Get total volume for BUY or SELL                                 |
//+------------------------------------------------------------------+
double TotalVolumeByType(ENUM_POSITION_TYPE type)
{
   double vol = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==type)
      {
         vol += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return(vol);
}

//+------------------------------------------------------------------+
//| Close all positions of given type (BUY or SELL)                  |
//+------------------------------------------------------------------+
void CloseAllOfType(ENUM_POSITION_TYPE type)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelect(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber &&
         PositionGetInteger(POSITION_TYPE)==type)
      {
         double lot   = PositionGetDouble(POSITION_VOLUME);
         double price = (type==POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         MqlTradeRequest  req;
         MqlTradeResult   res;
         ZeroMemory(req); ZeroMemory(res);

         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = _Symbol;
         req.volume       = lot;
         req.type         = (type==POSITION_TYPE_BUY ?
                             ORDER_TYPE_SELL : ORDER_TYPE_BUY);
         req.position     = ticket;
         req.price        = price;
         req.magic        = InpMagicNumber;
         req.type_time    = ORDER_TIME_GTC;
         req.type_filling = ORDER_FILLING_IOC;

         if(!OrderSend(req,res))
         {
            Print("CloseAllOfType: OrderSend failed, error=",
                  IntegerToString(GetLastError()));
         }
         else if(res.retcode!=TRADE_RETCODE_DONE)
         {
            Print("CloseAllOfType: close not done, retcode=",
                  IntegerToString((int)res.retcode));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open BUY with specified volume                                   |
//+------------------------------------------------------------------+
void OpenBuy(double lot)
{
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
   req.comment      = "RSI_EA_BUY";
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
   {
      Print("OpenBuy: OrderSend failed, error=",
            IntegerToString(GetLastError()));
   }
   else if(res.retcode!=TRADE_RETCODE_DONE)
   {
      Print("OpenBuy: order not done, retcode=",
            IntegerToString((int)res.retcode));
   }
}

//+------------------------------------------------------------------+
//| Open SELL with specified volume                                  |
//+------------------------------------------------------------------+
void OpenSell(double lot)
{
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
   req.comment      = "RSI_EA_SELL";
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
   {
      Print("OpenSell: OrderSend failed, error=",
            IntegerToString(GetLastError()));
   }
   else if(res.retcode!=TRADE_RETCODE_DONE)
   {
      Print("OpenSell: order not done, retcode=",
            IntegerToString((int)res.retcode));
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Get latest RSI
   double rsiBuffer[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
   {
      Print("CopyBuffer failed. Error=",
            IntegerToString(GetLastError()));
      return;
   }
   double rsi = rsiBuffer[0];

   // 2) Init prevRSI on first tick
   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   // Position counts by direction
   int buyCount  = CountPositionsByType(POSITION_TYPE_BUY);
   int sellCount = CountPositionsByType(POSITION_TYPE_SELL);
   int totalPos  = buyCount + sellCount;

   // 3) ENTRY LOGIC

   // A) First BUY: RSI cross up through InpBuyLevel, no positions
   bool crossUpBuy = (prevRSI < InpBuyLevel) && (rsi >= InpBuyLevel);
   if(crossUpBuy && totalPos == 0)
   {
      // first BUY lot always 0.03
      OpenBuy(0.03);
   }

   // B) First SELL: RSI cross up through InpSellLevel, no positions
   bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);
   if(crossUpSell && totalPos == 0)
   {
      // first SELL lot always 0.03
      OpenSell(0.03);
   }

   // C) Second BUY: RSI <= InpBuyAddLevel, we already have BUY and no SELL,
   // and total positions < 2
   if(rsi <= InpBuyAddLevel &&
      buyCount > 0 && sellCount == 0 &&
      totalPos < 2)
   {
      double vol = TotalVolumeByType(POSITION_TYPE_BUY);
      // Expect vol == 0.03, next lot is twice: 0.06
      double addLot = 2.0 * vol;
      // Just in case user changed volume manually, still double it
      OpenBuy(addLot);
   }

   // D) Second SELL: RSI >= InpSellAddLevel, we already have SELL and no BUY,
   // and total positions < 2
   if(rsi >= InpSellAddLevel &&
      sellCount > 0 && buyCount == 0 &&
      totalPos < 2)
   {
      double vol = TotalVolumeByType(POSITION_TYPE_SELL);
      double addLot = 2.0 * vol;  // from 0.03 to 0.06
      OpenSell(addLot);
   }

   // 4) EXIT LOGIC

   // Close BUY basket when RSI crosses down InpBuyCloseLevel
   bool crossDownBuyExit = (prevRSI > InpBuyCloseLevel) &&
                           (rsi <= InpBuyCloseLevel);
   if(buyCount > 0 && crossDownBuyExit)
   {
      CloseAllOfType(POSITION_TYPE_BUY);
   }

   // Close SELL basket when RSI crosses down InpSellCloseLevel
   bool crossDownSellExit = (prevRSI > InpSellCloseLevel) &&
                            (rsi <= InpSellCloseLevel);
   if(sellCount > 0 && crossDownSellExit)
   {
      CloseAllOfType(POSITION_TYPE_SELL);
   }

   // 5) Store RSI for next tick
   prevRSI = rsi;
}
//+------------------------------------------------------------------+