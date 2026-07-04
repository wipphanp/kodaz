//+------------------------------------------------------------------+
//|                                             wipphanp_sumX_hf.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "4.00"
#property strict

//===================================================================
//  INPUTS
//===================================================================

//--- Timeframe ---
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_M5;    // Chart timeframe (M1/M5 for HF scalping)

//--- RSI ---
input int             InpRSIPeriod          = 8;            // RSI period (8 for HF scalping, 14 for swing)
input double          InpBuyLevel           = 32.4;         // RSI cross-up → Stage 1 BUY
input double          InpSellLevel          = 68.81;        // RSI cross-up → Stage 1 SELL
input double          InpBuySecondRSI       = 18.18;        // Stage 2 BUY: RSI <= this
input double          InpBuyThirdRSI        = 14.14;        // Stage 3 BUY: RSI <= this
input double          InpSellSecondRSI      = 84.84;        // Stage 2 SELL: RSI >= this
input double          InpSellThirdRSI       = 89.00;        // Stage 3 SELL: RSI >= this

//--- EMA Stack ---
input int             InpEMAFast            = 9;            // Fast EMA period (signal)
input int             InpEMASlow            = 21;           // Slow EMA period (confirmation)
input int             InpEMATrend           = 200;          // Macro trend EMA period
input bool            InpUseMacroTrend      = true;         // Only trade in EMA200 direction
input bool            InpRequireEMACross    = true;         // Require EMA9 > EMA21 for buy / < for sell

//--- Candle Confirmation ---
input bool            InpUseCandleClose     = true;         // Candle must close above/below EMA9
input bool            InpUseEngulfing       = true;         // Require bullish/bearish engulfing pattern
input bool            InpUsePinbar          = false;        // Require pinbar (hammer/shooting star)
input double          InpPinbarRatio        = 2.0;          // Wick must be X times the body

//--- ATR Dynamic SL/TP ---
input int             InpATRPeriod          = 14;           // ATR period for dynamic SL/TP
input double          InpSLMultiplier       = 1.5;          // SL = ATR * this
input double          InpTPMultiplier       = 2.5;          // TP = ATR * this

//--- Lot Progression (0.01 base) ---
input double          InpStartLot           = 0.01;         // Starting lot size
input double          InpMaxLot             = 0.10;         // Maximum lot cap
input double          InpLotStep            = 0.01;         // Lot increment per win streak level
input int             InpWinStreakStep       = 3;            // Wins needed before next lot increase
input bool            InpResetLotOnLoss     = true;         // Reset lot to StartLot after a loss

//--- Primary Exit (Basket Target Profit) ---
input double          InpTargetMoney        = 15.0;         // Close basket when net P&L >= this

//--- Trailing Basket Stop ---
input double          InpTrailActivateMoney = 10.0;         // Start trailing after P&L reaches this
input double          InpTrailLockInMoney   = 5.0;          // Minimum profit locked in by trail

//--- Emergency Money Stop-Loss ---
input double          InpMaxLossMoney       = -50.0;        // Emergency close if basket P&L <= this

//--- EA Identity ---
input int             InpMagicNumber        = 987654;       // Magic number for EA trades

//--- Manual Trade Management ---
input double          InpManualTPMoney      = 18.18;        // Close manual positions at this net P&L

//--- Execution Quality ---
input int             InpMinBarsBetween     = 2;            // Minimum bars between new Stage 1 entries
input int             InpMaxSpreadPoints    = 30;           // Block entry if spread > this (points)

//===================================================================
//  GLOBAL STATE
//===================================================================

//--- Indicator Handles ---
int    rsiHandle        = INVALID_HANDLE;
int    emaFastHandle    = INVALID_HANDLE;
int    emaSlowHandle    = INVALID_HANDLE;
int    emaTrendHandle   = INVALID_HANDLE;
int    atrHandle        = INVALID_HANDLE;

//--- Bar tracking ---
datetime lastBarTime    = 0;          // Detects new bar open
int      barsSinceTrade = 0;          // Cooldown counter

//--- RSI cross detection ---
double   prevRSI        = 0.0;
bool     firstTick      = true;

//--- Sequence state ---
int      eaTradeSequence  = 0;        // 0=None, 1=Buy, 2=Sell
bool     stage2Triggered  = false;
bool     stage3Triggered  = false;
double   firstBuyPrice    = 0.0;
double   firstSellPrice   = 0.0;

//--- Trailing stop ---
double   peakPnL          = 0.0;

//--- Lot progression ---
double   currentLot       = 0.01;     // Dynamic lot — starts at InpStartLot
int      consecutiveWins  = 0;
int      consecutiveLosses = 0;

//===================================================================
//  UTILITY: Reset all sequence state
//===================================================================
void ResetSequenceState()
{
   eaTradeSequence  = 0;
   stage2Triggered  = false;
   stage3Triggered  = false;
   firstBuyPrice    = 0.0;
   firstSellPrice   = 0.0;
   peakPnL          = 0.0;
}

//===================================================================
//  UTILITY: Normalize lot
//===================================================================
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot)  lot = minLot;
   if(lot > maxLot)  lot = maxLot;
   if(lot > InpMaxLot) lot = InpMaxLot;
   if(stepLot > 0.0) lot = MathFloor(lot / stepLot) * stepLot;

   return lot;
}

//===================================================================
//  UTILITY: Calculate current lot based on win streak
//===================================================================
double GetCurrentLot()
{
   int level = consecutiveWins / InpWinStreakStep;
   double lot = InpStartLot + (level * InpLotStep);
   return NormalizeLot(lot);
}

//===================================================================
//  UTILITY: Sum net P&L (profit + swap) for all EA trades
//===================================================================
double GetTotalEAPnL()
{
   double totalPnL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol)                      continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      totalPnL += PositionGetDouble(POSITION_PROFIT);
      totalPnL += PositionGetDouble(POSITION_SWAP);
   }
   return totalPnL;
}

//===================================================================
//  UTILITY: Count EA positions + cache first-entry prices
//===================================================================
void GetEAPositionInfo(int &totalEATrades)
{
   totalEATrades = 0;

   double tempFirstBuyPrice  = 0.0;
   double tempFirstSellPrice = 0.0;
   ulong  firstBuyTime       = 0;
   ulong  firstSellTime      = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol)                      continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      totalEATrades++;

      ulong posTime = (ulong)PositionGetInteger(POSITION_TIME);
      long  posType = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
      {
         if(firstBuyTime == 0 || posTime < firstBuyTime)
         {
            firstBuyTime      = posTime;
            tempFirstBuyPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(firstSellTime == 0 || posTime < firstSellTime)
         {
            firstSellTime      = posTime;
            tempFirstSellPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }

   if(totalEATrades > 0)
   {
      if(eaTradeSequence == 1 && firstBuyPrice  == 0.0) firstBuyPrice  = tempFirstBuyPrice;
      if(eaTradeSequence == 2 && firstSellPrice == 0.0) firstSellPrice = tempFirstSellPrice;
   }
   else
   {
      ResetSequenceState();
   }
}

//===================================================================
//  CANDLE PATTERN: Bullish Engulfing
//===================================================================
bool IsBullishEngulfing()
{
   double c1Open  = iOpen (_Symbol, InpTimeframe, 1);
   double c1Close = iClose(_Symbol, InpTimeframe, 1);
   double c2Open  = iOpen (_Symbol, InpTimeframe, 2);
   double c2Close = iClose(_Symbol, InpTimeframe, 2);

   return (c1Close > c1Open)  &&   // c1 is bullish
          (c2Close < c2Open)  &&   // c2 was bearish
          (c1Close > c2Open)  &&   // c1 body engulfs c2 body top
          (c1Open  < c2Close);     // c1 body engulfs c2 body bottom
}

//===================================================================
//  CANDLE PATTERN: Bearish Engulfing
//===================================================================
bool IsBearishEngulfing()
{
   double c1Open  = iOpen (_Symbol, InpTimeframe, 1);
   double c1Close = iClose(_Symbol, InpTimeframe, 1);
   double c2Open  = iOpen (_Symbol, InpTimeframe, 2);
   double c2Close = iClose(_Symbol, InpTimeframe, 2);

   return (c1Close < c1Open)  &&   // c1 is bearish
          (c2Close > c2Open)  &&   // c2 was bullish
          (c1Close < c2Open)  &&   // c1 body engulfs c2 body bottom
          (c1Open  > c2Close);     // c1 body engulfs c2 body top
}

//===================================================================
//  CANDLE PATTERN: Bullish Pinbar (Hammer)
//  Lower wick >= InpPinbarRatio * body, small upper wick
//===================================================================
bool IsBullishPinbar()
{
   double high   = iHigh (_Symbol, InpTimeframe, 1);
   double low    = iLow  (_Symbol, InpTimeframe, 1);
   double open   = iOpen (_Symbol, InpTimeframe, 1);
   double close  = iClose(_Symbol, InpTimeframe, 1);

   double body      = MathAbs(close - open);
   double lowerWick = MathMin(open, close) - low;
   double upperWick = high - MathMax(open, close);

   if(body <= 0) return false;

   return (lowerWick >= InpPinbarRatio * body) &&  // Long lower wick
          (upperWick <= body);                      // Small upper wick
}

//===================================================================
//  CANDLE PATTERN: Bearish Pinbar (Shooting Star)
//  Upper wick >= InpPinbarRatio * body, small lower wick
//===================================================================
bool IsBearishPinbar()
{
   double high   = iHigh (_Symbol, InpTimeframe, 1);
   double low    = iLow  (_Symbol, InpTimeframe, 1);
   double open   = iOpen (_Symbol, InpTimeframe, 1);
   double close  = iClose(_Symbol, InpTimeframe, 1);

   double body      = MathAbs(close - open);
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;

   if(body <= 0) return false;

   return (upperWick >= InpPinbarRatio * body) &&  // Long upper wick
          (lowerWick <= body);                      // Small lower wick
}

//===================================================================
//  SIGNAL: Check all BUY conditions
//===================================================================
bool CheckBuySignal(double rsi, double emaFast, double emaSlow, double emaTrend)
{
   double lastClose = iClose(_Symbol, InpTimeframe, 1);

   // 1. RSI in bullish zone (not overbought)
   if(rsi < 50.0 || rsi > 70.0) return false;

   // 2. EMA cross: fast > slow
   if(InpRequireEMACross && emaFast <= emaSlow) return false;

   // 3. Candle closed above EMA9
   if(InpUseCandleClose && lastClose <= emaFast) return false;

   // 4. Macro trend filter: price above EMA200
   if(InpUseMacroTrend && lastClose <= emaTrend) return false;

   // 5. Candle pattern (at least one required if both enabled)
   if(InpUseEngulfing || InpUsePinbar)
   {
      bool engulf = InpUseEngulfing && IsBullishEngulfing();
      bool pinbar = InpUsePinbar   && IsBullishPinbar();
      if(!engulf && !pinbar) return false;
   }

   return true;
}

//===================================================================
//  SIGNAL: Check all SELL conditions
//===================================================================
bool CheckSellSignal(double rsi, double emaFast, double emaSlow, double emaTrend)
{
   double lastClose = iClose(_Symbol, InpTimeframe, 1);

   // 1. RSI in bearish zone (not oversold)
   if(rsi > 50.0 || rsi < 30.0) return false;

   // 2. EMA cross: fast < slow
   if(InpRequireEMACross && emaFast >= emaSlow) return false;

   // 3. Candle closed below EMA9
   if(InpUseCandleClose && lastClose >= emaFast) return false;

   // 4. Macro trend filter: price below EMA200
   if(InpUseMacroTrend && lastClose >= emaTrend) return false;

   // 5. Candle pattern
   if(InpUseEngulfing || InpUsePinbar)
   {
      bool engulf = InpUseEngulfing && IsBearishEngulfing();
      bool pinbar = InpUsePinbar   && IsBearishPinbar();
      if(!engulf && !pinbar) return false;
   }

   return true;
}

//===================================================================
//  TRADE: Close ALL EA positions — basket exit
//===================================================================
void CloseAllEAPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol)                      continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      long   pType  = PositionGetInteger(POSITION_TYPE);
      double vol    = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action    = TRADE_ACTION_DEAL;
      req.symbol    = _Symbol;
      req.position  = ticket;
      req.volume    = vol;
      req.type      = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (pType == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 50;
      req.magic     = InpMagicNumber;

      if(!OrderSend(req, res))
         PrintFormat("CloseAll ERROR %d | Ticket: %I64u", GetLastError(), ticket);
      else
         PrintFormat("CLOSED | Ticket: %I64u | %s | Vol: %.2f",
                     ticket, (pType == POSITION_TYPE_BUY ? "BUY" : "SELL"), vol);
   }
}

//===================================================================
//  TRADE: Close hedge positions only
//===================================================================
void CloseHedgePositions()
{
   if(eaTradeSequence == 0) return;

   ENUM_POSITION_TYPE hedgeType = (eaTradeSequence == 1)
                                  ? POSITION_TYPE_SELL
                                  : POSITION_TYPE_BUY;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol)                                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)               continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != hedgeType) continue;

      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      double vol    = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action    = TRADE_ACTION_DEAL;
      req.symbol    = _Symbol;
      req.position  = ticket;
      req.volume    = vol;
      req.type      = (hedgeType == POSITION_TYPE_SELL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      req.price     = (hedgeType == POSITION_TYPE_SELL)
                      ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                      : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      req.deviation = 50;
      req.magic     = InpMagicNumber;

      if(!OrderSend(req, res))
         PrintFormat("CloseHedge ERROR %d | Ticket: %I64u", GetLastError(), ticket);
      else
         PrintFormat("HEDGE CLOSED | Ticket: %I64u | Vol: %.2f", ticket, vol);
   }
}

//===================================================================
//  TRADE: Open BUY with ATR-based SL/TP
//===================================================================
void OpenBuyPosition(double lot)
{
   if(lot <= 0.0) return;
   lot = NormalizeLot(lot);

   // Get ATR for dynamic SL/TP
   double atrArr[1];
   double sl = 0.0, tp = 0.0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrArr) > 0 && atrArr[0] > 0)
   {
      double atr = atrArr[0];
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - atr * InpSLMultiplier;
      tp = price + atr * InpTPMultiplier;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lot;
   req.type      = ORDER_TYPE_BUY;
   req.price     = price;
   req.sl        = sl;
   req.tp        = tp;
   req.deviation = 50;
   req.magic     = InpMagicNumber;

   if(!OrderSend(req, res))
      PrintFormat("OpenBuy ERROR %d", GetLastError());
   else
      PrintFormat("BUY OPENED | Lot: %.2f | Ask: %.5f | SL: %.5f | TP: %.5f", lot, price, sl, tp);
}

//===================================================================
//  TRADE: Open SELL with ATR-based SL/TP
//===================================================================
void OpenSellPosition(double lot)
{
   if(lot <= 0.0) return;
   lot = NormalizeLot(lot);

   double atrArr[1];
   double sl = 0.0, tp = 0.0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrArr) > 0 && atrArr[0] > 0)
   {
      double atr = atrArr[0];
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + atr * InpSLMultiplier;
      tp = price - atr * InpTPMultiplier;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lot;
   req.type      = ORDER_TYPE_SELL;
   req.price     = price;
   req.sl        = sl;
   req.tp        = tp;
   req.deviation = 50;
   req.magic     = InpMagicNumber;

   if(!OrderSend(req, res))
      PrintFormat("OpenSell ERROR %d", GetLastError());
   else
      PrintFormat("SELL OPENED | Lot: %.2f | Bid: %.5f | SL: %.5f | TP: %.5f", lot, price, sl, tp);
}

//===================================================================
//  TRADE: Manage manual (non-EA) positions at money TP
//===================================================================
void ManageManualTradesMoneyTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol)                      continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) continue;

      double netProfit = PositionGetDouble(POSITION_PROFIT)
                       + PositionGetDouble(POSITION_SWAP);
      if(netProfit < InpManualTPMoney) continue;

      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      long   pType  = PositionGetInteger(POSITION_TYPE);
      double vol    = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action    = TRADE_ACTION_DEAL;
      req.symbol    = _Symbol;
      req.position  = ticket;
      req.volume    = vol;
      req.type      = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (pType == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 50;
      req.magic     = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(!OrderSend(req, res))
         PrintFormat("ManualClose ERROR %d | Ticket: %I64u", GetLastError(), ticket);
      else
         PrintFormat("MANUAL CLOSED | Ticket: %I64u | Net P&L: %.2f", ticket, netProfit);
   }
}

//===================================================================
//  OnTradeTransaction — Track wins/losses for lot progression
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   // Only process when a deal is added (position closed)
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   // Select the deal
   if(!HistoryDealSelect(trans.deal)) return;

   // Only EA deals
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;

   // Only closing deals (DEAL_ENTRY_OUT)
   long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT) return;

   double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double dealSwap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   double netDeal    = dealProfit + dealSwap;

   if(netDeal >= 0)
   {
      consecutiveWins++;
      if(InpResetLotOnLoss) consecutiveLosses = 0;
      currentLot = GetCurrentLot();
      PrintFormat("[LOT PROGRESSION] WIN | Streak: %d | Next Lot: %.2f",
                  consecutiveWins, currentLot);
   }
   else
   {
      consecutiveLosses++;
      if(InpResetLotOnLoss)
      {
         consecutiveWins = 0;
         currentLot      = InpStartLot;
         PrintFormat("[LOT PROGRESSION] LOSS | Reset to StartLot: %.2f", currentLot);
      }
   }
}

//===================================================================
//  OnInit — Validate inputs, create all indicator handles
//===================================================================
int OnInit()
{
   // RSI level ordering
   if(InpBuySecondRSI >= InpBuyLevel)
   { PrintFormat("INIT ERROR: BuySecondRSI(%.2f) must be < BuyLevel(%.2f)", InpBuySecondRSI, InpBuyLevel); return INIT_FAILED; }
   if(InpBuyThirdRSI >= InpBuySecondRSI)
   { PrintFormat("INIT ERROR: BuyThirdRSI(%.2f) must be < BuySecondRSI(%.2f)", InpBuyThirdRSI, InpBuySecondRSI); return INIT_FAILED; }
   if(InpSellSecondRSI <= InpSellLevel)
   { PrintFormat("INIT ERROR: SellSecondRSI(%.2f) must be > SellLevel(%.2f)", InpSellSecondRSI, InpSellLevel); return INIT_FAILED; }
   if(InpSellThirdRSI <= InpSellSecondRSI)
   { PrintFormat("INIT ERROR: SellThirdRSI(%.2f) must be > SellSecondRSI(%.2f)", InpSellThirdRSI, InpSellSecondRSI); return INIT_FAILED; }

   // Money targets
   if(InpTargetMoney <= 0.0)
   { PrintFormat("INIT ERROR: InpTargetMoney(%.2f) must be > 0", InpTargetMoney); return INIT_FAILED; }
   if(InpTrailActivateMoney >= InpTargetMoney)
   { PrintFormat("INIT ERROR: TrailActivate(%.2f) must be < TargetMoney(%.2f)", InpTrailActivateMoney, InpTargetMoney); return INIT_FAILED; }
   if(InpTrailLockInMoney >= InpTrailActivateMoney)
   { PrintFormat("INIT ERROR: TrailLockIn(%.2f) must be < TrailActivate(%.2f)", InpTrailLockInMoney, InpTrailActivateMoney); return INIT_FAILED; }
   if(InpMaxLossMoney >= 0.0)
   { PrintFormat("INIT ERROR: MaxLossMoney(%.2f) must be negative", InpMaxLossMoney); return INIT_FAILED; }

   // Lot validation
   if(InpStartLot <= 0.0)
   { PrintFormat("INIT ERROR: StartLot(%.2f) must be > 0", InpStartLot); return INIT_FAILED; }
   if(InpMaxLot < InpStartLot)
   { PrintFormat("INIT ERROR: MaxLot(%.2f) must be >= StartLot(%.2f)", InpMaxLot, InpStartLot); return INIT_FAILED; }

   // Create RSI handle
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   { PrintFormat("INIT ERROR: iRSI failed. Error=%d", GetLastError()); return INIT_FAILED; }

   // Create EMA handles
   emaFastHandle = iMA(_Symbol, InpTimeframe, InpEMAFast,  0, MODE_EMA, PRICE_CLOSE);
   if(emaFastHandle == INVALID_HANDLE)
   { PrintFormat("INIT ERROR: EMA Fast failed. Error=%d", GetLastError()); return INIT_FAILED; }

   emaSlowHandle = iMA(_Symbol, InpTimeframe, InpEMASlow,  0, MODE_EMA, PRICE_CLOSE);
   if(emaSlowHandle == INVALID_HANDLE)
   { PrintFormat("INIT ERROR: EMA Slow failed. Error=%d", GetLastError()); return INIT_FAILED; }

   emaTrendHandle = iMA(_Symbol, InpTimeframe, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
   if(emaTrendHandle == INVALID_HANDLE)
   { PrintFormat("INIT ERROR: EMA Trend failed. Error=%d", GetLastError()); return INIT_FAILED; }

   // Create ATR handle
   atrHandle = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   { PrintFormat("INIT ERROR: iATR failed. Error=%d", GetLastError()); return INIT_FAILED; }

   // Init lot
   currentLot = NormalizeLot(InpStartLot);

   PrintFormat("=== EA v4.00 HF Scalper Initialized ===");
   PrintFormat("Symbol: %s | TF: %s | RSI: %d | EMA: %d/%d/%d | ATR: %d",
               _Symbol, EnumToString(InpTimeframe), InpRSIPeriod,
               InpEMAFast, InpEMASlow, InpEMATrend, InpATRPeriod);
   PrintFormat("StartLot: %.2f | MaxLot: %.2f | WinStreakStep: %d | LotStep: %.2f",
               InpStartLot, InpMaxLot, InpWinStreakStep, InpLotStep);
   PrintFormat("Target: %.2f | TrailActivate: %.2f | TrailLock: %.2f | EmergSL: %.2f",
               InpTargetMoney, InpTrailActivateMoney, InpTrailLockInMoney, InpMaxLossMoney);
   PrintFormat("CandleClose: %s | Engulfing: %s | Pinbar: %s | MacroTrend: %s",
               (InpUseCandleClose?"ON":"OFF"), (InpUseEngulfing?"ON":"OFF"),
               (InpUsePinbar?"ON":"OFF"), (InpUseMacroTrend?"ON":"OFF"));

   return INIT_SUCCEEDED;
}

//===================================================================
//  OnDeinit
//===================================================================
void OnDeinit(const int reason)
{
   if(rsiHandle     != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   if(emaTrendHandle!= INVALID_HANDLE) IndicatorRelease(emaTrendHandle);
   if(atrHandle     != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Comment("");
}

//===================================================================
//  OnTick — Main EA Logic (8 Steps)
//===================================================================
void OnTick()
{
   //----------------------------------------------------------------
   //  STEP 1: Manage manual positions
   //----------------------------------------------------------------
   ManageManualTradesMoneyTP();

   //----------------------------------------------------------------
   //  STEP 2: BAR-OPEN GATE
   //  Only evaluate signals once per new bar (not every tick).
   //  This is essential for HF scalping to avoid signal noise.
   //----------------------------------------------------------------
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);
   bool isNewBar = (currentBarTime != lastBarTime);
   if(isNewBar)
   {
      lastBarTime = currentBarTime;
      barsSinceTrade++;
   }

   //----------------------------------------------------------------
   //  STEP 3: Read all indicator values
   //----------------------------------------------------------------
   double rsiArr[1], emaFastArr[1], emaSlowArr[1], emaTrendArr[1];

   if(CopyBuffer(rsiHandle,      0, 0, 1, rsiArr)      <= 0) return;
   if(CopyBuffer(emaFastHandle,  0, 0, 1, emaFastArr)  <= 0) return;
   if(CopyBuffer(emaSlowHandle,  0, 0, 1, emaSlowArr)  <= 0) return;
   if(CopyBuffer(emaTrendHandle, 0, 0, 1, emaTrendArr) <= 0) return;

   double rsi      = rsiArr[0];
   double emaFast  = emaFastArr[0];
   double emaSlow  = emaSlowArr[0];
   double emaTrend = emaTrendArr[0];

   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   //----------------------------------------------------------------
   //  STEP 4: Count EA positions + cache first-entry prices
   //----------------------------------------------------------------
   int totalEATrades = 0;
   GetEAPositionInfo(totalEATrades);

   //----------------------------------------------------------------
   //  STEP 5: EXIT LOGIC (runs every tick, not bar-gated)
   //
   //  Priority: Emergency SL → Trailing Stop → Target TP
   //----------------------------------------------------------------
   if(totalEATrades > 0)
   {
      double netPnL = GetTotalEAPnL();
      if(netPnL > peakPnL) peakPnL = netPnL;

      // Live chart dashboard
      Comment(StringFormat(
         "=== RSI+EMA HF Scalper v4.00 ===\n"
         "Sequence  : %s\n"
         "EA Trades : %d\n"
         "Net P&L   : %.2f\n"
         "Peak P&L  : %.2f\n"
         "Target TP : %.2f\n"
         "Trail     : Activate=%.2f  Lock=%.2f\n"
         "Emrg SL   : %.2f\n"
         "Stage 2   : %s  |  Stage 3: %s\n"
         "RSI       : %.2f\n"
         "EMA 9/21  : %.5f / %.5f\n"
         "EMA 200   : %.5f\n"
         "Lot       : %.2f  (Wins: %d)",
         (eaTradeSequence==1?"BUY":eaTradeSequence==2?"SELL":"FLAT"),
         totalEATrades, netPnL, peakPnL, InpTargetMoney,
         InpTrailActivateMoney, InpTrailLockInMoney,
         InpMaxLossMoney,
         (stage2Triggered?"YES":"NO"), (stage3Triggered?"YES":"NO"),
         rsi, emaFast, emaSlow, emaTrend,
         currentLot, consecutiveWins));

      // 5a. EMERGENCY STOP
      if(netPnL <= InpMaxLossMoney)
      {
         PrintFormat("!!! EMERGENCY STOP | P&L: %.2f <= MaxLoss: %.2f", netPnL, InpMaxLossMoney);
         CloseAllEAPositions();
         ResetSequenceState();
         prevRSI = rsi;
         return;
      }

      // 5b. TRAILING STOP
      if(peakPnL >= InpTrailActivateMoney)
      {
         if(netPnL <= InpTrailLockInMoney)
         {
            PrintFormat(">>> TRAIL STOP | Peak: %.2f | P&L: %.2f | Floor: %.2f",
                        peakPnL, netPnL, InpTrailLockInMoney);
            CloseAllEAPositions();
            ResetSequenceState();
            prevRSI = rsi;
            return;
         }
      }

      // 5c. TARGET TP
      if(netPnL >= InpTargetMoney)
      {
         PrintFormat(">>> TARGET HIT | P&L: %.2f >= %.2f", netPnL, InpTargetMoney);
         CloseAllEAPositions();
         ResetSequenceState();
         prevRSI = rsi;
         return;
      }
   }
   else
   {
      Comment(StringFormat(
         "=== RSI+EMA HF Scalper v4.00 ===\n"
         "Sequence  : FLAT\n"
         "RSI       : %.2f\n"
         "EMA 9/21  : %.5f / %.5f\n"
         "EMA 200   : %.5f\n"
         "Lot       : %.2f  (Wins: %d)\n"
         "Bars Since Trade: %d",
         rsi, emaFast, emaSlow, emaTrend, currentLot, consecutiveWins, barsSinceTrade));
   }

   //----------------------------------------------------------------
   //  STEP 6: ENTRY LOGIC — Bar-gated (new bar only)
   //----------------------------------------------------------------
   if(!isNewBar) { prevRSI = rsi; return; }

   // Spread filter — skip wide-spread conditions
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
   {
      PrintFormat("[SPREAD FILTER] Spread: %.0f > Max: %d. Skipping.", spread, InpMaxSpreadPoints);
      prevRSI = rsi;
      return;
   }

   //----------------------------------------------------------------
   //  STEP 7: STAGE 1 — First Entry (when flat + cooldown passed)
   //
   //  Two-layer entry:
   //    Layer 1: RSI cross (original v1 logic, retained)
   //    Layer 2: EMA + candle confirmation (new in v4)
   //
   //  BOTH layers must agree to open Stage 1.
   //----------------------------------------------------------------
   bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
   bool crossUpSell = (prevRSI < InpSellLevel)  && (rsi >= InpSellLevel);

   if(totalEATrades == 0 && barsSinceTrade >= InpMinBarsBetween)
   {
      if(crossUpBuy && CheckBuySignal(rsi, emaFast, emaSlow, emaTrend))
      {
         PrintFormat(">>> STAGE 1 BUY | RSI: %.2f | EMA9: %.5f | EMA21: %.5f | Lot: %.2f",
                     rsi, emaFast, emaSlow, currentLot);
         OpenBuyPosition(currentLot);
         eaTradeSequence  = 1;
         stage2Triggered  = false;
         stage3Triggered  = false;
         firstBuyPrice    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         firstSellPrice   = 0.0;
         peakPnL          = 0.0;
         barsSinceTrade   = 0;
      }
      else if(crossUpSell && CheckSellSignal(rsi, emaFast, emaSlow, emaTrend))
      {
         PrintFormat(">>> STAGE 1 SELL | RSI: %.2f | EMA9: %.5f | EMA21: %.5f | Lot: %.2f",
                     rsi, emaFast, emaSlow, currentLot);
         OpenSellPosition(currentLot);
         eaTradeSequence  = 2;
         stage2Triggered  = false;
         stage3Triggered  = false;
         firstSellPrice   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         firstBuyPrice    = 0.0;
         peakPnL          = 0.0;
         barsSinceTrade   = 0;
      }
   }

   //----------------------------------------------------------------
   //  STEP 8: STAGE 2 & 3 — Pyramid / Hedge Entries
   //  (RSI-level based, same as v3 — uses currentLot for base)
   //----------------------------------------------------------------
   if(eaTradeSequence == 1) // BUY sequence
   {
      if(!stage2Triggered && rsi <= InpBuySecondRSI)
      {
         PrintFormat(">>> STAGE 2 BUY | RSI: %.2f <= %.2f", rsi, InpBuySecondRSI);
         OpenBuyPosition(currentLot);
         OpenSellPosition(currentLot);
         stage2Triggered = true;
      }
      if(stage2Triggered && !stage3Triggered && rsi <= InpBuyThirdRSI)
      {
         PrintFormat(">>> STAGE 3 BUY | RSI: %.2f <= %.2f", rsi, InpBuyThirdRSI);
         OpenBuyPosition(currentLot * 2.0);
         OpenSellPosition(currentLot);
         stage3Triggered = true;
      }
   }
   else if(eaTradeSequence == 2) // SELL sequence
   {
      if(!stage2Triggered && rsi >= InpSellSecondRSI)
      {
         PrintFormat(">>> STAGE 2 SELL | RSI: %.2f >= %.2f", rsi, InpSellSecondRSI);
         OpenSellPosition(currentLot);
         OpenBuyPosition(currentLot);
         stage2Triggered = true;
      }
      if(stage2Triggered && !stage3Triggered && rsi >= InpSellThirdRSI)
      {
         PrintFormat(">>> STAGE 3 SELL | RSI: %.2f >= %.2f", rsi, InpSellThirdRSI);
         OpenSellPosition(currentLot * 2.0);
         OpenBuyPosition(currentLot);
         stage3Triggered = true;
      }
   }

   //----------------------------------------------------------------
   //  Store RSI for next bar cross detection
   //----------------------------------------------------------------
   prevRSI = rsi;
}
//+------------------------------------------------------------------+
