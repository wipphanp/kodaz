//+------------------------------------------------------------------+
//|                                      MoneyTPSL_ExpertAdvisor.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+

#property copyright "Copyright 2026 MoneyTPSL_ExpertAdvisor.mq5 "
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input parameters
input double RiskMoney = 50.0;      // Risk amount in account currency (e.g., $50)
input double ProfitMoney = 100.0;   // Profit target in account currency (e.g., $100)
input double LotSize = 0.01;        // Fixed lot size (override auto-calc if >0)
input int MagicNumber = 12345;      // Magic number for trades
input ENUM_TIMEFRAMES Timeframe = PERIOD_CURRENT; // Trading timeframe

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(MagicNumber);
    Print("Money-based TP/SL EA initialized. Risk: $", RiskMoney, ", Profit: $", ProfitMoney);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // Simple strategy: Buy on new bar high, Sell on new bar low (customize as needed)
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, Timeframe, 0);
    
    if (currentBar != lastBar) {
        lastBar = currentBar;
        
        // Close opposite positions before new signal
        CloseAllPositions();
        
        double high = iHigh(_Symbol, Timeframe, 1);
        double low = iLow(_Symbol, Timeframe, 1);
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        
        // Buy signal example (customize your strategy here)
        if (currentPrice > high) {
            OpenPosition(ORDER_TYPE_BUY);
        }
        // Sell signal
        else if (currentPrice < low) {
            OpenPosition(ORDER_TYPE_SELL);
        }
    }
}

//+------------------------------------------------------------------+
//| Open position with money-based TP/SL                             |
//+------------------------------------------------------------------+



//*void OpenPosition(ENUM_ORDER_TYPE orderType) {
    double entry = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    
    if (tickValue <= 0) {
        Print("Error: Invalid tick value: ", tickValue);
        return;
    }
    
    double lots = LotSize;
    if (lots <= 0) {
        // Auto lot based on risk (calculate lots so risk == RiskMoney)
        double slPoints = (RiskMoney / tickValue) * tickSize;
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        lots = NormalizeDouble(RiskMoney / (slPoints * tickValue / tickSize), 2);
        lots = MathMax(lots, minLot);
        lots = MathMin(lots, maxLot);
        lots = MathRound(lots / stepLot) * stepLot;
    }
    
    double sl = 0, tp = 0;
    
    if (orderType == ORDER_TYPE_BUY) {
        double slDistPoints = (RiskMoney / tickValue) * tickSize;
        sl = NormalizeDouble(entry - slDistPoints * point, _Digits);
        double tpDistPoints = (ProfitMoney / tickValue) * tickSize;
        tp = NormalizeDouble(entry + tpDistPoints * point, _Digits);
    } else {  // SELL
        double slDistPoints = (RiskMoney / tickValue) * tickSize;
        sl = NormalizeDouble(entry + slDistPoints * point, _Digits);
        double tpDistPoints = (ProfitMoney / tickValue) * tickSize;
        tp = NormalizeDouble(entry - tpDistPoints * point, _Digits);
    }
    
    if (trade.PositionOpen(_Symbol, orderType, lots, entry, sl, tp, "Money TP/SL EA")) {
        Print("Opened ", EnumToString(orderType), " Lots:", lots, " Entry:", entry, " SL:", sl, " TP:", tp);
    } else {
        Print("Failed to open position: ", trade.ResultRetcodeDescription());
    }
}



void OpenPosition(ENUM_ORDER_TYPE orderType) {
    double entry = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);  // Min points from price
    
    Print("Entry:", entry, " TickValue:", tickValue, " StopsLevel:", stopsLevel, " Point:", point);
    
    if (tickValue <= 0) {
        Print("ERROR: Invalid tick value");
        return;
    }
    
    double lots = LotSize;
    if (lots <= 0) {
        double slPoints = (RiskMoney / tickValue) * tickSize;
        lots = NormalizeDouble(RiskMoney / (slPoints * tickValue / tickSize), 2);
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        lots = MathMax(lots, minLot); lots = MathMin(lots, maxLot);
        lots = MathRound(lots / stepLot) * stepLot;
    }
    
    double sl = 0, tp = 0;
    double buffer = (double)stopsLevel * point;  // Buffer for min distance
    
    if (orderType == ORDER_TYPE_BUY) {
        double slDist = (RiskMoney / tickValue) * tickSize * point + buffer;
        sl = NormalizeDouble(entry - slDist, _Digits);
        double tpDist = (ProfitMoney / tickValue) * tickSize * point + buffer;
        tp = NormalizeDouble(entry + tpDist, _Digits);
    } else {
        double slDist = (RiskMoney / tickValue) * tickSize * point + buffer;
        sl = NormalizeDouble(entry + slDist, _Digits);
        double tpDist = (ProfitMoney / tickValue) * tickSize * point + buffer;
        tp = NormalizeDouble(entry - tpDist, _Digits);
    }
    
    Print("Lots:", lots, " SL:", sl, " TP:", tp);
    
    if (trade.PositionOpen(_Symbol, orderType, lots, entry, sl, tp, "Money TP/SL EA")) {
        Print("SUCCESS: Trade opened with TP/SL");
    } else {
        Print("FAILED: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    }
}


//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            trade.PositionClose(ticket);
        }
    }
}
