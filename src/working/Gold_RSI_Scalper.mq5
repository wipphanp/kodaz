//+------------------------------------------------------------------+
//                                       Gold_RSI_Scalper.mq5
//                        Copyright 2025, MetaQuotes Software Corp.
//                                             https://www.mql5.com
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//--- input parameters
input int    RSI_Period   = 14;          // RSI period
input double LotsLevel1   = 0.05;        // first lot size
input double LotsLevel2   = 0.09;        // second lot size (added when RSI goes deeper)
input int    MagicNumber  = 123456;

//--- global variables
int        rsiHandle;                    // indicator handle
double     rsiBuffer[];                  // to store RSI values

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- create RSI handle for current symbol, M1 timeframe
   rsiHandle = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   if(rsiHandle==INVALID_HANDLE)
     {
      Print("Failed to create RSI handle. Error ",GetLastError());
      return(INIT_FAILED);
     }
   //--- set array as series for easy indexing (0 = current bar)
   ArraySetAsSeries(rsiBuffer,true);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- release the indicator handle
   if(rsiHandle!=INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- copy latest RSI values (we need only the current bar)
   if(CopyBuffer(rsiHandle,0,0,1,rsiBuffer)<=0)
      return;   // wait for data

   double rsi = rsiBuffer[0];   // current RSI value

   //--- count existing buy and sell positions
   int buys = 0, sells = 0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) buys++;
      else if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL) sells++;
     }

   //--- ENTRY LOGIC -------------------------------------------------
   // Buy conditions (only if no sell positions exist)
   if(sells==0)
     {
      // first level: RSI touches 30
      if(rsi<=30 && buys==0)
         OpenPosition(ORDER_TYPE_BUY,LotsLevel1);
      // second level: RSI still <=15 and we already have one buy
      if(rsi<=15 && buys==1)
         OpenPosition(ORDER_TYPE_BUY,LotsLevel2);
     }
   // Sell conditions (only if no buy positions exist)
   if(buys==0)
     {
      // first level: RSI touches 70
      if(rsi>=70 && sells==0)
         OpenPosition(ORDER_TYPE_SELL,LotsLevel1);
      // second level: RSI still >=85 and we already have one sell
      if(rsi>=85 && sells==1)
         OpenPosition(ORDER_TYPE_SELL,LotsLevel2);
     }

   //--- EXIT LOGIC --------------------------------------------------
   // Close all buys when RSI reaches 63
   if(buys>0 && rsi>=63)
      CloseAllByType(POSITION_TYPE_BUY);
   // Close all sells when RSI reaches 35 or below
   if(sells>0 && rsi<=35)
      CloseAllByType(POSITION_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| Open a market position with specified lot size                   |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type, double lots)
  {
   MqlTradeRequest  request;
   MqlTradeResult   result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = _Symbol;
   request.volume   = lots;
   request.type     = type;
   request.price    = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   request.deviation= 10;
   request.magic    = MagicNumber;
   request.comment  = "Gold_RSI_Scalper";

   if(!OrderSend(request,result))
      Print("OrderSend failed: ",GetLastError());
   else if(result.retcode!=TRADE_RETCODE_DONE)
      Print("OrderSend failed, retcode=",result.retcode);
  }

//+------------------------------------------------------------------+
//| Close all positions of a given type (buy or sell)                |
//+------------------------------------------------------------------+
void CloseAllByType(ENUM_POSITION_TYPE type)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_TYPE)!=type) continue;

      MqlTradeRequest  request;
      MqlTradeResult   result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol   = _Symbol;
      request.volume   = PositionGetDouble(POSITION_VOLUME);
      request.type     = (type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price    = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                                   : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      request.deviation= 10;
      request.magic    = MagicNumber;
      request.comment  = "Close_RSI";

      if(!OrderSend(request,result))
         Print("OrderSend close failed: ",GetLastError());
     }
  }
//+------------------------------------------------------------------+