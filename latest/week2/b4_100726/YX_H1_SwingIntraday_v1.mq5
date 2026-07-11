//+------------------------------------------------------------------+
//|                                      YX_H1_SwingIntraday_v1.mq5 |
//|        Converted from: YX_M5_scalper_v11_cleanTP.mq5             |
//|        Style: SWING INTRADAY (hold for hours, flat by day end)   |
//+------------------------------------------------------------------+
#property copyright "YX"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "H1 swing-intraday EA converted from the YX M5 scalper."
#property description "Signals on H1, confirms on M15, trend-filters on H4/D1."
#property description "Risk-% sizing, ATR stops, >=2R targets, partial TP,"
#property description "chandelier trail, session force-close, daily loss cap."

//+------------------------------------------------------------------+
//| CONVERSION NOTES (M5 scalper -> H1 swing intraday)                |
//|                                                                   |
//| TIMEFRAME REMAP                                                   |
//|   Signal candle:        M5  -> H1                                 |
//|   Entry confirmation:   M1  -> M15                                |
//|   Trend filter stack:   M5/M15/H1 -> H1/H4/D1                     |
//|                                                                   |
//| RISK MODEL — REBUILT ("optimal minimal loss")                     |
//|   OLD: fixed 0.27 lots for every trade, fixed 1503-pt SL, TP at   |
//|        only 0.5x the SL distance (risking ~2x the reward), no     |
//|        link between lot size and account balance.                 |
//|   NEW: lot size is computed from RiskPercent of equity and the    |
//|        actual ATR-based SL distance, so every trade risks the     |
//|        same known fraction of the account. TP is a true multiple  |
//|        of risk (default 2R) so the win/loss geometry is positive. |
//|                                                                   |
//| EXIT MODEL — REBUILT ("optimal maximum profit")                   |
//|   OLD: close (nearly) everything at the end of each M5 candle;    |
//|        tight $12 secondary targets; 15-pt breakeven.              |
//|   NEW: trades are held through the session. Profit is banked in   |
//|        stages: partial close at +1R with SL to breakeven, then a  |
//|        chandelier (ATR) trailing stop lets the remainder run.     |
//|        All positions are force-closed before the session ends     |
//|        (intraday constraint) and before the weekend.              |
//|                                                                   |
//| REMOVED SUBSYSTEMS (deliberate)                                   |
//|   - Sequential lot ladder                                         |
//|   - Loss-recovery AVERAGE (martingale add) and HEDGE freeze       |
//|   - Legacy fixed-dollar secondary TP                              |
//|   These are loss-averaging / grid-family mechanics. They reduce   |
//|   the number of losing trades but concentrate risk into rare,     |
//|   very large drawdowns — the opposite of "optimal minimal loss".  |
//|   The ONE recovery idea kept is the safe branch: if the higher-   |
//|   timeframe trend flips fully against an open trade, cut it       |
//|   early instead of waiting for the full stop (UseTrendFlipExit).  |
//|                                                                   |
//| ADDED SAFETY                                                      |
//|   - Session window (no new entries near day end)                  |
//|   - Force-close hour + Friday close                               |
//|   - Daily loss limit as % of balance (ON by default)              |
//|   - Max trades per day, max spread filter                         |
//|                                                                   |
//| NOTE: No EA can guarantee "maximum profit / minimum loss".        |
//| Backtest on your symbol/broker (every-tick, real spreads) and     |
//| forward-test on demo before any live use.                         |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>

CTrade trade;

//=== IDENTIFICATION ===
input long   MagicNumber            = 20260708;   // Magic number (new — do not reuse the scalper's)

//=== RISK & POSITION SIZING ===
// Lot size is DERIVED: it risks RiskPercent of current equity over the
// ATR-based SL distance. This replaces the scalper's fixed 0.27 lots.
input double RiskPercent            = 1.0;        // % of equity risked per trade
input double MaxLot                 = 2.0;        // Hard ceiling on computed lot
input double MinLot                 = 0.01;       // Hard floor on computed lot
input double MaxSpreadPoints        = 40;         // Skip entries when spread exceeds this (0 = off)

//=== STOP LOSS / TAKE PROFIT (ATR-BASED, H1) ===
// SL = ATR(H1) * ATR_SL_Mult  -> adapts to current volatility instead of
// the scalper's fixed 1503 points.
// TP = SL distance * TP_RiskReward_Ratio  -> keep this >= 2.0 so winners
// pay for more than one loser (the scalper used 0.5, i.e. inverted R:R).
input double ATR_SL_Mult            = 2.0;        // SL = ATR(H1,14) x this
input double SL_Min_Points          = 150;        // Volatility floor for SL (protects vs dead markets)
input double SL_Max_Points          = 3000;       // Volatility ceiling for SL (protects vs news spikes)
input double TP_RiskReward_Ratio    = 2.0;        // TP = SL distance x this (>= 2 recommended)

//=== PARTIAL PROFIT + BREAKEVEN (stage 1 of the exit) ===
// At +1R the EA banks part of the position and moves SL to breakeven.
// From that point the trade can no longer lose — the remainder is a
// "free" runner managed by the chandelier trail below.
input bool   UsePartialTP           = true;       // Take partial profit at +1R
input double Partial_ClosePercent   = 50.0;       // % of volume closed at +1R
input bool   UseBreakEven           = true;       // Move SL to entry (+lock) at +1R
input double BreakEven_LockPoints   = 20;         // Locked buffer beyond entry (covers costs)

//=== CHANDELIER / ATR TRAILING (stage 2 of the exit) ===
// After the partial, the SL trails behind the highest high (BUY) /
// lowest low (SELL) since entry at Chandelier_ATR_Mult x ATR(H1).
// Wide enough to survive normal H1 pullbacks, unlike the scalper's
// 0.8x ATR M5 trail which choked winners within minutes.
input bool   UseTrailingStop        = true;       // Enable the chandelier trail
input double Chandelier_ATR_Mult    = 2.5;        // Trail distance = ATR(H1) x this
input double Trail_ActivateR        = 1.0;        // Start trailing once profit >= this many R
input int    Trail_StepPoints       = 30;         // Min SL improvement before modifying (throttles requests)

//=== TREND-FLIP EARLY EXIT (the only "recovery" behavior kept) ===
// If ALL higher-timeframe trend gauges flip against an open trade,
// cut it immediately instead of riding it to the full ATR stop.
// This is the RECOVERY_CLOSE branch of the old EA, minus the
// martingale/hedge branches.
input bool   UseTrendFlipExit       = true;       // Cut early when trend fully reverses
input int    TrendFlip_MaxScore     = 0;          // Exit when alignment score falls to <= this (0 = full flip)

//=== ENTRY SIGNAL — H1 MOMENTUM (was M5) ===
input int    MomentumCandles        = 3;          // Closed H1 candles inspected for momentum
input double MinAvgBody_Points      = 80.0;       // Min average H1 body (was 10 pts on M5)
input double MinATR_Points          = 100.0;      // Min ATR(H1) to trade at all (was 15 on M5)
input double RSI_BuyAbove           = 52.0;       // H1 RSI must exceed this for BUY bias
input double RSI_SellBelow          = 48.0;       // H1 RSI must be under this for SELL bias

//=== MULTI-TIMEFRAME TREND FILTER — H1 / H4 / D1 (was M5/M15/H1) ===
input bool   UseMTF_Scoring         = true;       // Score-based agreement (vs strict all-agree)
input int    MTF_MinScore           = 2;          // Timeframes (of 3) that must agree to enter
input int    EMA_Fast_Period        = 20;         // Fast EMA (H1 & H4) — swing-appropriate (was 9)
input int    EMA_Slow_Period        = 50;         // Slow EMA (H1 & H4) — swing-appropriate (was 21)

//=== M15 CONFIRMATION (was M1) ===
// After the H1 direction is decided, wait for a closed M15 candle that
// agrees: right color, sufficient body, and price beyond the H1 open.
input int    ConfirmWaitBars        = 1;          // Closed M15 bars to wait before confirming
input int    ConfirmMaxBars         = 3;          // Give up after this many M15 bars (late = chasing)
input double MinM15ConfirmBody      = 40.0;       // Min confirmation body in points (was 8 on M1)
input bool   RequireM15BreakLevel   = true;       // Price must be beyond the H1 open in trade direction

//=== M15 RSI FILTER (was M1 RSI) ===
input bool   UseM15_RSI_Filter      = true;       // Skip entries into short-term exhaustion
input double M15_RSI_Overbought     = 70.0;       // No BUY confirmation above this
input double M15_RSI_Oversold      = 30.0;        // No SELL confirmation below this

//=== MEAN REVERSION ENTRY (adapted from M1/M5 to M15/H1) ===
// Fades dual-timeframe RSI exhaustion when a reversal candle appears.
// Kept, but OFF by default: counter-trend swings held for hours carry
// more risk than counter-trend scalps held for minutes.
input bool   UseMeanReversion       = false;      // Enable exhaustion-fade entries
input double MeanRev_RSI_Overbought = 75.0;       // Both M15 & H1 RSI above -> SELL fade allowed
input double MeanRev_RSI_Oversold   = 25.0;       // Both M15 & H1 RSI below -> BUY fade allowed
input double MeanRev_MinM15Body     = 30.0;       // Min reversal-candle body (points)

//=== OVEREXTENSION FILTER (from the old ladder gates — kept, it's sound) ===
// Never chase: skip entries when price is already far from the H1 fast
// EMA. Entering an overextended move is the main cause of instant
// drawdown on swing entries.
input bool   UseExtensionFilter     = true;       // Skip entries far from fast EMA
input double MaxEMA_DistanceATR     = 1.5;        // Max distance from H1 fast EMA, in ATRs

//=== SESSION / INTRADAY MANAGEMENT (replaces candle-end close) ===
// Times are SERVER time (check your broker's server clock!).
input int    Session_StartHour      = 7;          // First hour new entries are allowed
input int    Session_LastEntryHour  = 17;         // No NEW entries at/after this hour
input int    Session_ForceCloseHour = 21;         // Flatten everything at this hour (intraday rule)
input bool   CloseBeforeWeekend     = true;       // Flatten before Friday close
input int    Friday_ForceCloseHour  = 20;         // Friday flatten hour (earlier than weekdays)

//=== DAILY CIRCUIT BREAKERS (ON by default — was off in the scalper) ===
input bool   UseDailyLimits         = true;       // Master switch
input double DailyLossLimit_Pct     = 3.0;        // Stop trading after losing this % of day-start balance
input double DailyProfitTarget_Pct  = 0.0;        // Stop after gaining this % (0 = no profit cap)
input int    MaxTradesPerDay        = 4;          // Max entries per day (0 = unlimited)

//=== GLOBAL STATE ===
datetime LastH1CandleTime  = 0;        // Detects new H1 signal candles (was M5)
bool     DirectionDecided  = false;    // Direction picked for the current H1 candle
string   CandleDirection   = "NONE";   // "BUY" / "SELL" / "SKIP"
int      M15BarsElapsed    = 0;        // Closed M15 bars since the H1 candle opened (was M1)
datetime LastM15Time       = 0;        // Detects new M15 bars

int      TodayTrades       = 0;        // Entries taken today
int      TodayWins         = 0;
int      TodayLosses       = 0;
int      LastTradeDay      = -1;       // Day-of-month of the last daily reset
double   DailyStartBalance = 0;        // Balance at the day's first tick
bool     DailyLimitHit     = false;    // Latched once a daily limit trips

// Per-position management state. The EA holds at most ONE position at a
// time, so a single set of variables is enough. Reset on every entry.
ulong    ActiveTicket      = 0;        // Ticket of the position being managed
double   ActiveRiskDist    = 0;        // Entry SL distance in PRICE units (defines 1R)
double   ActiveHighWater   = 0;        // Highest bid since entry (BUY) — chandelier anchor
double   ActiveLowWater    = 0;        // Lowest ask since entry (SELL) — chandelier anchor
bool     PartialDone       = false;    // Partial TP already taken for this position
bool     BreakEvenDone     = false;    // SL already moved to breakeven

//=== INDICATOR HANDLES ===
int hEMA_Fast_H1, hEMA_Slow_H1;        // H1 trend pair (was M5)
int hEMA_Fast_H4, hEMA_Slow_H4;        // H4 trend pair (was M15)
int hMA20_D1, hMA50_D1;                // D1 trend pair (was H1 SMA 20/50)
int hRSI_H1;                           // Signal RSI (was M5 RSI)
int hRSI_M15;                          // Confirmation RSI (was M1 RSI)
int hATR_H1;                           // Volatility engine for SL/TP/trail (was M5 ATR)

//+------------------------------------------------------------------+
//| Initialization                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   // --- Create all indicator handles on the swing timeframes ---
   hEMA_Fast_H1 = iMA(_Symbol, PERIOD_H1, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_H1 = iMA(_Symbol, PERIOD_H1, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Fast_H4 = iMA(_Symbol, PERIOD_H4, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_H4 = iMA(_Symbol, PERIOD_H4, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hMA20_D1     = iMA(_Symbol, PERIOD_D1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_D1     = iMA(_Symbol, PERIOD_D1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1      = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   hRSI_M15     = iRSI(_Symbol, PERIOD_M15, 14, PRICE_CLOSE);
   hATR_H1      = iATR(_Symbol, PERIOD_H1, 14);

   if(hEMA_Fast_H1 == INVALID_HANDLE || hEMA_Slow_H1 == INVALID_HANDLE ||
      hEMA_Fast_H4 == INVALID_HANDLE || hEMA_Slow_H4 == INVALID_HANDLE ||
      hMA20_D1 == INVALID_HANDLE     || hMA50_D1 == INVALID_HANDLE     ||
      hRSI_H1 == INVALID_HANDLE      || hRSI_M15 == INVALID_HANDLE     ||
      hATR_H1 == INVALID_HANDLE)
   {
      Print("[INIT] Indicator handle creation failed");
      return(INIT_FAILED);
   }

   // --- Sanity checks on the risk inputs ---
   if(TP_RiskReward_Ratio < 1.0)
      Print("[INIT][WARN] TP_RiskReward_Ratio < 1.0 — winners smaller than losers. ",
            "This is the geometry the scalper suffered from; >= 2.0 recommended.");
   if(RiskPercent > 2.0)
      Print("[INIT][WARN] RiskPercent > 2% per trade is aggressive for swing holds.");

   Print("[INIT] YX H1 Swing-Intraday v1 (converted from M5 scalper v11)");
   Print("[INIT] Risk=", DoubleToString(RiskPercent, 2), "% per trade | SL=ATR(H1)x",
         DoubleToString(ATR_SL_Mult, 2), " | TP=", DoubleToString(TP_RiskReward_Ratio, 1), "R");
   Print("[INIT] Partial ", DoubleToString(Partial_ClosePercent, 0), "% at +1R -> BE | Chandelier trail ATRx",
         DoubleToString(Chandelier_ATR_Mult, 2));
   Print("[INIT] Session: entries ", Session_StartHour, ":00-", Session_LastEntryHour,
         ":00 | force close ", Session_ForceCloseHour, ":00 (Fri ", Friday_ForceCloseHour, ":00)");
   Print("[INIT] Daily limits: loss ", DoubleToString(DailyLossLimit_Pct, 1), "% | max ",
         MaxTradesPerDay, " trades/day | enabled=", (UseDailyLimits ? "true" : "false"));

   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA_Fast_H1 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_H1);
   if(hEMA_Slow_H1 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_H1);
   if(hEMA_Fast_H4 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_H4);
   if(hEMA_Slow_H4 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_H4);
   if(hMA20_D1 != INVALID_HANDLE)     IndicatorRelease(hMA20_D1);
   if(hMA50_D1 != INVALID_HANDLE)     IndicatorRelease(hMA50_D1);
   if(hRSI_H1 != INVALID_HANDLE)      IndicatorRelease(hRSI_H1);
   if(hRSI_M15 != INVALID_HANDLE)     IndicatorRelease(hRSI_M15);
   if(hATR_H1 != INVALID_HANDLE)      IndicatorRelease(hATR_H1);
   Print("[STATS] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                 |
//| Order of operations each tick:                                    |
//|   1. Daily rollover / stats reset                                 |
//|   2. Session force-close (intraday rule)                          |
//|   3. Manage the open position (partial, BE, trail, trend-flip)    |
//|   4. Daily circuit breakers                                       |
//|   5. New H1 candle -> decide direction                            |
//|   6. M15 confirmation -> enter                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // ---- 1. Daily rollover -------------------------------------------------
   MqlDateTime dt;
   TimeCurrent(dt);                    // SERVER time (sessions are server-based)
   if(dt.day != LastTradeDay)
   {
      if(LastTradeDay != -1)
         Print("[DAILY] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses,
               " WR=", (TodayTrades > 0 ? DoubleToString((double)TodayWins / TodayTrades * 100, 1) : "0"), "%");
      TodayTrades = 0; TodayWins = 0; TodayLosses = 0;
      LastTradeDay = dt.day;
      DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      DailyLimitHit = false;
   }

   // ---- 2. Session force-close (replaces the scalper's candle-end close) --
   int forceHour = (CloseBeforeWeekend && dt.day_of_week == 5) ? Friday_ForceCloseHour
                                                               : Session_ForceCloseHour;
   if(dt.hour >= forceHour && HasPosition())
   {
      Print("[SESSION] Force-close hour reached (", dt.hour, ":00). Flattening.");
      CloseAllPositions();
      return;
   }

   // ---- 3. Manage the open position ---------------------------------------
   if(HasPosition())
   {
      ManageOpenPosition();
      return;   // one position at a time — no new-entry logic while in a trade
   }

   // Position gone (SL/TP/manual) — clear the management state.
   if(ActiveTicket != 0 && !PositionSelectByTicket(ActiveTicket))
      ResetPositionState();

   // ---- 4. Daily circuit breakers -----------------------------------------
   if(UseDailyLimits && CheckDailyLimits())
      return;

   // ---- 5. New H1 candle -> decide direction ------------------------------
   datetime currentH1 = iTime(_Symbol, PERIOD_H1, 0);
   if(currentH1 != LastH1CandleTime)
   {
      LastH1CandleTime = currentH1;
      DirectionDecided = false;
      CandleDirection  = "NONE";
      M15BarsElapsed   = 0;
      LastM15Time      = 0;

      // Only look for a direction inside the entry window.
      if(dt.hour >= Session_StartHour && dt.hour < Session_LastEntryHour)
      {
         CandleDirection  = DecideDirection();
         DirectionDecided = true;
         if(CandleDirection != "SKIP")
            Print("[DIRECTION] ", CandleDirection, " decided on H1. Waiting for M15 confirmation...");
      }
      else
      {
         CandleDirection  = "SKIP";
         DirectionDecided = true;
      }
   }

   // ---- 6. M15 confirmation -> enter ---------------------------------------
   if(DirectionDecided && CandleDirection != "SKIP" && !HasPosition())
   {
      // Re-check the entry window every tick — the hour can roll past
      // Session_LastEntryHour while we're still waiting for confirmation.
      if(dt.hour < Session_StartHour || dt.hour >= Session_LastEntryHour)
      {
         CandleDirection = "SKIP";
         return;
      }
      if(MaxTradesPerDay > 0 && TodayTrades >= MaxTradesPerDay)
      {
         CandleDirection = "SKIP";
         Print("[LIMIT] Max trades per day (", MaxTradesPerDay, ") reached.");
         return;
      }
      CheckM15Confirmation();
   }
}

//+------------------------------------------------------------------+
//| Direction decision on a fresh H1 candle (was DecideDirection M5) |
//| Requires, in order:                                               |
//|   a) enough volatility (ATR floor)                                |
//|   b) H1 momentum: majority of last N closed candles one color,    |
//|      with sufficient average body                                 |
//|   c) H1 RSI bias agreeing                                         |
//|   d) MTF trend score (H1 EMA, H4 EMA, D1 SMA) >= MTF_MinScore     |
//|   e) price not overextended from the H1 fast EMA (no chasing)     |
//+------------------------------------------------------------------+
string DecideDirection()
{
   // --- a) Volatility floor ---
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_H1, 0, 0, 1, atr) <= 0) return "SKIP";
   if(atr[0] / _Point < MinATR_Points)
      return "SKIP";

   // --- b) H1 momentum over the last MomentumCandles CLOSED candles ---
   MqlRates h1[];
   ArraySetAsSeries(h1, true);
   if(CopyRates(_Symbol, PERIOD_H1, 1, MomentumCandles, h1) < MomentumCandles)
      return "SKIP";

   int bullish = 0, bearish = 0;
   double totalBody = 0;
   for(int i = 0; i < MomentumCandles; i++)
   {
      double body = (h1[i].close - h1[i].open) / _Point;
      totalBody += MathAbs(body);
      if(h1[i].close > h1[i].open)      bullish++;
      else if(h1[i].close < h1[i].open) bearish++;
   }
   if(totalBody / MomentumCandles < MinAvgBody_Points)
      return "SKIP";                      // market too quiet for a swing move

   // --- c) H1 RSI bias ---
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRSI_H1, 0, 0, 1, rsi) <= 0) return "SKIP";

   // --- d) Multi-timeframe trend score ---
   string direction = "SKIP";
   if(UseMTF_Scoring)
   {
      int buyScore  = GetTrendAlignmentScore("BUY");
      int sellScore = GetTrendAlignmentScore("SELL");

      if(bullish >= 2 && rsi[0] > RSI_BuyAbove && buyScore >= MTF_MinScore)
         direction = "BUY";
      else if(bearish >= 2 && rsi[0] < RSI_SellBelow && sellScore >= MTF_MinScore)
         direction = "SELL";
   }
   else
   {
      // Strict mode: all three timeframes must agree.
      if(bullish >= 2 && rsi[0] > RSI_BuyAbove && GetTrendAlignmentScore("BUY") == 3)
         direction = "BUY";
      else if(bearish >= 2 && rsi[0] < RSI_SellBelow && GetTrendAlignmentScore("SELL") == 3)
         direction = "SELL";
   }
   if(direction == "SKIP") return direction;

   // --- e) Overextension filter (adapted from the old ladder gate) ---
   if(UseExtensionFilter && !ExtensionOK())
   {
      Print("[SKIP] Price too far from H1 fast EMA — not chasing an extended move.");
      return "SKIP";
   }

   return direction;
}

//+------------------------------------------------------------------+
//| MTF trend alignment score, 0..3 (H1 EMA / H4 EMA / D1 SMA).       |
//| Same idea as the scalper's GetTrendAlignmentScore, one TF stack   |
//| higher. Also reused by the trend-flip early exit.                 |
//+------------------------------------------------------------------+
int GetTrendAlignmentScore(string direction)
{
   double f1[], s1[], f4[], s4[], d20[], d50[];
   ArraySetAsSeries(f1, true);  ArraySetAsSeries(s1, true);
   ArraySetAsSeries(f4, true);  ArraySetAsSeries(s4, true);
   ArraySetAsSeries(d20, true); ArraySetAsSeries(d50, true);

   if(CopyBuffer(hEMA_Fast_H1, 0, 0, 1, f1)  <= 0) return 0;
   if(CopyBuffer(hEMA_Slow_H1, 0, 0, 1, s1)  <= 0) return 0;
   if(CopyBuffer(hEMA_Fast_H4, 0, 0, 1, f4)  <= 0) return 0;
   if(CopyBuffer(hEMA_Slow_H4, 0, 0, 1, s4)  <= 0) return 0;
   if(CopyBuffer(hMA20_D1, 0, 0, 1, d20)     <= 0) return 0;
   if(CopyBuffer(hMA50_D1, 0, 0, 1, d50)     <= 0) return 0;

   bool h1_bull = f1[0]  > s1[0];
   bool h4_bull = f4[0]  > s4[0];
   bool d1_bull = d20[0] > d50[0];

   int score = 0;
   if(direction == "BUY")
   {
      if(h1_bull) score++;
      if(h4_bull) score++;
      if(d1_bull) score++;
   }
   else // SELL
   {
      if(!h1_bull) score++;
      if(!h4_bull) score++;
      if(!d1_bull) score++;
   }
   return score;
}

//+------------------------------------------------------------------+
//| Overextension check: price within MaxEMA_DistanceATR ATRs of the  |
//| H1 fast EMA. Fails OPEN (returns true) on a data hiccup.          |
//+------------------------------------------------------------------+
bool ExtensionOK()
{
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(hEMA_Fast_H1, 0, 0, 1, ema) <= 0) return true;

   double atr = GetATR();
   if(atr <= 0) return true;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (MathAbs(price - ema[0]) <= atr * MaxEMA_DistanceATR);
}

//+------------------------------------------------------------------+
//| M15 confirmation (was CheckM1Confirmation on M1).                 |
//| Waits ConfirmWaitBars closed M15 bars, gives up after             |
//| ConfirmMaxBars. Mean-reversion branch (if enabled) is checked     |
//| first, then the standard momentum confirmation.                   |
//+------------------------------------------------------------------+
void CheckM15Confirmation()
{
   // Count closed M15 bars since the H1 candle opened.
   datetime currentM15 = iTime(_Symbol, PERIOD_M15, 0);
   if(currentM15 != LastM15Time)
   {
      LastM15Time = currentM15;
      M15BarsElapsed++;
   }

   if(M15BarsElapsed < ConfirmWaitBars)
      return;

   if(M15BarsElapsed > ConfirmMaxBars)
   {
      CandleDirection = "SKIP";
      Print("[SKIP] Too late in the H1 candle. M15 bars elapsed: ", M15BarsElapsed);
      return;
   }

   // Spread filter — a wide spread on entry is an immediate hidden loss.
   if(MaxSpreadPoints > 0)
   {
      double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                          SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
      if(spreadPts > MaxSpreadPoints)
         return;   // silently wait for the spread to normalize
   }

   // Latest CLOSED M15 candle.
   MqlRates m15[];
   ArraySetAsSeries(m15, true);
   if(CopyRates(_Symbol, PERIOD_M15, 1, 1, m15) <= 0)
      return;

   double body      = (m15[0].close - m15[0].open) / _Point;
   double absBody   = MathAbs(body);
   bool   isBullish = (m15[0].close > m15[0].open);
   bool   isBearish = (m15[0].close < m15[0].open);

   // ---- Mean-reversion branch (OFF by default for swing holds) ----
   if(UseMeanReversion)
   {
      double rsi15[], rsi1h[];
      ArraySetAsSeries(rsi15, true);
      ArraySetAsSeries(rsi1h, true);
      if(CopyBuffer(hRSI_M15, 0, 1, 1, rsi15) > 0 && CopyBuffer(hRSI_H1, 0, 0, 1, rsi1h) > 0)
      {
         // SELL fade: both timeframes overbought + bearish reversal candle.
         if(rsi15[0] >= MeanRev_RSI_Overbought && rsi1h[0] >= MeanRev_RSI_Overbought &&
            isBearish && absBody >= MeanRev_MinM15Body)
         {
            Print("[MEAN REVERSAL] SELL | M15 RSI=", DoubleToString(rsi15[0], 1),
                  " | H1 RSI=", DoubleToString(rsi1h[0], 1));
            ExecuteEntry("SELL");
            return;
         }
         // BUY fade: both timeframes oversold + bullish reversal candle.
         if(rsi15[0] <= MeanRev_RSI_Oversold && rsi1h[0] <= MeanRev_RSI_Oversold &&
            isBullish && absBody >= MeanRev_MinM15Body)
         {
            Print("[MEAN REVERSAL] BUY | M15 RSI=", DoubleToString(rsi15[0], 1),
                  " | H1 RSI=", DoubleToString(rsi1h[0], 1));
            ExecuteEntry("BUY");
            return;
         }
      }
   }

   // ---- Standard momentum confirmation ----
   // M15 RSI exhaustion filter: don't buy into a short-term top or sell
   // into a short-term bottom.
   if(UseM15_RSI_Filter)
   {
      double rsi15[];
      ArraySetAsSeries(rsi15, true);
      if(CopyBuffer(hRSI_M15, 0, 1, 1, rsi15) > 0)
      {
         if(CandleDirection == "BUY" && rsi15[0] >= M15_RSI_Overbought)
         {
            Print("[FILTER] M15 RSI overbought (", DoubleToString(rsi15[0], 1), "). Skipping BUY.");
            return;
         }
         if(CandleDirection == "SELL" && rsi15[0] <= M15_RSI_Oversold)
         {
            Print("[FILTER] M15 RSI oversold (", DoubleToString(rsi15[0], 1), "). Skipping SELL.");
            return;
         }
      }
   }

   if(absBody < MinM15ConfirmBody)
      return;                              // confirmation candle too weak

   double h1Open = iOpen(_Symbol, PERIOD_H1, 0);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(CandleDirection == "BUY")
   {
      if(!isBullish) return;
      if(RequireM15BreakLevel && bid <= h1Open) return;   // still below the H1 open — no follow-through
      Print("[CONFIRMED] BUY after ", M15BarsElapsed, " M15 bars");
      ExecuteEntry("BUY");
   }
   else if(CandleDirection == "SELL")
   {
      if(!isBearish) return;
      if(RequireM15BreakLevel && ask >= h1Open) return;   // still above the H1 open — no follow-through
      Print("[CONFIRMED] SELL after ", M15BarsElapsed, " M15 bars");
      ExecuteEntry("SELL");
   }
}

//+------------------------------------------------------------------+
//| SL/TP distances in PRICE units (was GetSLTP with fixed points).   |
//| SL = ATR(H1) x ATR_SL_Mult, clamped to [SL_Min, SL_Max] points.   |
//| TP = SL x TP_RiskReward_Ratio — a true risk multiple.             |
//+------------------------------------------------------------------+
void GetSLTP(double &sl_dist, double &tp_dist)
{
   double atrPts = GetATR() / _Point;
   double slPts  = atrPts * ATR_SL_Mult;

   if(slPts < SL_Min_Points) slPts = SL_Min_Points;
   if(slPts > SL_Max_Points) slPts = SL_Max_Points;

   sl_dist = slPts * _Point;
   tp_dist = sl_dist * TP_RiskReward_Ratio;

   Print("[SLTP] ATR=", DoubleToString(atrPts, 0), "pts | SL=", DoubleToString(slPts, 0),
         "pts | TP=", DoubleToString(slPts * TP_RiskReward_Ratio, 0), "pts (",
         DoubleToString(TP_RiskReward_Ratio, 1), "R)");
}

//+------------------------------------------------------------------+
//| Current ATR(H1) in price units, with a conservative fallback.     |
//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_H1, 0, 0, 1, atr) <= 0)
      return SL_Min_Points * _Point;      // fail safe, not fail wide
   return atr[0];
}

//+------------------------------------------------------------------+
//| RISK-BASED LOT SIZING (replaces the scalper's fixed 0.27 lots).   |
//| lot = (equity x RiskPercent%) / (SL distance in ticks x tick $).  |
//| The result is normalized to the broker's volume step and clamped  |
//| to both the EA's and the broker's min/max volume.                 |
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney  = equity * RiskPercent / 100.0;

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || sl_dist <= 0)
      return MinLot;                      // degenerate symbol data — trade minimum

   // Money lost per 1.0 lot if the SL is hit.
   double lossPerLot = (sl_dist / tickSize) * tickValue;
   if(lossPerLot <= 0) return MinLot;

   double lot = riskMoney / lossPerLot;

   // Normalize to the broker's volume step.
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;

   // Clamp: EA limits AND broker limits.
   double brokerMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brokerMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < MinLot)    lot = MinLot;
   if(lot < brokerMin) lot = brokerMin;
   if(lot > MaxLot)    lot = MaxLot;
   if(lot > brokerMax) lot = brokerMax;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Unified entry (replaces ExecuteBuy/ExecuteSell).                  |
//| Opens the position with a hard broker-side SL and TP, then seeds  |
//| the per-position management state (1R distance, water marks).     |
//+------------------------------------------------------------------+
void ExecuteEntry(string direction)
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = CalcLot(sl_dist);

   bool ok;
   double entry, sl, tp;

   if(direction == "BUY")
   {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl    = NormalizeDouble(entry - sl_dist, _Digits);
      tp    = NormalizeDouble(entry + tp_dist, _Digits);
      ok    = trade.Buy(lot, _Symbol, entry, sl, tp, "SWING BUY");
   }
   else
   {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl    = NormalizeDouble(entry + sl_dist, _Digits);
      tp    = NormalizeDouble(entry - tp_dist, _Digits);
      ok    = trade.Sell(lot, _Symbol, entry, sl, tp, "SWING SELL");
   }

   if(!ok)
   {
      Print("[ERROR] ", direction, " failed: ", trade.ResultRetcode(), " ",
            trade.ResultRetcodeDescription());
      return;
   }

   TodayTrades++;

   // Seed the management state for this position.
   ActiveTicket    = FindLatestPositionTicket();
   ActiveRiskDist  = sl_dist;             // 1R in price units
   ActiveHighWater = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ActiveLowWater  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   PartialDone     = false;
   BreakEvenDone   = false;

   Print("[ENTRY] ", direction, " ", DoubleToString(lot, 2), " lots | SL:",
         DoubleToString(sl, _Digits), " TP:", DoubleToString(tp, _Digits),
         " | risk=", DoubleToString(RiskPercent, 2), "% (1R=",
         DoubleToString(sl_dist / _Point, 0), "pts)");
}

//+------------------------------------------------------------------+
//| Most recently opened position for this symbol/magic — used right  |
//| after an entry to capture the position ticket.                    |
//+------------------------------------------------------------------+
ulong FindLatestPositionTicket()
{
   ulong best = 0;
   long  bestTime = -1;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      long t = (long)PositionGetInteger(POSITION_TIME);
      if(t > bestTime)
      {
         bestTime = t;
         best = (ulong)PositionGetInteger(POSITION_TICKET);
      }
   }
   return best;
}

//+------------------------------------------------------------------+
//| Clears the per-position management state.                         |
//+------------------------------------------------------------------+
void ResetPositionState()
{
   ActiveTicket    = 0;
   ActiveRiskDist  = 0;
   ActiveHighWater = 0;
   ActiveLowWater  = 0;
   PartialDone     = false;
   BreakEvenDone   = false;
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT — the heart of "max profit / min loss".       |
//| Runs every tick while a position is open. Stages, in order:       |
//|                                                                   |
//|  0. Trend-flip early exit: if the H1/H4/D1 stack fully reverses   |
//|     against the trade, cut it now — don't wait for the ATR stop.  |
//|  1. At +1R: close Partial_ClosePercent of the volume and move SL  |
//|     to breakeven (+lock). The trade can no longer lose.           |
//|  2. From Trail_ActivateR onward: chandelier trail — SL follows    |
//|     the best price seen since entry minus ATR x Chandelier_Mult,  |
//|     ratcheting only in the trade's favor.                         |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(ActiveTicket == 0 || !PositionSelectByTicket(ActiveTicket))
   {
      // The EA restarted, or the ticket changed after a partial close on
      // a netting account. Re-acquire the position if one exists.
      ulong t = FindLatestPositionTicket();
      if(t == 0) { ResetPositionState(); return; }
      ActiveTicket = t;
      if(!PositionSelectByTicket(ActiveTicket)) { ResetPositionState(); return; }
      if(ActiveRiskDist <= 0)
      {
         // Rebuild 1R from the position's own SL if state was lost.
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         double slp = PositionGetDouble(POSITION_SL);
         ActiveRiskDist = (slp > 0) ? MathAbs(op - slp) : GetATR() * ATR_SL_Mult;
         ActiveHighWater = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         ActiveLowWater  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
   }

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);
   double volume    = PositionGetDouble(POSITION_VOLUME);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Update water marks (chandelier anchors).
   if(bid > ActiveHighWater) ActiveHighWater = bid;
   if(ask < ActiveLowWater)  ActiveLowWater  = ask;

   // Profit in R (multiples of the initial risk distance).
   double profitDist = (type == POSITION_TYPE_BUY) ? (bid - openPrice) : (openPrice - ask);
   double profitR    = (ActiveRiskDist > 0) ? profitDist / ActiveRiskDist : 0;

   // ---- Stage 0: trend-flip early exit ("optimal minimal loss") ----
   // Only while the trade is still at risk (before breakeven is locked).
   if(UseTrendFlipExit && !BreakEvenDone)
   {
      string dir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(GetTrendAlignmentScore(dir) <= TrendFlip_MaxScore)
      {
         double pl = PositionGetDouble(POSITION_PROFIT);
         Print("[TREND FLIP] H1/H4/D1 fully reversed against the trade. Cutting at $",
               DoubleToString(pl, 2), " instead of riding to the full stop.");
         trade.PositionClose(ActiveTicket);
         if(pl > 0) TodayWins++; else TodayLosses++;
         ResetPositionState();
         return;
      }
   }

   // ---- Stage 1: partial profit + breakeven at +1R ----
   if(profitR >= 1.0)
   {
      // 1a. Partial close.
      if(UsePartialTP && !PartialDone)
      {
         double closeVol = volume * Partial_ClosePercent / 100.0;
         double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(step > 0) closeVol = MathFloor(closeVol / step) * step;

         // Only partial if both the closed part and the remainder stay
         // at/above the broker minimum — otherwise skip and let the
         // trail manage the full position.
         if(closeVol >= vmin && (volume - closeVol) >= vmin)
         {
            if(trade.PositionClosePartial(ActiveTicket, closeVol))
            {
               Print("[PARTIAL] +1R reached. Closed ", DoubleToString(closeVol, 2),
                     " of ", DoubleToString(volume, 2), " lots. Remainder runs on the trail.");
               TodayWins++;
               // On a netting account a partial close can issue a new ticket —
               // re-acquire before any further modify calls.
               ActiveTicket = FindLatestPositionTicket();
               if(ActiveTicket == 0 || !PositionSelectByTicket(ActiveTicket))
               { ResetPositionState(); return; }
               curSL = PositionGetDouble(POSITION_SL);
               curTP = PositionGetDouble(POSITION_TP);
            }
         }
         PartialDone = true;   // one attempt per position, success or skip
      }

      // 1b. Breakeven lock.
      if(UseBreakEven && !BreakEvenDone)
      {
         double lock = BreakEven_LockPoints * _Point;
         double beSL = (type == POSITION_TYPE_BUY)
                       ? NormalizeDouble(openPrice + lock, _Digits)
                       : NormalizeDouble(openPrice - lock, _Digits);
         bool improves = (type == POSITION_TYPE_BUY) ? (beSL > curSL) : (curSL == 0 || beSL < curSL);
         if(improves && trade.PositionModify(ActiveTicket, beSL, curTP))
         {
            Print("[BREAKEVEN] +1R reached. SL locked at ", DoubleToString(beSL, _Digits),
                  " — trade can no longer lose.");
            curSL = beSL;
         }
         BreakEvenDone = true;
      }
   }

   // ---- Stage 2: chandelier ATR trail ----
   if(UseTrailingStop && profitR >= Trail_ActivateR)
   {
      double trailDist = GetATR() * Chandelier_ATR_Mult;
      double stepDist  = Trail_StepPoints * _Point;

      if(type == POSITION_TYPE_BUY)
      {
         // Trail hangs below the HIGHEST price seen since entry.
         double trailSL = NormalizeDouble(ActiveHighWater - trailDist, _Digits);
         if(trailSL > curSL + stepDist)   // ratchet forward only, throttled
         {
            if(trade.PositionModify(ActiveTicket, trailSL, curTP))
               Print("[TRAIL] BUY SL -> ", DoubleToString(trailSL, _Digits),
                     " | profit=", DoubleToString(profitR, 2), "R");
         }
      }
      else
      {
         // Trail hangs above the LOWEST price seen since entry.
         double trailSL = NormalizeDouble(ActiveLowWater + trailDist, _Digits);
         if(curSL == 0 || trailSL < curSL - stepDist)
         {
            if(trade.PositionModify(ActiveTicket, trailSL, curTP))
               Print("[TRAIL] SELL SL -> ", DoubleToString(trailSL, _Digits),
                     " | profit=", DoubleToString(profitR, 2), "R");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Daily circuit breakers (percent-based; ON by default).            |
//| Returns true while trading is halted for the day.                 |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   if(DailyLimitHit) return true;
   if(DailyStartBalance <= 0) return false;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPLpc = (equity - DailyStartBalance) / DailyStartBalance * 100.0;

   if(DailyLossLimit_Pct > 0 && dayPLpc <= -DailyLossLimit_Pct)
   {
      Print("[DAILY LIMIT] Down ", DoubleToString(-dayPLpc, 2),
            "% today — trading halted until tomorrow.");
      CloseAllPositions();
      DailyLimitHit = true;
      return true;
   }
   if(DailyProfitTarget_Pct > 0 && dayPLpc >= DailyProfitTarget_Pct)
   {
      Print("[DAILY LIMIT] Up ", DoubleToString(dayPLpc, 2),
            "% today — banking the day and stopping.");
      CloseAllPositions();
      DailyLimitHit = true;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Flatten every position belonging to this EA on this symbol.       |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            double pl = PositionGetDouble(POSITION_PROFIT);
            trade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET));
            if(pl > 0) TodayWins++; else TodayLosses++;
         }
   ResetPositionState();
}

//+------------------------------------------------------------------+
//| True if this EA holds any position on this symbol.                |
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}
//+------------------------------------------------------------------+
