//+------------------------------------------------------------------+
//|                                        Gold_Scalper_EA_V1.mq5 |
//|                                  Copyright 2026, Pruthviraj S P  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Pruthviraj S P"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input int      RSI_Period = 14;         // RSI Period
input double   Lot_Stage1 = 0.03;       // Lot Size Stage 1
input double   Lot_Stage2 = 0.04;       // Lot Size Stage 2
input double   Lot_Stage3 = 0.05;       // Lot Size Stage 3
input int      ATR_Period = 14;         // ATR Period
input double   ATR_Multiplier = 1.5;    // ATR Multiplier for Grid
input int      ADX_Period = 14;         // ADX Period
input double   ADX_Max = 35.0;          // Max ADX (Trend Filter)
input int      MagicNumber = 123456;    // Magic Number

//--- Global Variables
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

int            rsiHandle;
int            atrHandle;
int            adxHandle;

double         rsiBuffer[];
double         atrBuffer[];
double         adxBuffer[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   
   rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, _Period, ATR_Period);
   adxHandle = iADX(_Symbol, PERIOD_H1, ADX_Period); // Higher timeframe ADX for trend filtering
   
   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(adxBuffer, true);
   
   if(rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
     {
      Print("Error initializing indicators.");
      return(INIT_FAILED);
     }
     
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(adxHandle);
  }

//+------------------------------------------------------------------+
//| Calculate VWAP Break-Even Price                                  |
//+------------------------------------------------------------------+
double CalculateVWAP(int type)
  {
   double totalVolume = 0;
   double totalValue = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Magic() == MagicNumber && posInfo.Symbol() == _Symbol && posInfo.PositionType() == type)
           {
            totalVolume += posInfo.Volume();
            totalValue += posInfo.Volume() * posInfo.PriceOpen();
           }
        }
     }
     
   if(totalVolume > 0)
      return totalValue / totalVolume;
      
   return 0;
  }

//+------------------------------------------------------------------+
//| Close All Positions of a Specific Type                           |
//+------------------------------------------------------------------+
void CloseAllPositions(int type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Magic() == MagicNumber && posInfo.Symbol() == _Symbol && posInfo.PositionType() == type)
           {
            trade.PositionClose(posInfo.Ticket());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   symInfo.Name(_Symbol);
   symInfo.RefreshRates();
   
   if(CopyBuffer(rsiHandle, 0, 0, 2, rsiBuffer) <= 0) return;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0) return;
   if(CopyBuffer(adxHandle, 0, 0, 1, adxBuffer) <= 0) return;
   
   double currentRSI = rsiBuffer[0];
   double prevRSI = rsiBuffer[1];
   double atrValue = atrBuffer[0];
   double adxValue = adxBuffer[0];
   
   int buyPositions = 0;
   int sellPositions = 0;
   double firstBuyPrice = 0;
   double firstSellPrice = 0;
   
   // Count positions and identify initial entry prices
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == MagicNumber && posInfo.Symbol() == _Symbol)
        {
         if(posInfo.PositionType() == POSITION_TYPE_BUY)
           {
            buyPositions++;
            if(buyPositions == 1) firstBuyPrice = posInfo.PriceOpen();
           }
         else if(posInfo.PositionType() == POSITION_TYPE_SELL)
           {
            sellPositions++;
            if(sellPositions == 1) firstSellPrice = posInfo.PriceOpen();
           }
        }
     }

   // --- Trend Filter (ADX) ---
   // If ADX is above the max threshold, it indicates a strong, potentially account-blowing trend.
   bool isTrending = (adxValue > ADX_Max);

   // =========================================================================================
   // BUY SEQUENCE
   // =========================================================================================
   if(buyPositions == 0 && !isTrending)
     {
      // Stage 1 Entry: RSI crosses above 31.4
      if(prevRSI < 31.4 && currentRSI >= 31.4)
        {
         trade.Buy(Lot_Stage1, _Symbol);
        }
     }
   else if(buyPositions > 0)
     {
      double vwapBuyPrice = CalculateVWAP(POSITION_TYPE_BUY);
      
      // Stage 1 & Master Exit: Price above VWAP (Break-Even) AND RSI reaches opposite extreme
      if(symInfo.Bid() > vwapBuyPrice && currentRSI >= 65.43)
        {
         CloseAllPositions(POSITION_TYPE_BUY);
        }
        
      // Stage 2 Entry (Pyramiding with ATR Dynamic Spacing)
      if(buyPositions == 1 && !isTrending && currentRSI <= 18.18)
        {
         // Wait for price to drop dynamically based on current market volatility
         if(firstBuyPrice - symInfo.Ask() > (atrValue * ATR_Multiplier)) 
           {
            trade.Buy(Lot_Stage2, _Symbol);
           }
        }
        
      // Stage 3 Entry 
      if(buyPositions == 2 && !isTrending && currentRSI <= 12.12)
        {
         // Requires an even larger drop to avoid stacking trades in a freefall
         if(firstBuyPrice - symInfo.Ask() > (atrValue * ATR_Multiplier * 2)) 
           {
            trade.Buy(Lot_Stage3, _Symbol);
           }
        }
     }

   // =========================================================================================
   // SELL SEQUENCE
   // =========================================================================================
   if(sellPositions == 0 && !isTrending)
     {
      // Stage 1 Entry: RSI crosses below 68.68
      if(prevRSI > 68.68 && currentRSI <= 68.68)
        {
         trade.Sell(Lot_Stage1, _Symbol);
        }
     }
   else if(sellPositions > 0)
     {
      double vwapSellPrice = CalculateVWAP(POSITION_TYPE_SELL);
      
      // Stage 1 & Master Exit: Price below VWAP (Break-Even) AND RSI reaches opposite extreme
      if(symInfo.Ask() < vwapSellPrice && currentRSI <= 32.31)
        {
         CloseAllPositions(POSITION_TYPE_SELL);
        }
        
      // Stage 2 Entry (Pyramiding with ATR Dynamic Spacing)
      if(sellPositions == 1 && !isTrending && currentRSI >= 84.84)
        {
         // Wait for price to rise dynamically based on current market volatility
         if(symInfo.Bid() - firstSellPrice > (atrValue * ATR_Multiplier)) 
           {
            trade.Sell(Lot_Stage2, _Symbol);
           }
        }
        
      // Stage 3 Entry 
      if(sellPositions == 2 && !isTrending && currentRSI >= 89.89)
        {
         if(symInfo.Bid() - firstSellPrice > (atrValue * ATR_Multiplier * 2)) 
           {
            trade.Sell(Lot_Stage3, _Symbol);
           }
        }
     }
  }
//+------------------------------------------------------------------+