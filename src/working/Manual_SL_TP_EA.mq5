//+------------------------------------------------------------------+
//|                 Manual_SL_TP_EA.mq5                               |
//|                     Simple SL/TP setter for manual trades       |
//|                        Copyright 2026, MetaQuotes Corp.          |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//--- include the Trade library for CTrade (order/modify functions)
#include <Trade\Trade.mqh>

//=== INPUT PARAMETERS =================================================
input double   InpLotSize      = 0.1;   // Lot size (informational only)
input ushort   InpStopLoss     = 150;   // Stop Loss in points
input ushort   InpTakeProfit   = 460;   // Take Profit in points
input ulong    InpMagic        = 200;   // Magic number to identify EA‑managed trades
input bool     InpModifyOnlyIfSameMagic = true; // Only modify positions with this magic

//=== GLOBAL OBJECTS ===================================================
CTrade        trade;          // Trading class for sending/modifying orders

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("Manual SL/TP EA initialized. SL=",InpStopLoss," pts, TP=",InpTakeProfit," pts");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("Manual SL/TP EA deinitialized.");
  }

//+------------------------------------------------------------------+
//| Expert tick function – runs every tick                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- we only care about positions on the current symbol
   long total = PositionsTotal();
   if(total<=0) return;

   for(int i=total-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      //--- verify symbol and (optionally) magic number
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(InpModifyOnlyIfSameMagic && PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      //--- current SL/TP of the position
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      //--- desired SL/TP based on inputs (in points)
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double newSL, newTP;

      if(type==POSITION_TYPE_BUY)
        {
         newSL = priceOpen - InpStopLoss*_Point;
         newTP = priceOpen + InpTakeProfit*_Point;
        }
      else // SELL
        {
         newSL = priceOpen + InpStopLoss*_Point;
         newTP = priceOpen - InpTakeProfit*_Point;
        }

      //--- modify only if SL or TP differs from the desired values
      if(MathAbs(curSL-newSL)>_Point || MathAbs(curTP-newTP)>_Point)
        {
         if(!trade.PositionModify(ticket, newSL, newTP))
            Print("PositionModify failed for ticket ",ticket,". Error:",trade.ResultRetcode());
         else
            Print("Modified ticket ",ticket,
                  " SL from ",DoubleToString(curSL,_Digits)," to ",DoubleToString(newSL,_Digits),
                  " TP from ",DoubleToString(curTP,_Digits)," to ",DoubleToString(newTP,_Digits));
        }
     }
  }
//+------------------------------------------------------------------+