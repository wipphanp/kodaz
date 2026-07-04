//+------------------------------------------------------------------+
//|                                          SimpleMA_EA_TP_SL.mq5 |
//|                        Copyright 2026, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//--- include the Trade library so CTrade is known
#include <Trade\Trade.mqh>

//--- input parameters (adjustable from the EA settings)
input int    InpFastMAPeriod   = 12;   // Fast MA period
input int    InpSlowMAPeriod   = 26;   // Slow MA period
input ENUM_MA_METHOD InpMAMethod = MODE_SMA; // MA method (SMA, EMA, SMMA, LWMA)
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // Applied price
input double InpLotSize        = 0.1;  // Lot size per trade
input ushort InpStopLoss       = 150;  // Stop Loss in points
input ushort InpTakeProfit     = 460;  // Take Profit in points
input ulong  InpMagic          = 200;  // Magic number to identify EA trades
input bool   InpTradeBothDirections = true; // Allow both buy and sell

//--- global objects
CTrade        trade;          // Trading class for sending orders
int           fastMA_handle;  // Handle for fast moving average
int           slowMA_handle;  // Handle for slow moving average
double        fastMA[];       // Buffer for fast MA values
double        slowMA[];       // Buffer for slow MA values

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- create moving average indicators
   fastMA_handle = iMA(_Symbol, PERIOD_CURRENT, InpFastMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   slowMA_handle = iMA(_Symbol, PERIOD_CURRENT, InpSlowMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   
   //--- check indicator creation
   if(fastMA_handle==INVALID_HANDLE || slowMA_handle==INVALID_HANDLE)
     {
      Print("Failed to create MA handles. Error:",GetLastError());
      return(INIT_FAILED);
     }
   
   //--- set array size for copying values
   ArraySetAsSeries(fastMA,true);
   ArraySetAsSeries(slowMA,true);
   
   Print("SimpleMA EA initialized. FastMA(",InpFastMAPeriod,"), SlowMA(",InpSlowMAPeriod,")");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- release indicator handles
   if(fastMA_handle!=INVALID_HANDLE) IndicatorRelease(fastMA_handle);
   if(slowMA_handle!=INVALID_HANDLE) IndicatorRelease(slowMA_handle);
   Print("SimpleMA EA deinitialized.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- wait for a new bar to avoid multiple signals on the same tick
   static datetime last_bar_time=0;
   datetime current_bar_time=iTime(_Symbol,PERIOD_CURRENT,0);
   if(last_bar_time==current_bar_time) return;
   last_bar_time=current_bar_time;
   
   //--- copy latest MA values
   if(CopyBuffer(fastMA_handle,0,0,2,fastMA)<=0 ||
      CopyBuffer(slowMA_handle,0,0,2,slowMA)<=0)
     {
      Print("Failed to copy MA data. Error:",GetLastError());
      return;
     }
   
   //--- check for crossover (fast MA crossing slow MA)
   bool buySignal  = (fastMA[1]<=slowMA[1] && fastMA[0]>slowMA[0]); // bullish cross
   bool sellSignal = (fastMA[1]>=slowMA[1] && fastMA[0]<slowMA[0]); // bearish cross
   
   //--- only trade if we have no opposite position (simple approach)
   // Count existing positions for this symbol and magic number
   long buys=0, sells=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) buys++;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL) sells++;
     }
   
   //--- BUY logic
   if(buySignal && (InpTradeBothDirections || sells==0))
     {
      // Close any opposite sells first (optional)
      if(sells>0) CloseOpposite(POSITION_TYPE_SELL);
      
      double price   = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl      = price - InpStopLoss*_Point;
      double tp      = price + InpTakeProfit*_Point;
      
      if(!trade.Buy(InpLotSize,_Symbol,price,sl,tp))
         Print("Buy order failed. Error:",trade.ResultRetcode());
      else
         Print("Buy opened: lots=",InpLotSize,
               " SL=",InpStopLoss,"pts TP=",InpTakeProfit,"pts");
     }
   
   //--- SELL logic
   if(sellSignal && (InpTradeBothDirections || buys==0))
     {
      // Close any opposite buys first (optional)
      if(buys>0) CloseOpposite(POSITION_TYPE_BUY);
      
      double price   = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl      = price + InpStopLoss*_Point;
      double tp      = price - InpTakeProfit*_Point;
      
      if(!trade.Sell(InpLotSize,_Symbol,price,sl,tp))
         Print("Sell order failed. Error:",trade.ResultRetcode());
      else
         Print("Sell opened: lots=",InpLotSize,
               " SL=",InpStopLoss,"pts TP=",InpTakeProfit,"pts");
     }
  }

//+------------------------------------------------------------------+
//| Helper: close opposite positions                                 |
//+------------------------------------------------------------------+
void CloseOpposite(ENUM_POSITION_TYPE opposite_type)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetInteger(POSITION_TYPE)!=opposite_type) continue;
      
      double price = (opposite_type==POSITION_TYPE_BUY)?
                     SymbolInfoDouble(_Symbol,SYMBOL_BID):
                     SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      
      if(!trade.PositionClose(ticket))
         Print("Close opposite failed. Error:",trade.ResultRetcode());
      else
         Print("Closed opposite ticket #",ticket);
     }
  }
//+------------------------------------------------------------------+