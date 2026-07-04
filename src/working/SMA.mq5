//--- Includes the standard library for trading operations
#include <Trade\Trade.mqh>

//--- Input parameters for the EA, configurable by the user
input double  InpLots        = 0.1;           // Lots
input int     InpTakeProfit  = 500;           // Take Profit in points
input int     InpStopLoss    = 250;           // Stop Loss in points
input int     InpFastMALen   = 12;            // Fast MA Period
input int     InpSlowMALen   = 26;            // Slow MA Period
input int     InpMAShift     = 0;             // MA Shift

//--- Global variables
Ctrade      m_trade;                // Trading class object
int         m_fast_ma_handle;       // Handle for the fast Moving Average indicator
int         m_slow_ma_handle;       // Handle for the slow Moving Average indicator
double      m_fast_ma_buffer[];     // Buffer for fast MA values
double      m_slow_ma_buffer[];     // Buffer for slow MA values

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set up the trading environment
   m_trade.SetExpertMagicNumber(12345); // Unique ID for this EA's orders
   m_trade.SetDeviationInPoints(10);    // Acceptable deviation for trade execution

   //--- Create a handle for the fast Moving Average
   // The iMA function creates and returns a handle to the indicator
   // We specify the symbol, timeframe, period, shift, method, and applied price
   m_fast_ma_handle = iMA(
      _Symbol,                 // Current symbol
      _Period,                 // Current timeframe
      InpFastMALen,            // Fast MA period from inputs
      InpMAShift,              // Shift from inputs
      MODE_EMA,                // Exponential Moving Average method
      PRICE_CLOSE              // Applied to the close price
   );

   //--- Check if the fast MA handle was created successfully
   if (m_fast_ma_handle == INVALID_HANDLE)
   {
      Print("Failed to create fast MA handle. Error: ", GetLastError());
      return(INIT_FAILED);
   }

   //--- Create a handle for the slow Moving Average
   m_slow_ma_handle = iMA(
      _Symbol,
      _Period,
      InpSlowMALen,
      InpMAShift,
      MODE_EMA,
      PRICE_CLOSE
   );

   //--- Check if the slow MA handle was created successfully
   if (m_slow_ma_handle == INVALID_HANDLE)
   {
      Print("Failed to create slow MA handle. Error: ", GetLastError());
      return(INIT_FAILED);
   }
   
   //--- Everything is ready
   Print("EA has been successfully initialized!");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//| This function is called when the EA is removed from the chart.   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment(""); // Clear any comments from the chart
   Print("EA has been de-initialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//| This function is called on every new tick.                       |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check if there are any open positions for the current symbol and magic number
   if (PositionsTotal() > 0)
   {
      // If there are, we don't need to check for new entries.
      // We can add a trailing stop or other management logic here later if needed.
      return;
   }

   //--- Copy the latest values from the indicator buffers to our arrays
   // The CopyBuffer function copies indicator values to an array
   if (CopyBuffer(m_fast_ma_handle, 0, 0, 2, m_fast_ma_buffer) <= 0 ||
       CopyBuffer(m_slow_ma_handle, 0, 0, 2, m_slow_ma_buffer) <= 0)
   {
      // Not enough data yet, wait for the next tick
      return;
   }

   //--- Get the current and previous values of the moving averages
   double fast_ma_current = m_fast_ma_buffer[0];
   double fast_ma_previous = m_fast_ma_buffer[1];
   double slow_ma_current = m_slow_ma_buffer[0];
   double slow_ma_previous = m_slow_ma_buffer[1];

   //--- Trading logic: Check for a moving average crossover
   
   // A bullish crossover (buy signal) occurs when the fast MA crosses above the slow MA
   bool buy_signal = (fast_ma_previous < slow_ma_previous) && (fast_ma_current > slow_ma_current);

   // A bearish crossover (sell signal) occurs when the fast MA crosses below the slow MA
   bool sell_signal = (fast_ma_previous > slow_ma_previous) && (fast_ma_current < slow_ma_current);

   //--- Execute trades based on the signals
   if (buy_signal)
   {
      // Calculate Stop Loss and Take Profit levels
      // We use _Point to convert from points to the correct price format
      double stop_loss_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - InpStopLoss * _Point;
      double take_profit_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + InpTakeProfit * _Point;

      // Place a buy order
      if (m_trade.Buy(InpLots, NULL, stop_loss_price, take_profit_price, "MA Cross Buy"))
      {
         Print("Buy order sent successfully.");
      }
      else
      {
         Print("Buy order failed. Error: ", m_trade.ResultRetcode(), " (", m_trade.ResultRetcodeDescription(), ")");
      }
   }
   else if (sell_signal)
   {
      // Calculate Stop Loss and Take Profit levels
      double stop_loss_price = SymbolInfoDouble(_Symbol, SYMBOL_BID) + InpStopLoss * _Point;
      double take_profit_price = SymbolInfoDouble(_Symbol, SYMBOL_BID) - InpTakeProfit * _Point;

      // Place a sell order
      if (m_trade.Sell(InpLots, NULL, stop_loss_price, take_profit_price, "MA Cross Sell"))
      {
         Print("Sell order sent successfully.");
      }
      else
      {
         Print("Sell order failed. Error: ", m_trade.ResultRetcode(), " (", m_trade.ResultRetcodeDescription(), ")");
      }
   }
}