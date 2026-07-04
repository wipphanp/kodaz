//+------------------------------------------------------------------+
//|                                   Simple_MACrossover_EA.mq5      |
//|                         Copyright 2025, MQL5 Community           |
//|                                   https://www.mql5.com           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MQL5 Community"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Simple Expert Advisor for learning MA crossover logic."

//--- Include the CTrade class for easy trade management
#include <Trade/Trade.mqh>

//--- Input parameters
input int    FastMAPeriod = 10;
input int    SlowMAPeriod = 25;
input double Lots         = 0.01;
input int    MagicNumber  = 12345;

//--- Global variables
CTrade trade; // Declare an instance of the CTrade class
int    fast_ma_handle;
int    slow_ma_handle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Get handles for the Moving Average indicators
    fast_ma_handle = iMA(_Symbol, _Period, FastMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    slow_ma_handle = iMA(_Symbol, _Period, SlowMAPeriod, 0, MODE_SMA, PRICE_CLOSE);

    //--- Check for handle errors
    if(fast_ma_handle == INVALID_HANDLE || slow_ma_handle == INVALID_HANDLE)
    {
        Print("Failed to get indicator handles.");
        return(INIT_FAILED);
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Free indicator handles
    IndicatorRelease(fast_ma_handle);
    IndicatorRelease(slow_ma_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Declare arrays to store indicator values
    double fast_ma_values[];
    double slow_ma_values[];

    //--- Get the latest two MA values
    if(CopyBuffer(fast_ma_handle, 0, 0, 2, fast_ma_values) < 0 ||
       CopyBuffer(slow_ma_handle, 0, 0, 2, slow_ma_values) < 0)
    {
        Print("Failed to copy indicator buffers.");
        return;
    }

    //--- Check for open positions
    if (PositionsTotal() > 0)
    {
        return; // Exit if a position is already open
    }
    
    //--- Check for signals
    
    // BUY Signal: Fast MA crosses above Slow MA
    if (fast_ma_values[1] < slow_ma_values[1] && fast_ma_values[0] > slow_ma_values[0])
    {
        // Check for no open positions before placing an order
        if (PositionsTotal() == 0)
        {
            trade.Buy(Lots, _Symbol);
            Print("BUY Signal! Opened a new buy position.");
        }
    }
    
    // SELL Signal: Fast MA crosses below Slow MA
    if (fast_ma_values[1] > slow_ma_values[1] && fast_ma_values[0] < slow_ma_values[0])
    {
        // Check for no open positions before placing an order
        if (PositionsTotal() == 0)
        {
            trade.Sell(Lots, _Symbol);
            Print("SELL Signal! Opened a new sell position.");
        }
    }
}