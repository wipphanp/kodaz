   //+------------------------------------------------------------------+
//|                                   Simple_MACrossover_EA.mq5      |
//|                         Copyright 2025, MQL5 Community           |
//|                                   https://www.mql5.com           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MQL5 Community"
#property link      "https://www.mql5.com"
#property version   "1.01" // Updated version
#property description "Simple Expert Advisor for learning MA crossover logic with visual signals."

//--- Include the CTrade class for easy trade management
#include <Trade/Trade.mqh>
//--- Include ChartObjectsArrows for plotting visual signals
#include <ChartObjects/ChartObjectsArrows.mqh>

//--- Input parameters, which you can modify from the EA properties window
input int    FastMAPeriod = 10;
input int    SlowMAPeriod = 25;
input double Lots         = 0.01;
input int    MagicNumber  = 12345;
input color  BuySignalColor  = clrGreen;   // Color for buy arrows
input color  SellSignalColor = clrRed;     // Color for sell arrows
input int    ArrowShiftBars  = 1;          // How many bars back to place the arrow (0 = current, 1 = previous)

//--- Global variables
CTrade trade; // Declare an instance of the CTrade class
int    fast_ma_handle;
int    slow_ma_handle;

// To keep track of the last bar a signal was processed on
datetime last_signal_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//| Called once when the EA is attached to a chart.                  |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Get handles for the Moving Average indicators
    fast_ma_handle = iMA(_Symbol, _Period, FastMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    slow_ma_handle = iMA(_Symbol, _Period, SlowMAPeriod, 0, MODE_SMA, PRICE_CLOSE);

    //--- Check for handle errors
    if(fast_ma_handle == INVALID_HANDLE || slow_ma_handle == INVALID_HANDLE)
    {
        Print("Failed to get indicator handles. Check parameters.");
        return(INIT_FAILED);
    }
    
    //--- Initialize the CTrade object
    trade.SetExpertMagic(MagicNumber);
    trade.SetDeviation(10); // Set max deviation for order execution (e.g., 10 points)
    trade.SetTypeFilling(ORDER_FILLING_FOK); // Fill or Kill

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//| Called when the EA is removed from a chart.                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Free indicator handles
    IndicatorRelease(fast_ma_handle);
    IndicatorRelease(slow_ma_handle);
    
    //--- Optional: Delete all objects created by this EA on deinitialization
    ObjectsDeleteAll(0, 0, OBJ_ARROW_BUY);
    ObjectsDeleteAll(0, 0, OBJ_ARROW_SELL);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//| Called on every new tick (price change).                         |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Ensure we only process signals once per new bar
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, 2, rates) != 2) return; // Get latest 2 bars

    datetime current_bar_time = rates[0].time;
    if (last_signal_time == current_bar_time) return; // Already processed this bar
    last_signal_time = current_bar_time;

    //--- Declare arrays to store indicator values
    double fast_ma_values[];
    double slow_ma_values[];

    //--- Get the latest two MA values (index 0 is current, index 1 is previous)
    if(CopyBuffer(fast_ma_handle, 0, 1, 2, fast_ma_values) < 0 || // Get value for bar 1 and 2 (previous and one before previous)
       CopyBuffer(slow_ma_handle, 0, 1, 2, slow_ma_values) < 0)
    {
        Print("Failed to copy indicator buffers.");
        return;
    }

    //--- Check for open positions
    if (PositionsTotal() > 0)
    {
        return; // Exit if a position is already open to avoid multiple trades
    }

    //--- Get prices for placing orders (only if a trade is to be made)
    double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // --- Trading Logic ---

    // BUY Signal: The fast MA crosses above the slow MA
    // Condition: Fast MA was below Slow MA on bar[1] and is now above on bar[0]
    // Plotting the arrow on the bar where the crossover occurred (bar[1] in this case, or rates[1])
    if (fast_ma_values[1] < slow_ma_values[1] && fast_ma_values[0] > slow_ma_values[0])
    {
        // Plot buy arrow
        PlotSignalArrow(OBJ_ARROW_BUY, rates[ArrowShiftBars].time, rates[ArrowShiftBars].low, BuySignalColor, "BuySignal_");
        
        // Open a buy position
        trade.Buy(Lots, _Symbol, current_ask);
        PrintFormat("BUY Signal! Fast MA (%d) crossed above Slow MA (%d) at %s. Opened %f lots.",
                    FastMAPeriod, SlowMAPeriod, TimeToString(rates[ArrowShiftBars].time), Lots);
    }
    // SELL Signal: The fast MA crosses below the slow MA
    // Condition: Fast MA was above Slow MA on bar[1] and is now below on bar[0]
    // Plotting the arrow on the bar where the crossover occurred (bar[1] in this case, or rates[1])
    else if (fast_ma_values[1] > slow_ma_values[1] && fast_ma_values[0] < slow_ma_values[0])
    {
        // Plot sell arrow
        PlotSignalArrow(OBJ_ARROW_SELL, rates[ArrowShiftBars].time, rates[ArrowShiftBars].high, SellSignalColor, "SellSignal_");

        // Open a sell position
        trade.Sell(Lots, _Symbol, current_bid);
        PrintFormat("SELL Signal! Fast MA (%d) crossed below Slow MA (%d) at %s. Opened %f lots.",
                    FastMAPeriod, SlowMAPeriod, TimeToString(rates[ArrowShiftBars].time), Lots);
    }
}

//+------------------------------------------------------------------+
//| Custom function to plot signal arrows on the chart               |
//+------------------------------------------------------------------+
void PlotSignalArrow(ENUM_OBJECT type, datetime time, double price, color arrow_color, string prefix)
{
    string object_name = prefix + TimeToString(time, TIME_DATE|TIME_MINUTES); // Unique name for the object
    
    // Check if an object with this name already exists (prevents duplicates)
    if(ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR) == -1 && ObjectFind(0, object_name) != 0)
    {
        // If it exists and we are not backtesting (CHART_FIRST_VISIBLE_BAR == -1 indicates backtesting)
        // or if running live and the object is already there, don't recreate.
        return; 
    }

    CChartObjectArrow *arrow = new CChartObjectArrow();
    if(arrow == NULL)
    {
        Print("Failed to create CChartObjectArrow object.");
        return;
    }

    if(!arrow.Create(0, object_name, 0, time, price))
    {
        PrintFormat("Failed to create arrow object '%s', error: %d", object_name, GetLastError());
        delete arrow;
        return;
    }

    arrow.Type(type);             // OBJ_ARROW_BUY (up arrow) or OBJ_ARROW_SELL (down arrow)
    arrow.Color(arrow_color);     // Set the color
    arrow.Width(1);               // Line thickness
    arrow.Z_Order(0);             // Ensure it's on top of indicators
    arrow.Selectable(false);      // Cannot be selected with mouse
    arrow.Set("description", "MA Crossover Signal"); // Tooltip description
    
    // For buy arrows, offset below the low. For sell arrows, offset above the high.
    if(type == OBJ_ARROW_BUY)
    {
        arrow.ShiftY(-15); // Shift down from the price for buy (triangle points up from below)
    }
    else if(type == OBJ_ARROW_SELL)
    {
        arrow.ShiftY(15);  // Shift up from the price for sell (triangle points down from above)
    }

    ChartRedraw(); // Redraw the chart to show the object immediately
}