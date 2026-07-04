//+------------------------------------------------------------------+
//| Expert Advisor: Alligator + ATR Stop Loss                        |
//| Converted from Pine Script strategy                              |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//--- Trade objects
CTrade trade;
CPositionInfo pos;

//--- Input parameters
input int    JawLength   = 13;
input int    TeethLength = 8;
input int    LipsLength  = 5;
input int    ATRPeriod   = 14;
input double ATRMult     = 2.0;
input double Lots        = 0.1;
input int    Slippage    = 3;
input ulong  MagicNumber = 123456;

//--- Date range filter
input datetime StartDate = D'2018.01.01 00:00';
input datetime EndDate   = D'2069.12.31 23:59';

//--- Indicator handles
int jawHandle, teethHandle, lipsHandle, atrHandle;

//--- Buffers
double jawBuff[], teethBuff[], lipsBuff[], atrBuff[];

//+------------------------------------------------------------------+
//| Custom initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Create indicator handles
   jawHandle   = iSMMA(_Symbol, PERIOD_CURRENT, JawLength, PRICE_MEDIAN);
   teethHandle = iSMMA(_Symbol, PERIOD_CURRENT, TeethLength, PRICE_MEDIAN);
   lipsHandle  = iSMMA(_Symbol, PERIOD_CURRENT, LipsLength, PRICE_MEDIAN);
   atrHandle   = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(jawHandle < 0 || teethHandle < 0 || lipsHandle < 0 || atrHandle < 0)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(jawHandle);
   IndicatorRelease(teethHandle);
   IndicatorRelease(lipsHandle);
   IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(TimeCurrent() < StartDate || TimeCurrent() > EndDate)
      return;

   //--- Get latest values
   if(CopyBuffer(jawHandle,0,0,3,jawBuff) < 0) return;
   if(CopyBuffer(teethHandle,0,0,3,teethBuff) < 0) return;
   if(CopyBuffer(lipsHandle,0,0,3,lipsBuff) < 0) return;
   if(CopyBuffer(atrHandle,0,0,3,atrBuff) < 0) return;

   double jaw   = jawBuff[0];
   double teeth = teethBuff[0];
   double lips  = lipsBuff[0];
   double atr   = atrBuff[0];

   if(jaw==0 || teeth==0 || lips==0) return;

   bool havePosition = pos.Select(_Symbol) && pos.Magic() == (long)MagicNumber;

   //--- Long entry: Lips cross above Jaw
   static double lipsPrev=0, jawPrev=0;
   bool longCond = (lipsPrev <= jawPrev && lips > jaw);

   //--- Exit: Lips cross under Jaw
   bool exitCond = (lipsPrev >= jawPrev && lips < jaw);

   //--- Update previous values
   lipsPrev = lips;
   jawPrev  = jaw;

   //--- Trade logic
   if(!havePosition && longCond)
   {
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(Slippage);
      if(trade.Buy(Lots,NULL,0,0,0,"Alligator Long"))
         Print("Opened Long");
      else
         Print("Buy failed: ",GetLastError());
   }

   if(havePosition && pos.PositionType()==POSITION_TYPE_BUY)
   {
      double stopPrice = pos.PriceOpen() - ATRMult * atr;

      //--- Apply ATR SL if tighter or not set
      double currentSL = pos.StopLoss();
      if(currentSL==0.0 || stopPrice > currentSL)
      {
         if(!trade.PositionModify(_Symbol, stopPrice, pos.TakeProfit()))
            Print("PositionModify (set ATR SL) failed: ",GetLastError());
         else
            Print("Updated SL to ATR: ",DoubleToString(stopPrice,_Digits));
      }

      //--- Exit on lips cross under jaw
      if(exitCond)
      {
         if(!trade.PositionClose(_Symbol))
            Print("Close failed: ",GetLastError());
         else
            Print("Closed Long on exitCond");
      }
   }
}
