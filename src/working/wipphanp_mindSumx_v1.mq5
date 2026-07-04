//+------------------------------------------------------------------+
//|                                         wipphanp_mindSumx_v1.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "3.00"
#property strict

//===================================================================
//  INPUTS
//===================================================================

//--- RSI & Entry ---
input int             InpRSIPeriod        = 14;             // RSI period
input double          InpBuyLevel         = 32.4;           // RSI cross-up level → Stage 1 BUY
input double          InpSellLevel        = 68.81;          // RSI cross-up level → Stage 1 SELL
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_CURRENT; // Timeframe for RSI calculation

//--- Primary Exit (Target Profit) ---
input double          InpTargetMoney      = 15.0;           // Close basket when net P&L >= this (account currency)

//--- Trailing Basket Stop ---
input double          InpTrailActivateMoney = 10.0;         // Start trailing only after P&L reaches this level
input double          InpTrailLockInMoney   = 5.0;          // Minimum profit to lock in once trailing activates

//--- Emergency Money Stop-Loss ---
input double          InpMaxLossMoney     = -50.0;          // Emergency close if basket net P&L <= this (must be negative)

//--- Per-Trade SL / TP (optional) ---
input double          InpStopLoss         = 0;              // Stop-loss in points per trade (0 = disabled)
input double          InpTakeProfit       = 0;              // Take-profit in points per trade (0 = disabled)

//--- EA Identity ---
input int             InpMagicNumber      = 987654;         // Magic number to identify EA trades

//--- Lot Sizing ---
input double          InpBaseLot          = 0.03;           // Base lot for Stage 1 entries and hedges

//--- Buy Sequence Pyramid Levels ---
input double          InpBuySecondRSI     = 18.18;          // Stage 2 BUY: RSI <= this → +0.03 Buy +0.03 Sell
input double          InpBuyThirdRSI      = 14.14;          // Stage 3 BUY: RSI <= this → +0.06 Buy +0.03 Sell

//--- Sell Sequence Pyramid Levels ---
input double          InpSellSecondRSI    = 84.84;          // Stage 2 SELL: RSI >= this → +0.03 Sell +0.03 Buy
input double          InpSellThirdRSI     = 89.00;          // Stage 3 SELL: RSI >= this → +0.06 Sell +0.03 Buy

//--- Manual Trade Management ---
input double          InpManualTPMoney    = 18.18;          // Close manual (non-EA) positions when net P&L >= this

//===================================================================
//  GLOBAL STATE
//===================================================================

int    rsiHandle        = INVALID_HANDLE; // Handle for iRSI indicator
double prevRSI          = 0.0;            // RSI value from previous tick
bool   firstTick        = true;           // Seed prevRSI on first tick, skip logic

int    eaTradeSequence  = 0;              // 0=None, 1=Buy Sequence, 2=Sell Sequence
bool   stage2Triggered  = false;          // TRUE after Stage 2 entries placed
bool   stage3Triggered  = false;          // TRUE after Stage 3 entries placed

double firstBuyPrice    = 0.0;            // Open price of first BUY in current sequence
double firstSellPrice   = 0.0;            // Open price of first SELL in current sequence

// --- NEW in v3.00 ---
double peakPnL          = 0.0;            // Highest net P&L seen in current sequence (for trailing stop)

//===================================================================
//  UTILITY: Reset all sequence state (called after every basket exit)
//===================================================================
void ResetSequenceState()
{
   eaTradeSequence = 0;
   stage2Triggered = false;
   stage3Triggered = false;
   firstBuyPrice   = 0.0;
   firstSellPrice  = 0.0;
   peakPnL         = 0.0;   // Reset trailing peak
}

//===================================================================
//  UTILITY: Normalize lot to broker min/max/step
//===================================================================
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot)  lot = minLot;
   if(lot > maxLot)  lot = maxLot;
   if(stepLot > 0.0) lot = MathFloor(lot / stepLot) * stepLot;

   return lot;
}

//===================================================================
//  UTILITY: Sum net P&L (floating profit + swap) across all EA trades
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
//  UTILITY: Count EA positions, cache first-entry prices.
//           Auto-resets all state when position count drops to zero.
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
      // Only cache first-entry price once per sequence
      // (prevents hedge fills from overwriting original entry price)
      if(eaTradeSequence == 1 && firstBuyPrice  == 0.0) firstBuyPrice  = tempFirstBuyPrice;
      if(eaTradeSequence == 2 && firstSellPrice == 0.0) firstSellPrice = tempFirstSellPrice;
   }
   else
   {
      // Fully flat — reset all state including trailing peak
      ResetSequenceState();
   }
}

//===================================================================
//  TRADE: Close ALL EA positions (buys + sells) — basket exit
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
                     ticket,
                     (pType == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                     vol);
   }
}

//===================================================================
//  TRADE: Close only hedge (counter-direction) positions.
//         SELLs in a Buy sequence, BUYs in a Sell sequence.
//         Utility for future staggered exit strategies.
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
//  TRADE: Open a BUY position at market
//===================================================================
void OpenBuyPosition(double lot)
{
   if(lot <= 0.0) return;
   lot = NormalizeLot(lot);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl    = (InpStopLoss   > 0) ? price - InpStopLoss   * _Point : 0.0;
   double tp    = (InpTakeProfit > 0) ? price + InpTakeProfit * _Point : 0.0;

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
//  TRADE: Open a SELL position at market
//===================================================================
void OpenSellPosition(double lot)
{
   if(lot <= 0.0) return;
   lot = NormalizeLot(lot);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (InpStopLoss   > 0) ? price + InpStopLoss   * _Point : 0.0;
   double tp    = (InpTakeProfit > 0) ? price - InpTakeProfit * _Point : 0.0;

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
//  TRADE: Close manual (non-EA magic) positions at money-based TP
//===================================================================
void ManageManualTradesMoneyTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol)                      continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) continue; // skip EA trades

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
//  OnInit — Validate inputs, create RSI handle
//===================================================================
int OnInit()
{
   //--- Buy RSI ordering: BuyLevel > BuySecondRSI > BuyThirdRSI
   if(InpBuySecondRSI >= InpBuyLevel)
   {
      PrintFormat("INIT ERROR: InpBuySecondRSI (%.2f) must be < InpBuyLevel (%.2f)",
                  InpBuySecondRSI, InpBuyLevel);
      return INIT_FAILED;
   }
   if(InpBuyThirdRSI >= InpBuySecondRSI)
   {
      PrintFormat("INIT ERROR: InpBuyThirdRSI (%.2f) must be < InpBuySecondRSI (%.2f)",
                  InpBuyThirdRSI, InpBuySecondRSI);
      return INIT_FAILED;
   }

   //--- Sell RSI ordering: SellLevel < SellSecondRSI < SellThirdRSI
   if(InpSellSecondRSI <= InpSellLevel)
   {
      PrintFormat("INIT ERROR: InpSellSecondRSI (%.2f) must be > InpSellLevel (%.2f)",
                  InpSellSecondRSI, InpSellLevel);
      return INIT_FAILED;
   }
   if(InpSellThirdRSI <= InpSellSecondRSI)
   {
      PrintFormat("INIT ERROR: InpSellThirdRSI (%.2f) must be > InpSellSecondRSI (%.2f)",
                  InpSellThirdRSI, InpSellSecondRSI);
      return INIT_FAILED;
   }

   //--- Target money > 0
   if(InpTargetMoney <= 0.0)
   {
      PrintFormat("INIT ERROR: InpTargetMoney (%.2f) must be > 0", InpTargetMoney);
      return INIT_FAILED;
   }

   //--- Trail activate must be < target (otherwise trailing never makes sense)
   if(InpTrailActivateMoney >= InpTargetMoney)
   {
      PrintFormat("INIT ERROR: InpTrailActivateMoney (%.2f) must be < InpTargetMoney (%.2f)",
                  InpTrailActivateMoney, InpTargetMoney);
      return INIT_FAILED;
   }

   //--- Lock-in must be < activate (you can't lock in more than you've activated at)
   if(InpTrailLockInMoney >= InpTrailActivateMoney)
   {
      PrintFormat("INIT ERROR: InpTrailLockInMoney (%.2f) must be < InpTrailActivateMoney (%.2f)",
                  InpTrailLockInMoney, InpTrailActivateMoney);
      return INIT_FAILED;
   }

   //--- Emergency loss must be negative
   if(InpMaxLossMoney >= 0.0)
   {
      PrintFormat("INIT ERROR: InpMaxLossMoney (%.2f) must be a negative value (e.g. -50.0)",
                  InpMaxLossMoney);
      return INIT_FAILED;
   }

   //--- Create RSI handle
   rsiHandle = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      PrintFormat("INIT ERROR: iRSI handle failed. Error=%d", GetLastError());
      return INIT_FAILED;
   }

   PrintFormat("=== EA v3.00 Initialized ===");
   PrintFormat("Symbol: %s | TF: %s | RSI Period: %d",
               _Symbol, EnumToString(InpTimeframe), InpRSIPeriod);
   PrintFormat("Buy  Levels — S1: %.2f | S2: %.2f | S3: %.2f",
               InpBuyLevel, InpBuySecondRSI, InpBuyThirdRSI);
   PrintFormat("Sell Levels — S1: %.2f | S2: %.2f | S3: %.2f",
               InpSellLevel, InpSellSecondRSI, InpSellThirdRSI);
   PrintFormat("Target: %.2f | Trail Activate: %.2f | Trail Lock-In: %.2f | Emergency SL: %.2f",
               InpTargetMoney, InpTrailActivateMoney, InpTrailLockInMoney, InpMaxLossMoney);
   PrintFormat("BaseLot: %.2f | Magic: %d", InpBaseLot, InpMagicNumber);

   return INIT_SUCCEEDED;
}

//===================================================================
//  OnDeinit — Release RSI handle
//===================================================================
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
   {
      IndicatorRelease(rsiHandle);
      rsiHandle = INVALID_HANDLE;
   }
   Comment(""); // Clear dashboard
}

//===================================================================
//  OnTick — Main EA Logic (8 Steps)
//===================================================================
void OnTick()
{
   //----------------------------------------------------------------
   //  STEP 1: Manage manual/non-EA positions for money-based TP
   //----------------------------------------------------------------
   ManageManualTradesMoneyTP();

   //----------------------------------------------------------------
   //  STEP 2: Read current RSI value
   //----------------------------------------------------------------
   double rsiArr[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiArr) <= 0)
      return; // Indicator buffer not ready

   double rsi = rsiArr[0];

   // Seed prevRSI on very first tick — skip all logic this tick
   if(firstTick)
   {
      prevRSI   = rsi;
      firstTick = false;
      return;
   }

   //----------------------------------------------------------------
   //  STEP 3: Count EA positions, cache first-entry prices.
   //          Auto-resets state when all positions are closed.
   //----------------------------------------------------------------
   int totalEATrades = 0;
   GetEAPositionInfo(totalEATrades);

   //----------------------------------------------------------------
   //  STEP 4: EXIT LOGIC — Three-layer protection (priority order)
   //
   //  All three checks run only when EA positions are open.
   //  Priority: Emergency Stop → Trailing Stop → Target TP
   //
   //  4a. EMERGENCY MONEY STOP-LOSS
   //      Hard floor to protect the account from catastrophic loss.
   //      Fires when net P&L <= InpMaxLossMoney (a negative number).
   //      This overrides everything — no waiting for recovery.
   //
   //  4b. TRAILING BASKET STOP
   //      Activates once P&L reaches InpTrailActivateMoney.
   //      Tracks highest P&L seen (peakPnL).
   //      Closes basket if P&L falls back below:
   //         peakPnL - (peakPnL - InpTrailLockInMoney)
   //      = InpTrailLockInMoney  ← the locked-in floor
   //      Example: Activate=10, LockIn=5, peakPnL=12
   //         Trail fires if P&L drops to <= 5 (locks in $5 profit)
   //
   //  4c. NORMAL TARGET TP EXIT
   //      Original money-based target from v2.00.
   //      Closes basket when P&L >= InpTargetMoney.
   //----------------------------------------------------------------
   if(totalEATrades > 0)
   {
      double netPnL = GetTotalEAPnL();

      // Update peak P&L tracker (only moves upward)
      if(netPnL > peakPnL)
         peakPnL = netPnL;

      // Live dashboard on chart
      Comment(StringFormat(
         "=== RSI Hedge EA v3.00 ===\n"
         "Sequence  : %s\n"
         "EA Trades : %d\n"
         "Net P&L   : %.2f\n"
         "Peak P&L  : %.2f\n"
         "Target TP : %.2f\n"
         "Trail Act : %.2f  Lock: %.2f\n"
         "Emrg SL   : %.2f\n"
         "Stage 2   : %s  |  Stage 3: %s\n"
         "RSI       : %.2f",
         (eaTradeSequence == 1 ? "BUY" : eaTradeSequence == 2 ? "SELL" : "FLAT"),
         totalEATrades,
         netPnL,
         peakPnL,
         InpTargetMoney,
         InpTrailActivateMoney, InpTrailLockInMoney,
         InpMaxLossMoney,
         (stage2Triggered ? "YES" : "NO"),
         (stage3Triggered ? "YES" : "NO"),
         rsi));

      //--------------------------------------------------------------
      //  4a. EMERGENCY MONEY STOP-LOSS
      //--------------------------------------------------------------
      if(netPnL <= InpMaxLossMoney)
      {
         PrintFormat("!!! EMERGENCY STOP | Net P&L: %.2f <= MaxLoss: %.2f — Closing ALL EA positions.",
                     netPnL, InpMaxLossMoney);
         CloseAllEAPositions();
         ResetSequenceState();
         prevRSI = rsi;
         return;
      }

      //--------------------------------------------------------------
      //  4b. TRAILING BASKET STOP
      //
      //  Only active once peakPnL has reached InpTrailActivateMoney.
      //  Trail floor = InpTrailLockInMoney (fixed minimum profit).
      //  Fires when current P&L pulls back below that floor.
      //--------------------------------------------------------------
      if(peakPnL >= InpTrailActivateMoney)
      {
         double trailFloor = InpTrailLockInMoney;

         if(netPnL <= trailFloor)
         {
            PrintFormat(">>> TRAILING STOP | Peak: %.2f | Current: %.2f | Floor: %.2f — Locking in profit.",
                        peakPnL, netPnL, trailFloor);
            CloseAllEAPositions();
            ResetSequenceState();
            prevRSI = rsi;
            return;
         }
         else
         {
            PrintFormat("[Trail Active] Peak: %.2f | P&L: %.2f | Floor: %.2f | Gap to floor: %.2f",
                        peakPnL, netPnL, trailFloor, netPnL - trailFloor);
         }
      }

      //--------------------------------------------------------------
      //  4c. NORMAL TARGET TP EXIT
      //--------------------------------------------------------------
      if(netPnL >= InpTargetMoney)
      {
         PrintFormat(">>> TARGET HIT | Net P&L: %.2f >= %.2f — Closing all EA positions.",
                     netPnL, InpTargetMoney);
         CloseAllEAPositions();
         ResetSequenceState();
         prevRSI = rsi;
         return;
      }

      // Log P&L status every tick
      PrintFormat("[P&L Monitor] Trades: %d | P&L: %.2f | Peak: %.2f | Target: %.2f | EmrgSL: %.2f",
                  totalEATrades, netPnL, peakPnL, InpTargetMoney, InpMaxLossMoney);
   }
   else
   {
      // No EA positions — clear dashboard
      Comment("=== RSI Hedge EA v3.00 ===\nSequence: FLAT\nWaiting for RSI signal...");
   }

   //----------------------------------------------------------------
   //  STEP 5: STAGE 1 — First Entry (only when flat)
   //
   //  BUY  sequence: RSI crosses UP through InpBuyLevel
   //  SELL sequence: RSI crosses UP through InpSellLevel
   //----------------------------------------------------------------
   bool crossUpBuy  = (prevRSI < InpBuyLevel)  && (rsi >= InpBuyLevel);
   bool crossUpSell = (prevRSI < InpSellLevel)  && (rsi >= InpSellLevel);

   if(totalEATrades == 0)
   {
      if(crossUpBuy)
      {
         PrintFormat(">>> STAGE 1 BUY | RSI %.2f crossed UP through %.2f", rsi, InpBuyLevel);
         OpenBuyPosition(InpBaseLot);
         eaTradeSequence = 1;
         stage2Triggered = false;
         stage3Triggered = false;
         firstBuyPrice   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         firstSellPrice  = 0.0;
         peakPnL         = 0.0; // Fresh peak tracker for new sequence
      }
      else if(crossUpSell)
      {
         PrintFormat(">>> STAGE 1 SELL | RSI %.2f crossed UP through %.2f", rsi, InpSellLevel);
         OpenSellPosition(InpBaseLot);
         eaTradeSequence = 2;
         stage2Triggered = false;
         stage3Triggered = false;
         firstSellPrice  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         firstBuyPrice   = 0.0;
         peakPnL         = 0.0; // Fresh peak tracker for new sequence
      }
   }

   //----------------------------------------------------------------
   //  STEP 6: STAGE 2 & 3 — Pyramid / Hedge Entries
   //
   //  Boolean flags prevent repeated firing on same RSI zone.
   //  Stage 3 is gated behind stage2Triggered (sequence ordering).
   //
   //  BUY SEQUENCE:
   //    Stage 2: RSI <= InpBuySecondRSI  → +0.03 Buy  +0.03 Sell
   //    Stage 3: RSI <= InpBuyThirdRSI   → +0.06 Buy  +0.03 Sell
   //
   //  SELL SEQUENCE:
   //    Stage 2: RSI >= InpSellSecondRSI → +0.03 Sell +0.03 Buy
   //    Stage 3: RSI >= InpSellThirdRSI  → +0.06 Sell +0.03 Buy
   //----------------------------------------------------------------
   if(eaTradeSequence == 1) // Active BUY sequence
   {
      if(!stage2Triggered && rsi <= InpBuySecondRSI)
      {
         PrintFormat(">>> STAGE 2 BUY | RSI %.2f <= %.2f | +%.2f Buy +%.2f Sell",
                     rsi, InpBuySecondRSI, InpBaseLot, InpBaseLot);
         OpenBuyPosition(InpBaseLot);
         OpenSellPosition(InpBaseLot);
         stage2Triggered = true;
      }

      if(stage2Triggered && !stage3Triggered && rsi <= InpBuyThirdRSI)
      {
         PrintFormat(">>> STAGE 3 BUY | RSI %.2f <= %.2f | +%.2f Buy +%.2f Sell",
                     rsi, InpBuyThirdRSI, InpBaseLot * 2.0, InpBaseLot);
         OpenBuyPosition(InpBaseLot * 2.0); // 0.06
         OpenSellPosition(InpBaseLot);      // 0.03
         stage3Triggered = true;
      }
   }
   else if(eaTradeSequence == 2) // Active SELL sequence
   {
      if(!stage2Triggered && rsi >= InpSellSecondRSI)
      {
         PrintFormat(">>> STAGE 2 SELL | RSI %.2f >= %.2f | +%.2f Sell +%.2f Buy",
                     rsi, InpSellSecondRSI, InpBaseLot, InpBaseLot);
         OpenSellPosition(InpBaseLot);
         OpenBuyPosition(InpBaseLot);
         stage2Triggered = true;
      }

      if(stage2Triggered && !stage3Triggered && rsi >= InpSellThirdRSI)
      {
         PrintFormat(">>> STAGE 3 SELL | RSI %.2f >= %.2f | +%.2f Sell +%.2f Buy",
                     rsi, InpSellThirdRSI, InpBaseLot * 2.0, InpBaseLot);
         OpenSellPosition(InpBaseLot * 2.0); // 0.06
         OpenBuyPosition(InpBaseLot);        // 0.03
         stage3Triggered = true;
      }
   }

   //----------------------------------------------------------------
   //  STEP 7: Store RSI for next-tick cross detection
   //----------------------------------------------------------------
   prevRSI = rsi;
}
//+------------------------------------------------------------------+
