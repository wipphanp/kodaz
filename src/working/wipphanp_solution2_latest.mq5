//+------------------------------------------------------------------+
//|                               wipphanp_solution2_latest.mq5     |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.60"
#property strict

//------------------------------ INPUTS ------------------------------
// Original RSI-touch and trade inputs
input int    InpRSIPeriod        = 14;          // RSI period
input double InpBuyLevel         = 32.4;        // RSI level to trigger first BUY (0.03)
input double InpSellLevel        = 68.81;       // RSI level to trigger first SELL (0.03)
input int    InpTargetPoints     = 1000;        // Points to close sequence trades
input double InpStopLoss         = 0;           // Stop-loss in points (0 = disabled)
input double InpTakeProfit       = 0;           // Take-profit in points (0 = disabled)
input int    InpMagicNumber      = 987654;      // EA identifier (magic for EA trades)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // chart timeframe for RSI

// New inputs for pyramiding/hedging entries
input double InpBaseLot          = 0.03;        // Base lot for first entry and initial hedges
input double InpBuySecondRSI     = 18.18;       // RSI for second stage (0.03 BUY, 0.03 SELL)
input double InpBuyThirdRSI      = 14.14;       // RSI for third stage (0.06 BUY, 0.03 SELL)
input double InpSellSecondRSI    = 84.84;       // RSI for second stage (0.03 SELL, 0.03 BUY)
input double InpSellThirdRSI     = 89.00;       // RSI for third stage (0.06 SELL, 0.03 BUY)

// Manual-trade TP input (money-based)
input double InpManualTPMoney    = 18.18;       // Target profit in account currency per manual/other position

//--------------------------- GLOBALS -------------------------------
int      rsiHandle      = INVALID_HANDLE;   // iRSI handle
double   prevRSI        = 0.0;              // Previous RSI
bool     firstTick      = true;             // First tick flag
int      eaTradeSequence = 0;               // 0=None, 1=Buy Sequence, 2=Sell Sequence
double   firstBuyPrice  = 0.0;              // Price of the first buy in a sequence
double   firstSellPrice = 0.0;              // Price of the first sell in a sequence

//+------------------------------------------------------------------+
//| Normalize lot to broker's step/min/max                           |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   if(stepLot > 0.0)
      lot = MathFloor(lot / stepLot) * stepLot;

   return(lot);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create RSI handle for selected timeframe and period
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create iRSI handle. Error=", GetLastError());
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
}

//+------------------------------------------------------------------+
//| Get total EA position count and reset sequence if flat           |
//+------------------------------------------------------------------+
void GetEAPositionInfo(int &totalEATrades)
{
   totalEATrades = 0;
   firstBuyPrice = 0.0;
   firstSellPrice = 0.0;
   
   ulong firstTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == _Symbol)
      {
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         if(posMagic == InpMagicNumber)
         {
            totalEATrades++;
            
            // Find the oldest EA trade to get the first entry price
            ulong posTime = PositionGetInteger(POSITION_TIME);
            if(firstTime == 0 || posTime < firstTime) {
               firstTime = posTime;
               long posType = PositionGetInteger(POSITION_TYPE);
               if(posType == POSITION_TYPE_BUY) {
                   firstBuyPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               } else if(posType == POSITION_TYPE_SELL) {
                   firstSellPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               }
            }
         }
      }
   }
   
   if(totalEATrades == 0) {
      eaTradeSequence = 0; // Reset sequence when flat
   }
}

//+------------------------------------------------------------------+
//| Close all EA positions of a specific type                        |
//+------------------------------------------------------------------+
void CloseAllPositionsOfType(ENUM_POSITION_TYPE pType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == _Symbol)
      {
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         if(posMagic == InpMagicNumber)
         {
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == pType)
            {
               ulong  ticket = PositionGetInteger(POSITION_TICKET);
               double vol    = PositionGetDouble(POSITION_VOLUME);

               MqlTradeRequest  req;
               MqlTradeResult   res;
               ZeroMemory(req);
               ZeroMemory(res);

               req.action       = TRADE_ACTION_DEAL;
               req.symbol       = _Symbol;
               req.position     = ticket;
               req.volume       = vol;
               req.type         = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               req.price        = (pType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               req.deviation    = 50;
               req.magic        = InpMagicNumber;

               if(!OrderSend(req, res))
                  PrintFormat("Close OrderSend error %d for ticket %I64u", GetLastError(), ticket);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open a BUY position with stoploss/takeprofit                     |
//+------------------------------------------------------------------+
void OpenBuyPosition(double lot)
{
   if(lot <= 0.0)
      return;

   lot = NormalizeLot(lot);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl    = (InpStopLoss  > 0) ? price - InpStopLoss  * _Point : 0.0;
   double tp    = (InpTakeProfit> 0) ? price + InpTakeProfit* _Point : 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = ORDER_TYPE_BUY;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 50;
   req.magic        = InpMagicNumber;

   if(!OrderSend(req, res))
      PrintFormat("Buy OrderSend error %d", GetLastError());
}

//+------------------------------------------------------------------+
//| Open a SELL position with stoploss/takeprofit                    |
//+------------------------------------------------------------------+
void OpenSellPosition(double lot)
{
   if(lot <= 0.0)
      return;

   lot = NormalizeLot(lot);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (InpStopLoss  > 0) ? price + InpStopLoss  * _Point : 0.0;
   double tp    = (InpTakeProfit> 0) ? price - InpTakeProfit* _Point : 0.0;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = ORDER_TYPE_SELL;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 50;
   req.magic        = InpMagicNumber;

   if(!OrderSend(req, res))
      PrintFormat("Sell OrderSend error %d", GetLastError());
}

//+------------------------------------------------------------------+
//| Manage Non-EA (Manual) trades to close at money TP               |
//+------------------------------------------------------------------+
void ManageManualTradesMoneyTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      string posSymbol = PositionGetSymbol(i);
      if(posSymbol == _Symbol)
      {
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         // If magic doesn't match our EA's main magic, treat it as a "manual/other" trade
         if(posMagic != InpMagicNumber)
         {
            double floatingProfit = PositionGetDouble(POSITION_PROFIT);
            double swap           = PositionGetDouble(POSITION_SWAP);
            double netProfit      = floatingProfit + swap;

            if(netProfit >= InpManualTPMoney)
            {
               ulong  ticket = PositionGetInteger(POSITION_TICKET);
               long   pType  = PositionGetInteger(POSITION_TYPE);
               double vol    = PositionGetDouble(POSITION_VOLUME);

               MqlTradeRequest  req;
               MqlTradeResult   res;
               ZeroMemory(req);
               ZeroMemory(res);

               req.action       = TRADE_ACTION_DEAL;
               req.symbol       = _Symbol;
               req.position     = ticket;
               req.volume       = vol;
               req.type         = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               req.price        = (pType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               req.deviation    = 50;
               req.magic        = posMagic;

               if(!OrderSend(req, res))
               {
                  PrintFormat("Manual Trade Close Error %d for ticket %I64u", GetLastError(), ticket);
               }
               else
               {
                  PrintFormat("Closed Manual Trade %I64u with Net Profit: %.2f", ticket, netProfit);
               }
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
   //--- 1) Manage manual/other positions for money-based TP
   ManageManualTradesMoneyTP();

   //--- 2) Get current RSI
   double rsiArr[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiArr) <= 0)
      return;
      
   double rsi = rsiArr[0];

   if(firstTick)
   {
      prevRSI = rsi;
      firstTick = false;
      return;
   }

   //--- 3) Get total EA positions
   int totalEATrades = 0;
   GetEAPositionInfo(totalEATrades);

   //===============================================================
   // 5) FIRST ENTRY LOGIC (Stage 1)
   //===============================================================
   bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
   bool crossUpSell = (prevRSI < InpSellLevel) && (rsi >= InpSellLevel);

   if(totalEATrades == 0)
   {
      if(crossUpBuy)
      {
         OpenBuyPosition(InpBaseLot);
         eaTradeSequence = 1; // Buy sequence active
      }
      else if(crossUpSell)
      {
         OpenSellPosition(InpBaseLot);
         eaTradeSequence = 2; // Sell sequence active
      }
   }

   //===============================================================
   // 6) PYRAMIDING / HEDGING LOGIC (Stage 2 & 3)
   //===============================================================
   if(eaTradeSequence == 1) // Buy sequence
   {
      // Stage 2: When RSI reaches 18.18 (<= 18.18), take 0.03 Buy AND 0.03 Sell
      if(totalEATrades == 1 && rsi <= InpBuySecondRSI)
      {
         OpenBuyPosition(InpBaseLot);
         OpenSellPosition(InpBaseLot);
      }
      
      // Stage 3: When RSI goes below 14.14 (<= 14.14), take 0.06 Buy AND 0.03 Sell
      if(totalEATrades == 3 && rsi <= InpBuyThirdRSI)
      {
         OpenBuyPosition(InpBaseLot * 2.0); // 0.06
         OpenSellPosition(InpBaseLot);      // 0.03
      }
      
      // EXIT for Buy Sequence: Close all EA trades when current price is 1000 points above first buy price
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(firstBuyPrice > 0 && currentBid >= (firstBuyPrice + (InpTargetPoints * _Point)))
      {
         CloseAllPositionsOfType(POSITION_TYPE_BUY);
         CloseAllPositionsOfType(POSITION_TYPE_SELL);
         eaTradeSequence = 0;
      }
   }
   else if(eaTradeSequence == 2) // Sell sequence
   {
      // Stage 2: When RSI reaches 84.84 (>= 84.84), take 0.03 Sell AND 0.03 Buy
      if(totalEATrades == 1 && rsi >= InpSellSecondRSI)
      {
         OpenSellPosition(InpBaseLot);
         OpenBuyPosition(InpBaseLot);
      }
      
      // Stage 3: When RSI goes above 89 (>= 89.0), take 0.06 Sell AND 0.03 Buy
      if(totalEATrades == 3 && rsi >= InpSellThirdRSI)
      {
         OpenSellPosition(InpBaseLot * 2.0); // 0.06
         OpenBuyPosition(InpBaseLot);        // 0.03
      }
      
      // EXIT for Sell Sequence: Close all EA trades when current price is 1000 points below first sell price
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(firstSellPrice > 0 && currentAsk <= (firstSellPrice - (InpTargetPoints * _Point)))
      {
         CloseAllPositionsOfType(POSITION_TYPE_BUY);
         CloseAllPositionsOfType(POSITION_TYPE_SELL);
         eaTradeSequence = 0;
      }
   }

   //--- 8) Store current RSI for next-tick cross detection
   prevRSI = rsi;
}
//+------------------------------------------------------------------+