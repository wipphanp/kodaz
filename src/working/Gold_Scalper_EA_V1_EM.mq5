//+------------------------------------------------------------------+
//|                                        Gold_Scalper_EA_V1_EM.mq5 |
//|                                  Copyright 2026, Pruthviraj S P  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Pruthviraj S P"
#property link      "https://www.mql5.com"
#property version   "1.01"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters (Automatic Grid System)
input int      RSI_Period = 14;         // RSI Period
input double   Lot_Stage1 = 0.03;       // Lot Size Stage 1
input double   Lot_Stage2 = 0.04;       // Lot Size Stage 2
input double   Lot_Stage3 = 0.05;       // Lot Size Stage 3
input int      ATR_Period = 14;         // ATR Period
input double   ATR_Multiplier = 1.5;    // ATR Multiplier for Grid
input int      ADX_Period = 14;         // ADX Period
input double   ADX_Max = 35.0;          // Max ADX (Trend Filter)
input int      MagicNumber = 123456;    // Auto Trade Magic Number

//--- Input Parameters (Manual Trade System)
input double   Manual_LotSize = 0.063;       // Manual Trade Lot Size
input double   Manual_TP_USD = 18.18;       // Manual Trade Target Profit ($)
input int      Manual_MagicNumber = 999999; // Manual Trade Magic Number

//--- Global Variables
CTrade         trade;         // Handles Automatic trades
CTrade         manualTrade;   // Handles Manual trades
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

int            rsiHandle;
int            atrHandle;
int            adxHandle;

double         rsiBuffer[];
double         atrBuffer[];
double         adxBuffer[];

//+------------------------------------------------------------------+
//| Create Chart Buttons for Manual Trading                          |
//+------------------------------------------------------------------+
void CreateButtons()
  {
   // Create Buy Button
   ObjectCreate(0, "BtnManualBuy", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_YSIZE, 30);
   ObjectSetString(0, "BtnManualBuy", OBJPROP_TEXT, "MANUAL BUY");
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_BGCOLOR, clrDarkGreen);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "BtnManualBuy", OBJPROP_HIDDEN, true);

   // Create Sell Button
   ObjectCreate(0, "BtnManualSell", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_XDISTANCE, 150);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_YSIZE, 30);
   ObjectSetString(0, "BtnManualSell", OBJPROP_TEXT, "MANUAL SELL");
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_BGCOLOR, clrDarkRed);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "BtnManualSell", OBJPROP_HIDDEN, true);
   
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Remove Chart Buttons                                             |
//+------------------------------------------------------------------+
void RemoveButtons()
  {
   ObjectDelete(0, "BtnManualBuy");
   ObjectDelete(0, "BtnManualSell");
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Chart Event Handler for UI Interactions                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == "BtnManualBuy")
        {
         manualTrade.Buy(Manual_LotSize, _Symbol);
         Print("Manual Buy executed with Magic Number: ", Manual_MagicNumber);
         ObjectSetInteger(0, "BtnManualBuy", OBJPROP_STATE, false); // Unpress button
        }
      else if(sparam == "BtnManualSell")
        {
         manualTrade.Sell(Manual_LotSize, _Symbol);
         Print("Manual Sell executed with Magic Number: ", Manual_MagicNumber);
         ObjectSetInteger(0, "BtnManualSell", OBJPROP_STATE, false); // Unpress button
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Assign unique magic numbers to specific operational objects
   trade.SetExpertMagicNumber(MagicNumber);
   manualTrade.SetExpertMagicNumber(Manual_MagicNumber);
   
   CreateButtons(); // Render visual control buttons
   
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
   
   RemoveButtons(); // Clean up chart GUI upon removing EA
  }

//+------------------------------------------------------------------+
//| Calculate VWAP Break-Even Price (Auto Trades Only)               |
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
//| Close All Positions of a Specific Type (Auto Trades Only)        |
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
//| Manage Manual Trades - Checks Take Profit Exit                   |
//+------------------------------------------------------------------+
void ManageManualTrades()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         // Strictly identify manual trades assigned via GUI buttons
         if(posInfo.Magic() == Manual_MagicNumber && posInfo.Symbol() == _Symbol)
           {
            // Calculate total net profit including swap and commission costs
            double netProfit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
            
            if(netProfit >= Manual_TP_USD)
              {
               manualTrade.PositionClose(posInfo.Ticket());
               Print("Manual Trade Closed. Target Profit Reached: $", netProfit);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Manage Manual Trades continuously independent of grid logic
   ManageManualTrades();

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
   
   // Count strictly AUTOMATIC positions and identify initial entry prices
   for(int i = 0; i < PositionsTotal(); i++)
     {
      // Using MagicNumber isolates this completely from Manual_MagicNumber
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
   bool isTrending = (adxValue > ADX_Max);

   // =========================================================================================
   // BUY SEQUENCE (Automatic)
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
         if(firstBuyPrice - symInfo.Ask() > (atrValue * ATR_Multiplier)) 
           {
            trade.Buy(Lot_Stage2, _Symbol);
           }
        }
        
      // Stage 3 Entry 
      if(buyPositions == 2 && !isTrending && currentRSI <= 12.12)
        {
         if(firstBuyPrice - symInfo.Ask() > (atrValue * ATR_Multiplier * 2)) 
           {
            trade.Buy(Lot_Stage3, _Symbol);
           }
        }
     }

   // =========================================================================================
   // SELL SEQUENCE (Automatic)
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