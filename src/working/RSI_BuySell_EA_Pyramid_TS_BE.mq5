//+------------------------------------------------------------------+
//|                RSI_BuySell_EA_Pyramid_TS_BE.mq5                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict

//------------------------------ INPUTS ------------------------------
input int    InpRSIPeriod       = 14;          // RSI period
input double InpBuyLevel        = 30.0;       // RSI level to trigger BUY entry (cross-up)
input double InpSellLevel       = 70.0;       // RSI level to trigger SELL entry (cross-up)
input double InpSellCloseLevel  = 35.0;       // RSI level to close SELL (cross-down)
input double InpBuyCloseLevel   = 63.0;       // RSI level to close BUY  (cross-down)

// pyramiding levels (RSI extremes for second entry)
input double InpBuyDeepLevel    = 15.0;       // deeper RSI for 2nd BUY
input double InpSellDeepLevel   = 85.0;       // deeper RSI for 2nd SELL

// base risk params
input double InpStopLoss        = 0;          // Stop-loss in points (0 = disabled)
input double InpTakeProfit      = 0;          // Take-profit in points (0 = disabled)
input int    InpMagicNumber     = 987654;     // EA identifier
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // RSI timeframe

// trailing stop & BE
input bool   InpUseBreakEven    = true;       // use break-even
input double InpBETriggerPoints = 300;        // when profit >= this, move SL to BE
input double InpBEOffsetPoints  = 50;         // offset from BE (e.g. +5 pips)
input bool   InpUseTrailingStop = true;       // use trailing stop
input double InpTrailingDistance= 400;        // distance in points from price

//--------------------------- GLOBALS -------------------------------
int      rsiHandle   = INVALID_HANDLE;   // iRSI indicator handle
double   prevRSI     = 0.0;              // RSI value from previous tick
bool     firstTick   = true;

// tracking pyramid state
int      buyCount    = 0;                // how many BUY positions by this EA
int      sellCount   = 0;                // how many SELL positions by this EA
bool     beApplied   = false;           // break-even applied for current direction

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
   buyCount  = 0;
   sellCount = 0;
   beApplied = false;
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
//| Count positions per direction for this EA                        |
//+------------------------------------------------------------------+
void UpdatePositionCounts()
{
   buyCount  = 0;
   sellCount = 0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)  buyCount++;
      if(type == POSITION_TYPE_SELL) sellCount++;
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- get latest RSI
   double rsiBuffer[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0)
   {
      Print("CopyBuffer failed. Error=", GetLastError());
      return;
   }
   double rsi = rsiBuffer[0];

   //--- first tick init
   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   //--- update counts
   UpdatePositionCounts();
   bool hasBuy  = (buyCount  > 0);
   bool hasSell = (sellCount > 0);
   bool hasAny  = hasBuy || hasSell;

   //--- ENTRY LOGIC: pyramiding, max 2 per side, only one side at a time
   // BUY side
   if(!hasSell)  // only if no sells
   {
      bool crossUpBuy = (prevRSI < InpBuyLevel) && (rsi >= InpBuyLevel);
      bool deepBuy    = (rsi <= InpBuyDeepLevel);

      // first BUY
      if(crossUpBuy && buyCount==0)
      {
         OpenBuyPosition(0.05);   // first level lot
         beApplied = false;
      }
      // second BUY at deeper RSI
      if(deepBuy && buyCount==1)
      {
         OpenBuyPosition(0.09);   // second level lot
      }
   }

   // SELL side
   if(!hasBuy)   // only if no buys
   {
      bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);
      bool deepSell    = (rsi >= InpSellDeepLevel);

      // first SELL
      if(crossUpSell && sellCount==0)
      {
         OpenSellPosition(0.05);  // first level lot
         beApplied = false;
      }
      // second SELL at deeper RSI
      if(deepSell && sellCount==1)
      {
         OpenSellPosition(0.09);  // second level lot
      }
   }

   //--- EXIT LOGIC (RSI exits)
   if(hasAny)
   {
      // we check direction per existing positions (netting style assumption)
      ENUM_POSITION_TYPE posType = GetMainPositionType();

      bool crossDownBuyExit  = (prevRSI > InpBuyCloseLevel)  && (rsi <= InpBuyCloseLevel);
      bool crossDownSellExit = (prevRSI > InpSellCloseLevel) && (rsi <= InpSellCloseLevel);

      if(posType == POSITION_TYPE_BUY  && crossDownBuyExit)
      {
         CloseAllPositions();
         beApplied = false;
      }
      if(posType == POSITION_TYPE_SELL && crossDownSellExit)
      {
         CloseAllPositions();
         beApplied = false;
      }
   }

   //--- BE + Trailing management
   if(hasAny)
   {
      ManageBreakEvenAndTrailing();
   }

   //--- store RSI
   prevRSI = rsi;
}

//+------------------------------------------------------------------+
//| Get main position type (assumes single direction at a time)      |
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetMainPositionType()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   }
   return POSITION_TYPE_BUY; // default, won't be used if no positions
}

//+------------------------------------------------------------------+
//| Break-even and trailing stop management                          |
//+------------------------------------------------------------------+
void ManageBreakEvenAndTrailing()
{
   // For simplicity, manage all positions of this EA on this symbol
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double currentPrice =
         (type==POSITION_TYPE_BUY) ?
         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
         SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitPoints;
      if(type == POSITION_TYPE_BUY)
         profitPoints = (currentPrice - openPrice)/_Point;
      else
         profitPoints = (openPrice - currentPrice)/_Point;

      double newSL = sl;

      // Break-even
      if(InpUseBreakEven && !beApplied && InpBETriggerPoints>0)
      {
         if(profitPoints >= InpBETriggerPoints)
         {
            if(type == POSITION_TYPE_BUY)
               newSL = openPrice + InpBEOffsetPoints*_Point;
            else
               newSL = openPrice - InpBEOffsetPoints*_Point;
            beApplied = true;
         }
      }

      // Trailing stop
      if(InpUseTrailingStop && InpTrailingDistance>0)
      {
         double trailSL;
         if(type == POSITION_TYPE_BUY)
         {
            trailSL = currentPrice - InpTrailingDistance*_Point;
            if(trailSL > newSL)  // only move SL up
               newSL = trailSL;
         }
         else
         {
            trailSL = currentPrice + InpTrailingDistance*_Point;
            if(trailSL < newSL || newSL==0.0) // only move SL down (for sell)
               newSL = trailSL;
         }
      }

      // apply modification if SL changed significantly
      if(newSL != sl && newSL != 0.0)
      {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req); ZeroMemory(res);

         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = newSL;
         req.tp       = PositionGetDouble(POSITION_TP);
         req.magic    = InpMagicNumber;

         if(!OrderSend(req,res))
            PrintFormat("Modify SL failed. Error=%d",GetLastError());
         else if(res.retcode!=TRADE_RETCODE_DONE)
            PrintFormat("Modify SL not done. Retcode=%d",res.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if any position opened by this EA                          |
//+------------------------------------------------------------------+
bool PositionExists()
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
//| Open BUY with specified lot                                      |
//+------------------------------------------------------------------+
void OpenBuyPosition(double lot)
{
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
   req.comment     = "RSI_Pyramid_BUY";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("BUY OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("BUY order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Open SELL with specified lot                                     |
//+------------------------------------------------------------------+
void OpenSellPosition(double lot)
{
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
   req.comment     = "RSI_Pyramid_SELL";
   req.type_time   = ORDER_TIME_GTC;
   req.type_filling= ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
      PrintFormat("SELL OrderSend failed. Error=%d", GetLastError());
   else if(res.retcode!=TRADE_RETCODE_DONE)
      PrintFormat("SELL order not filled. Retcode=%d", res.retcode);
}

//+------------------------------------------------------------------+
//| Close all positions for this EA on this symbol                   |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req); ZeroMemory(res);

      req.action   = TRADE_ACTION_DEAL;
      req.symbol   = _Symbol;
      req.position = ticket;
      req.volume   = volume;
      req.type     = (type==POSITION_TYPE_BUY)? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price    = (type==POSITION_TYPE_BUY)?
                     SymbolInfoDouble(_Symbol,SYMBOL_BID):
                     SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      req.magic    = InpMagicNumber;
      req.comment  = "RSI_Pyramid_Close";
      req.type_time   = ORDER_TIME_GTC;
      req.type_filling= ORDER_FILLING_IOC;

      if(!OrderSend(req,res))
         PrintFormat("Close OrderSend failed. Error=%d", GetLastError());
      else if(res.retcode!=TRADE_RETCODE_DONE)
         PrintFormat("Close not filled. Retcode=%d", res.retcode);
   }
}
//+------------------------------------------------------------------+