//+------------------------------------------------------------------+
//|                          YX_M5_scalper_v12_ATR_BE_MeanRevFix.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.07"

//+------------------------------------------------------------------+
//| YX M5 Scalper v10 — SEQUENTIAL LOT-LADDER edition                  |
//| Quant Only Closed Candle M1 RSI + Mean Reversion                  |
//|                                                                    |
//| CHANGES IN THIS VERSION (vs YX_M5_scalper_v9_loss_recovery):       |
//|  6. SEQUENTIAL LOT-LADDER SUBSYSTEM (NEW) - entirely additive,     |
//|     off by default (UseLadder = false).                            |
//|                                                                    |
//|     Trade #1 of each M5 candle is completely unchanged - it's the  |
//|     EA's normal DecideDirection()/CheckM1Confirmation()/           |
//|     ExecuteBuy()/ExecuteSell() flow, exactly as before.            |
//|                                                                    |
//|     If UseLadder=true, once that trade closes (by ANY exit - SL,   |
//|     TP, breakeven, trail, candle-end - it doesn't matter which),   |
//|     and IF the trend/EMA/volume/candle-body conditions still       |
//|     confirm the SAME direction, the EA opens another trade in that |
//|     same direction with a smaller lot. Only ONE ladder trade is    |
//|     ever open at a time - the next one never opens until the       |
//|     previous one has fully closed.                                 |
//|                                                                    |
//|     Lot size per trade #: Ladder_StartLot (0.27) minus             |
//|     Ladder_LotStep (0.01) per trade, floored at Ladder_FloorLot     |
//|     (0.20) and held there for as many further trades as fire.       |
//|     e.g. 0.27, 0.26, 0.25, 0.24, 0.23, 0.22, 0.21, 0.20, 0.20, ...  |
//|                                                                    |
//|     Starting at trade # Ladder_HedgeStartTrade (default 6), a new   |
//|     safety rule applies: if THAT specific trade's floating loss     |
//|     exceeds Ladder_HedgeTriggerDollars ($20), the EA opens an       |
//|     EQUAL-LOT opposite-direction hedge against it (a true P&L       |
//|     freeze, not a mismatched-lot directional bet). That pair is     |
//|     then watched as a "basket" - once their COMBINED floating       |
//|     profit reaches Ladder_HedgeCloseInProfit, both legs are closed  |
//|     together. Once a hedge fires, the ladder is DONE for that       |
//|     candle - no further ladder trades, even after the basket        |
//|     eventually closes (it may close in the following candle).       |
//|                                                                    |
//|     Re-entry conditions checked before every ladder trade (2nd      |
//|     onward), reusing existing EA signals - see                      |
//|     LadderReentryConditionsMet():                                   |
//|       - Trend: same MTF EMA alignment as GetTrendAlignmentScore()   |
//|         (from the v9 recovery subsystem) must still agree with the  |
//|         ladder's direction on at least Ladder_MinTrendScore/3        |
//|         timeframes.                                                 |
//|       - Volume: latest closed M5 candle's tick volume vs its own    |
//|         N-bar average must be >= Ladder_MinVolumeRatio.              |
//|       - EMA distance: price must not be more than                   |
//|         Ladder_MaxEMA_DistanceATR * ATR away from the M5 fast EMA -  |
//|         i.e. don't pyramid into an already-overextended move.       |
//|       - Body: latest closed M5 candle's body must still meet        |
//|         MinAvgBody_Points (same input the normal strategy uses).    |
//|                                                                    |
//|     The v9 loss-recovery system (-$50 independent trigger) is left  |
//|     running exactly as before and applies to ladder trades too,     |
//|     completely independently of this subsystem - a ladder trade     |
//|     can hit its own -$50 recovery trigger regardless of where it    |
//|     sits in the ladder sequence.                                    |
//|                                                                    |
//|     To keep all of the above from interfering with each other,      |
//|     positions tagged "LADDER_HEDGE_" (the hedge leg only - NOT the  |
//|     original ladder trades, which keep normal "M5v4 BUY/SELL"       |
//|     comments and stay fully subject to every existing system) are   |
//|     excluded from CheckProfitTarget(), HandleCandleEndClose(),      |
//|     ManageTrailing(), and ManageLossRecovery() - same pattern       |
//|     already used for "RECOVERY_"-tagged legs from v9.               |
//|                                                                    |
//|  Carried over from YX_M5_scalper_v9_loss_recovery and earlier       |
//|  versions: loss recovery (hedge/average/close), breakeven stop,     |
//|  fixed 0.27 lot default entry, Fixed_SL_Points=1503 backstop -      |
//|  all unchanged.                                                     |
//|                                                                    |
//|  #9 RISK:REWARD-LINKED TP (NEW, v3.05):                            |
//|     Previously TP came from ATR (ATR_TP_Mult), capped at            |
//|     Max_TP_Points=150 - vs a Fixed_SL_Points of 1503, a ~1:10       |
//|     reward:risk ratio on paper. New TP_Mode input defaults to       |
//|     TP_MODE_RR, which ties TP directly to the SL distance:          |
//|        tp_points = Fixed_SL_Points * TP_RiskReward_Ratio            |
//|     Default TP_RiskReward_Ratio=0.5 -> TP ~= 751pts (5x the old     |
//|     150pt cap), bounded by RR_Min_TP_Points/RR_Max_TP_Points.       |
//|     Set TP_Mode = TP_MODE_ATR to revert to the exact old behavior   |
//|     with zero other changes - both code paths live side by side in |
//|     GetSLTP(). This only changes where the TP price level is set;   |
//|     it does not touch breakeven, trailing, ladder, or loss-recovery |
//|     logic, all of which still manage exits independently and will   |
//|     usually close trades well before either SL or the new TP.       |
//|                                                                    |
//|  #10 SINGLE-SOURCE-OF-TRUTH TP (NEW, v3.06):                        |
//|     CheckProfitTarget() previously ran TWO extra profit checks on    |
//|     every tick, always on, alongside the broker-side TP price from   |
//|     GetSLTP(): a fixed $12.03 floating-profit close, and a dynamic   |
//|     ATR x 2.0 points close. Because $12.03 is reached at a fraction  |
//|     of the RR-linked TP distance, this secondary check was almost    |
//|     always firing first - silently closing trades long before the   |
//|     RR-linked TP (or even the old ATR-based TP) could ever be hit.   |
//|     Both checks are now gated behind UseLegacySecondaryTP (default   |
//|     false), so GetSLTP()'s price-level TP is the EA's sole active    |
//|     target. Set UseLegacySecondaryTP = true to restore the exact     |
//|     old always-on behavior for side-by-side comparison - nothing     |
//|     else in CheckProfitTarget() changed, and HandleCandleEndClose(), |
//|     ManageTrailing(), ManageLossRecovery(), and the ladder subsystem  |
//|     are all completely untouched by this change.                     |
//+------------------------------------------------------------------+
//|  #11 ATR-RELATIVE BREAKEVEN (NEW, v3.07 / v12):                     |
//|     The old breakeven stage used flat point values                  |
//|     (BreakEven_TriggerPoints=15, BreakEven_LockPoints=5) regardless  |
//|     of volatility. On a volatile session that 5pt lock sat well      |
//|     inside normal noise/spread and stopped winners out early; on a   |
//|     quiet session it gave up more of the available move than         |
//|     necessary. UseATR_BreakEven (default true) now scales both       |
//|     numbers with the live M5 ATR, same way ManageTrailing()'s Stage  |
//|     2 already does:                                                  |
//|        effTrigger = MAX(BreakEven_TriggerPoints, ATR_pts * BreakEven_TriggerATR_Mult) |
//|        effLock    = MAX(BreakEven_LockPoints,    ATR_pts * BreakEven_LockATR_Mult)    |
//|     BreakEven_TriggerPoints/BreakEven_LockPoints are kept as FLOORS  |
//|     so behavior on quiet days is never tighter than before - it only |
//|     widens when ATR justifies it. Set UseATR_BreakEven=false to      |
//|     revert to the exact old fixed-point behavior. Nothing else in    |
//|     ManageTrailing() (the ATR trail stage, the "most protective"     |
//|     ratchet logic) changed.                                          |
//|                                                                       |
//|  #12 MEAN-REVERSION DIRECTION FIX (NEW, v3.07 / v12):                |
//|     Previously the mean-reversion branch inside CheckM1Confirmation()|
//|     only ever ran on candles where DecideDirection() had ALREADY     |
//|     picked a trend-following bias (CandleDirection = BUY/SELL), and  |
//|     it could fire in the OPPOSITE direction of that bias with no     |
//|     check at all - e.g. trend says BUY, mean-reversion RSI reads     |
//|     overbought and fires a contradicting SELL on the same candle.    |
//|     True range/no-trend candles (CandleDirection = SKIP), which are  |
//|     the natural home for a reversion trade, never got evaluated for  |
//|     mean reversion at all.                                           |
//|                                                                       |
//|     New MeanRev_Mode input controls this:                            |
//|       MEANREV_SKIP_ONLY (default)  - mean reversion is ONLY allowed  |
//|          to fire on candles where DecideDirection() returned SKIP    |
//|          (no clean trend) - a genuine contrarian/range regime that   |
//|          no longer fights the trend engine for the same entry slot.  |
//|          The OnTick() gate that used to skip CheckM1Confirmation()   |
//|          entirely on SKIP candles now still calls it in this mode,   |
//|          purely so the mean-reversion branch gets evaluated; the     |
//|          momentum-confirmation branch further down is unaffected     |
//|          since it explicitly requires CandleDirection=="BUY"/"SELL". |
//|       MEANREV_AGREE_WITH_TREND - mean reversion may only fire when   |
//|          its signal direction matches CandleDirection (reinforces    |
//|          the trend call instead of fighting or replacing it).        |
//|       MEANREV_INDEPENDENT - restores the exact old v11 behavior      |
//|          (fires regardless of CandleDirection, including opposite).  |
//|                                                                       |
//|     Also new: MeanRev_RequireEMA_Extension (default true) with       |
//|     MeanRev_MinEMA_DistanceATR (default 0.8). RSI-overbought/oversold|
//|     alone doesn't confirm price is actually stretched away from the  |
//|     mean it would be "reverting" to - this adds that check using the |
//|     same M5 fast EMA / ATR handles already used elsewhere, requiring |
//|     price to be at least this many ATRs away from EMA_Fast_M5 before |
//|     a reversion entry is allowed. Set the bool to false to skip it.  |
//|                                                                       |
//|     No other logic (SL/TP, trailing Stage 2, ladder, loss-recovery,  |
//|     candle-end close, daily limits) was touched by this change.      |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>
#include <JAson.mqh>

CTrade trade;

//=== TRADE PARAMETERS ===
// NOTE: LotSize is kept here only for reference / backward compatibility with
// the rest of the code base. It is NO LONGER USED to size trades - as of this
// version every trade (BUY and SELL) uses a hard-coded fixed lot of 0.27,
// enforced inside CalcLot(). Changing this input will have NO effect on the
// actual traded volume

input double LotSize = 0.10;              // (unused for sizing — see CalcLot(), fixed at 0.27)
input long MagicNumber = 20260607;

//=== FIXED LOT SIZE (ALWAYS APPLIED TO BUY & SELL) ===
// This is the single source of truth for trade volume in this EA version.
// Every BUY and every SELL will use exactly this many lots, regardless of
// account balance, risk percent, or stop-loss distance.
input double Fixed_Entry_Lot = 0.27;      // Fixed lot size used for ALL entries (BUY + SELL)

//=== SL/TP SETTINGS ===
input double Fixed_SL_Points = 1503;      // Fixed SL distance in points (e.g. price 4060 → SL 2557)
input double ATR_TP_Mult = 3.0;           // TP multiplier based on ATR (only used when TP_Mode = TP_MODE_ATR)
input double Max_TP_Points = 150;         // Cap TP at this many points in ATR mode (avoid too high)
input double Min_TP_Points = 40;          // Minimum TP in ATR mode to ensure worthwhile trades

//=== #9 RISK:REWARD-LINKED TP (NEW) ===
// The old ATR-based TP was capped at Max_TP_Points (150), while Fixed_SL_Points
// sits at 1503 - roughly a 1:10 reward:risk ratio on paper (in practice most
// trades never touch the fixed SL because breakeven/trailing manage the exit
// first, but the raw ratio was still worth fixing).
//
// TP_MODE_RR ties TP directly to the SL distance instead of ATR:
//    tp_points = Fixed_SL_Points * TP_RiskReward_Ratio
// e.g. with the defaults below (ratio 0.5), TP = 1503 * 0.5 = ~751 points -
// about 5x the old 150-point cap. RR_Min/Max_TP_Points act as safety rails
// on top of that so a misconfigured ratio can't produce an absurd target.
//
// TP_MODE_ATR keeps the exact old behavior (untouched) for A/B comparison -
// just flip TP_Mode back to TP_MODE_ATR to revert with zero other changes.
enum ENUM_TP_MODE
{
   TP_MODE_ATR,   // Legacy: TP = ATR * ATR_TP_Mult, capped by Min/Max_TP_Points
   TP_MODE_RR     // NEW: TP = Fixed_SL_Points * TP_RiskReward_Ratio, capped by RR_Min/Max_TP_Points
};

input ENUM_TP_MODE TP_Mode              = TP_MODE_RR; // Which TP calculation to use
input double TP_RiskReward_Ratio        = 0.5;   // TP = SL distance * this ratio (RR mode only)
input double RR_Min_TP_Points           = 40;     // Safety floor for TP in RR mode
input double RR_Max_TP_Points           = 900;    // Safety ceiling for TP in RR mode (0 = no cap)

//=== #7 LOSS RECOVERY (NEW) ===
// See the version-header comment block at the top of this file for the full
// explanation of what this does and its risks. Off by default
// (UseLossRecovery = false) so existing behavior is 100% unchanged unless
// you explicitly turn it on.
enum ENUM_RECOVERY_MODE
{
   RECOVERY_CLOSE,    // Always cut the loss immediately once triggered
   RECOVERY_HEDGE,    // Always open an opposite-direction recovery order
   RECOVERY_AVERAGE,  // Always open a same-direction recovery order (martingale-style add)
   RECOVERY_AUTO      // Pick CLOSE/HEDGE/AVERAGE using existing MTF trend signals
};

input bool   UseLossRecovery            = true;  // Master switch - if false, this subsystem does nothing at all
input double LossRecovery_TriggerDollars = 50.0;  // Floating loss (in account currency) that arms a recovery decision
input ENUM_RECOVERY_MODE LossRecoveryMode = RECOVERY_AUTO; // How to react once triggered
input double LossRecovery_Lot           = 0.4;    // Lot size for the HEDGE/AVERAGE recovery order
input double LossRecovery_CloseInProfit = 12.36;   // Close BOTH legs once their COMBINED floating profit reaches this

//=== #8 SEQUENTIAL LOT-LADDER (NEW) ===
// See the version-header comment block at the top of this file for the
// full explanation. Off by default (UseLadder = false) so nothing changes
// unless you explicitly enable it.
input bool   UseLadder                  = true; // Master switch
input double Ladder_StartLot            = 0.27;  // Trade #1 lot (should match Fixed_Entry_Lot)
input double Ladder_LotStep             = 0.01;  // Lot decrease per subsequent trade
input double Ladder_FloorLot            = 0.20;  // Never go below this lot size - holds here once reached
input int    Ladder_HedgeStartTrade     = 6;      // Trade # from which the loss-triggered equal-lot hedge rule applies
input double Ladder_HedgeTriggerDollars = 20.0;   // Floating loss (on that specific trade) that triggers the hedge
input double Ladder_HedgeCloseInProfit  = 12.36;   // Close BOTH hedge legs once their COMBINED floating profit reaches this
input int    Ladder_MinTrendScore       = 3;      // 0-3: how many of the 3 timeframes must still agree with the ladder direction to re-enter
input double Ladder_MinVolumeRatio      = 1.0;    // Latest closed M5 candle's volume vs its own N-bar average must be >= this to re-enter
input int    Ladder_VolumeAvgBars       = 10;      // N-bar window for the volume average above
input double Ladder_MaxEMA_DistanceATR  = 1.5;    // Skip re-entry if price is more than this many ATRs away from the M5 fast EMA (avoid pyramiding into an overextended move)

//=== #3 HOLD WINNERS PAST CANDLE (IMPROVED) ===
input bool HoldWinnersPastCandle = true;
input double HoldMinProfitPoints = 20;    // REDUCED from 30 - catch smaller trends
input double HoldTrailBuffer = 10;        // Keep trail buffer this far behind price

//=== #4 TRAILING STOP (OPTIMIZED) ===
input bool UseTrailingStop = true;
input double Trail_ATR_Mult = 0.8;        // REDUCED from 1.0 - tighter trail
input int Trail_StartPoints = 25;         // REDUCED from 40 - trail earlier
input int Trail_StepPoints = 15;          // Move SL by this much when trailing

//=== #4b BREAKEVEN STOP (NEW) ===
// Moves the SL to "entry + a small locked buffer" as soon as a trade has
// moved BreakEven_TriggerPoints in profit — BEFORE the ATR trail (which only
// starts at the wider Trail_StartPoints) ever gets a chance to engage.
// This closes the gap where a trade can run to a small profit, stall, and
// reverse all the way back to the original (often wide) Fixed_SL_Points
// stop without ever having its risk reduced along the way.
input bool UseBreakEven = true;
input double BreakEven_TriggerPoints = 15;  // FLOOR: minimum profit (pts) needed to arm breakeven (used as-is if UseATR_BreakEven=false)
input double BreakEven_LockPoints = 5;      // FLOOR: minimum buffer locked in beyond entry (covers spread/commission)

//=== #11 ATR-RELATIVE BREAKEVEN (NEW, v12) ===
// Scales the breakeven trigger/lock distances with live M5 ATR instead of
// staying fixed, so the stage behaves consistently with the ATR trail
// (Stage 2) that follows it. BreakEven_TriggerPoints/BreakEven_LockPoints
// above are kept as FLOORS - the effective distance is never tighter than
// those values, it only widens when ATR justifies it. Set UseATR_BreakEven
// = false to fall back to the exact old fixed-point-only behavior.
input bool   UseATR_BreakEven          = true;  // Scale breakeven trigger/lock with ATR (floors above still apply)
input double BreakEven_TriggerATR_Mult = 0.5;   // effTrigger = MAX(BreakEven_TriggerPoints, ATR_pts * this)
input double BreakEven_LockATR_Mult    = 0.15;  // effLock    = MAX(BreakEven_LockPoints,    ATR_pts * this)

//=== #5 MTF SCORING ===
input bool UseMTF_Scoring = true;
input int MTF_MinScore = 2;

//=== #6 DAILY LIMITS + RISK SIZING ===
input bool UseRiskSizing = true;
input double RiskPercent = 0.5;           // Reduced to 0.5% for safer trading
input double MaxLot = 1.0;
input double MinLot = 0.01;

//=== DAILY LIMITS (for safety) ===
input bool UseDailyLimits = false;        // Disabled - trades continue all day
input double DailyProfitTarget = 100.0;
input double DailyLossLimit = 50.0;

//=== CONFIRMATION ENTRY SETTINGS ===
input int ConfirmWaitBars = 1;
input double MinM1ConfirmBody = 8.0;      // Reduced to catch more confirmations
input bool RequireM1BreakHigh = true;
input bool RequireM1BreakLow = true;

//=== M1 RSI FILTER ===
input bool UseM1_RSI_Filter = true;
input double M1_RSI_Overbought = 70.0;
input double M1_RSI_Oversold = 30.0;

//=== MEAN REVERSION SETTINGS ===
input bool UseMeanReversion = true;
input double MeanRev_RSI_Overbought = 75.0;
input double MeanRev_RSI_Oversold = 25.0;
input double MeanRev_MinM1Body = 4.0; // Minimum reversal candle body in points
input bool MeanRev_UseClosedM5RSI = false; // false=current M5 RSI, true=closed M5 RSI

//=== #12 MEAN-REVERSION DIRECTION FIX (NEW, v12) ===
// See #12 in the version-header comment block at the top of this file.
enum ENUM_MEANREV_MODE
{
   MEANREV_SKIP_ONLY,        // (default) Only fire when DecideDirection() found no trend (CandleDirection==SKIP) - a genuine contrarian regime, no longer fights the trend engine
   MEANREV_AGREE_WITH_TREND, // Only fire when the reversion signal direction matches CandleDirection (reinforces the trend call)
   MEANREV_INDEPENDENT       // Old v11 behavior - fires regardless of CandleDirection, including directly opposite it
};
input ENUM_MEANREV_MODE MeanRev_Mode          = MEANREV_SKIP_ONLY; // How mean-reversion direction relates to the trend bias
input bool   MeanRev_RequireEMA_Extension     = true;  // Require price to be genuinely stretched away from the M5 fast EMA before allowing a reversion entry
input double MeanRev_MinEMA_DistanceATR       = 0.8;   // Minimum distance from EMA_Fast_M5, in ATR multiples, required when the above is true

//=== MULTI-TIMEFRAME FILTER ===
input bool UseMTF_Filter = true;
input int EMA_Fast_Period = 9;
input int EMA_Slow_Period = 21;

//=== MOMENTUM & FILTERS ===
input int MomentumCandles = 3;
input double MinAvgBody_Points = 10.0;    // REDUCED from 15.0 - catch more setups
input double MinATR_Points = 15.0;        // REDUCED from 25.0 - more entry opportunities
input double RSI_BuyAbove = 51.0;         // REDUCED from 52.0 - more BUY opportunities
input double RSI_SellBelow = 47.0;        // REDUCED from 48.0 - more SELL opportunities

//=== GLOBAL STATE ===
datetime LastM5CandleTime = 0;
bool TradeOpenThisCandle = false;
bool DirectionDecided = false;
string CandleDirection = "NONE";
int M1BarsElapsed = 0;
datetime LastM1Time = 0;
int TodayTrades = 0;
int TodayWins = 0;
int TodayLosses = 0;
int LastTradeDay = -1;
double DailyStartBalance = 0;
bool DailyLimitHit = false;

// Legacy secondary profit targets (see #10 note below) - kept as variables/
// inputs for backward compatibility but no longer active by default, since
// they were firing before the RR-linked TP ever got a chance to be hit.
double TakeProfit_Dollars = 12.03;
input bool UseLegacySecondaryTP = false;   // Off by default (v11 change) - see #10 in header
input double Legacy_DynamicTP_ATR_Mult = 2.0; // Only used if UseLegacySecondaryTP = true

//=== LOSS RECOVERY STATE ===
// Tracks original tickets that have already had a recovery decision made,
// so ManageLossRecovery() only ever acts ONCE per original trade - it
// cannot re-trigger and stack a second recovery leg on top of the first.
ulong RecoveryHandledTickets[];

// A "basket" pairs an original ticket with the recovery ticket opened
// against it (HEDGE or AVERAGE). ManageRecoveryBaskets() watches each
// active basket's COMBINED floating profit and closes both legs together
// once it reaches LossRecovery_CloseInProfit.
struct RecoveryBasket
{
   ulong originalTicket;
   ulong recoveryTicket;
   bool  active;
};
RecoveryBasket RecoveryBaskets[];

//=== LADDER STATE ===
// TradesThisCandle / LadderDirection / LadderOpenTicket / LadderActiveThisCandle
// all reset at the start of every new M5 candle (see OnTick). LadderBaskets is
// NOT reset per candle - a hedge basket opened near a candle boundary is
// allowed to keep being managed into the next candle until it actually closes.
int      TradesThisCandle       = 0;
bool     LadderActiveThisCandle = false;
string   LadderDirection        = "NONE";
ulong    LadderOpenTicket       = 0;
datetime LastLadderCheckM1Time  = 0;

struct LadderBasket
{
   ulong originalTicket;
   ulong hedgeTicket;
   bool  active;
};
LadderBasket LadderBaskets[];

//=== INDICATOR HANDLES ===
int hEMA_Fast_M5, hEMA_Slow_M5;
int hEMA_Fast_M15, hEMA_Slow_M15;
int hRSI_M5;
int hATR_M5;
int hMA20_H1, hMA50_H1, hRSI_H1;
int hRSI_M1;
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   
   hEMA_Fast_M5 = iMA(_Symbol, PERIOD_M5, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M5 = iMA(_Symbol, PERIOD_M5, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5 = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   hATR_M5 = iATR(_Symbol, PERIOD_M5, 14);
   
   hEMA_Fast_M15 = iMA(_Symbol, PERIOD_M15, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow_M15 = iMA(_Symbol, PERIOD_M15, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   hMA20_H1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   hMA50_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   hRSI_H1  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   
   if(hEMA_Fast_M5 == INVALID_HANDLE || hEMA_Slow_M5 == INVALID_HANDLE ||
      hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA_Fast_M15 == INVALID_HANDLE || hEMA_Slow_M15 == INVALID_HANDLE)
      return(INIT_FAILED);
   
   Print("[INIT] YX M5 Scalper v10 - RR-LINKED TP edition");
   Print("[INIT] Fixed Entry Lot=" + DoubleToString(Fixed_Entry_Lot, 2) + " lots (applied to BOTH BUY and SELL)");
   Print("[INIT] Fixed SL=" + DoubleToString(Fixed_SL_Points, 0) + "pts | TP_Mode=" + EnumToString(TP_Mode));
   if(TP_Mode == TP_MODE_RR)
      Print("[INIT] TP = SL x " + DoubleToString(TP_RiskReward_Ratio, 2) +
            " -> ~" + DoubleToString(Fixed_SL_Points * TP_RiskReward_Ratio, 0) + "pts" +
            " (floor=" + DoubleToString(RR_Min_TP_Points,0) + ", ceiling=" + (RR_Max_TP_Points>0 ? DoubleToString(RR_Max_TP_Points,0) : "none") + ")");
   else
      Print("[INIT] TP = ATR x " + DoubleToString(ATR_TP_Mult, 2) + " (floor=" + DoubleToString(Min_TP_Points,0) + ", ceiling=" + DoubleToString(Max_TP_Points,0) + ")");
   Print("[INIT] Legacy secondary TP (fixed $" + DoubleToString(TakeProfit_Dollars,2) +
         " / dynamic ATRx" + DoubleToString(Legacy_DynamicTP_ATR_Mult,2) + ") enabled=" +
         (UseLegacySecondaryTP ? "true - WILL override the price-level TP above if hit first" : "false - price-level TP above is the sole active target"));
   Print("[INIT] Breakeven: trigger floor=" + DoubleToString(BreakEven_TriggerPoints,0) + "pts | lock floor=" + DoubleToString(BreakEven_LockPoints,0) + "pts | enabled=" + (UseBreakEven ? "true" : "false"));
   Print("[INIT] ATR-relative Breakeven: enabled=" + (UseATR_BreakEven ? "true" : "false") +
         " | triggerMult=" + DoubleToString(BreakEven_TriggerATR_Mult,2) + "xATR" +
         " | lockMult=" + DoubleToString(BreakEven_LockATR_Mult,2) + "xATR" +
         (UseATR_BreakEven ? " (floors above are the minimum, ATR widens it)" : " (fixed points only)"));
   Print("[INIT] Trail start=" + IntegerToString(Trail_StartPoints) + "pts | Step=" + IntegerToString(Trail_StepPoints) + "pts");
   Print("[INIT] Mean Reversion: enabled=" + (UseMeanReversion ? "true" : "false") +
         " | mode=" + EnumToString(MeanRev_Mode) +
         " | EMA extension filter=" + (MeanRev_RequireEMA_Extension ? ("true (>=" + DoubleToString(MeanRev_MinEMA_DistanceATR,2) + "xATR from EMA_Fast_M5)") : "false"));
   Print("[INIT] Loss Recovery: enabled=" + (UseLossRecovery ? "true" : "false") +
         " | trigger=-$" + DoubleToString(LossRecovery_TriggerDollars,2) +
         " | mode=" + EnumToString(LossRecoveryMode) +
         " | recovery lot=" + DoubleToString(LossRecovery_Lot,2) +
         " | close basket at +$" + DoubleToString(LossRecovery_CloseInProfit,2));
   if(UseLossRecovery)
      Print("[INIT] NOTE: HEDGE mode requires a Hedging-type MT5 account. On a Netting account, opposite-direction orders on the same symbol net together instead of creating a second ticket.");
   Print("[INIT] Ladder: enabled=" + (UseLadder ? "true" : "false") +
         " | lots=" + DoubleToString(Ladder_StartLot,2) + "->" + DoubleToString(Ladder_FloorLot,2) +
         " step " + DoubleToString(Ladder_LotStep,2) +
         " | hedge from trade #" + IntegerToString(Ladder_HedgeStartTrade) +
         " at -$" + DoubleToString(Ladder_HedgeTriggerDollars,2) +
         " | close basket at +$" + DoubleToString(Ladder_HedgeCloseInProfit,2));
   if(UseLadder)
      Print("[INIT] NOTE: Ladder hedge (trade #" + IntegerToString(Ladder_HedgeStartTrade) + "+) also requires a Hedging-type MT5 account, same as the v9 loss-recovery HEDGE mode.");
   
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA_Fast_M5 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M5);
   if(hEMA_Slow_M5 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M5);
   if(hEMA_Fast_M15 != INVALID_HANDLE) IndicatorRelease(hEMA_Fast_M15);
   if(hEMA_Slow_M15 != INVALID_HANDLE) IndicatorRelease(hEMA_Slow_M15);
   if(hRSI_M5 != INVALID_HANDLE) IndicatorRelease(hRSI_M5);
   if(hATR_M5 != INVALID_HANDLE) IndicatorRelease(hATR_M5);
   if(hMA20_H1 != INVALID_HANDLE) IndicatorRelease(hMA20_H1);
   if(hMA50_H1 != INVALID_HANDLE) IndicatorRelease(hMA50_H1);
   if(hRSI_H1 != INVALID_HANDLE) IndicatorRelease(hRSI_H1);
if(hRSI_M1 != INVALID_HANDLE) IndicatorRelease(hRSI_M1);
   Print("[STATS] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses);
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime dt;
   TimeLocal(dt);
   if(dt.day != LastTradeDay)
   {
      Print("[DAILY] Trades=", TodayTrades, " W=", TodayWins, " L=", TodayLosses,
            " WR=", (TodayTrades>0 ? DoubleToString((double)TodayWins/TodayTrades*100,1) : "0"), "%");
      TodayTrades = 0; TodayWins = 0; TodayLosses = 0;
      LastTradeDay = dt.day;
      DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      DailyLimitHit = false;
   }
   
   // Daily limits disabled - trades continue all day
   // if(UseDailyLimits && CheckDailyLimits()) return;
   
   if(HasPosition())
   {
      CheckProfitTarget();
      if(UseTrailingStop) ManageTrailing();
      if(UseLossRecovery)
      {
         ManageLossRecovery();
         ManageRecoveryBaskets();
      }
      if(UseLadder) ManageLadderHedge();
   }
   
   // These run every tick regardless of HasPosition() - ManageLadderBaskets
   // needs to keep watching a hedge basket even after the ladder itself has
   // ended for the candle, and ManageLadderReentry specifically needs to act
   // in the gap right after a ladder trade closes (when HasPosition() is
   // false), so neither can be confined to the block above.
   if(UseLadder)
   {
      ManageLadderBaskets();
      ManageLadderReentry();
   }
   
   datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
   if(currentM5 != LastM5CandleTime)
   {
      if(HasPosition()) HandleCandleEndClose();
      
      LastM5CandleTime = currentM5;
      TradeOpenThisCandle = HasPosition();
      DirectionDecided = false;
      CandleDirection = "NONE";
      M1BarsElapsed = 0;
      LastM1Time = 0;
      
      // Reset ladder state for the new candle. LadderBaskets is intentionally
      // NOT reset here - an open hedge basket keeps being managed by
      // ManageLadderBaskets() until it actually closes, even across a candle
      // boundary.
      TradesThisCandle = 0;
      LadderActiveThisCandle = UseLadder;
      LadderDirection = "NONE";
      LadderOpenTicket = 0;
      
      if(!HasPosition())
      {
         CandleDirection = DecideDirection();
         DirectionDecided = true;
         if(CandleDirection != "SKIP")
            Print("[DIRECTION] ", CandleDirection, " decided. Waiting for M1 confirmation...");
         else if(UseMeanReversion && MeanRev_Mode == MEANREV_SKIP_ONLY)
            Print("[DIRECTION] SKIP (no trend) - scanning for mean-reversion setups instead.");
      }
   }
   
   // #12 v12: previously this gate excluded CheckM1Confirmation() entirely on
   // SKIP candles, which meant the mean-reversion branch inside it could only
   // ever be evaluated on candles where a trend bias already existed - the
   // opposite of where a contrarian/range setup naturally belongs. When
   // MeanRev_Mode == MEANREV_SKIP_ONLY we now still call CheckM1Confirmation()
   // on SKIP candles purely so mean reversion gets a chance to fire; the
   // momentum-confirmation branch further down is unaffected since it
   // explicitly requires CandleDirection=="BUY"/"SELL" and simply does
   // nothing when CandleDirection=="SKIP".
   bool allowMeanRevOnSkip = (UseMeanReversion && MeanRev_Mode == MEANREV_SKIP_ONLY && CandleDirection == "SKIP");

   // Once the ladder has taken its first trade this candle (TradesThisCandle
   // >= 1), all further entries for the rest of this candle are exclusively
   // ManageLadderReentry()'s job - the normal fresh-direction confirmation
   // flow is suppressed so the two can't both try to open a trade at once.
   if(DirectionDecided && !TradeOpenThisCandle && !HasPosition()
      && (CandleDirection != "SKIP" || allowMeanRevOnSkip)
      && !(UseLadder && TradesThisCandle >= 1))
   {
      CheckM1Confirmation();
   }
}

//+------------------------------------------------------------------+
string DecideDirection()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   CopyBuffer(hATR_M5, 0, 0, 1, atr);
   if(atr[0] / _Point < MinATR_Points)
      return "SKIP";
   
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   CopyRates(_Symbol, PERIOD_M5, 1, MomentumCandles, m5);
   
   int bullish = 0, bearish = 0;
   double totalBody = 0;
   for(int i = 0; i < MomentumCandles; i++)
   {
      double body = (m5[i].close - m5[i].open) / _Point;
      totalBody += MathAbs(body);
      if(m5[i].close > m5[i].open) bullish++;
      else if(m5[i].close < m5[i].open) bearish++;
   }
   
   if(totalBody / MomentumCandles < MinAvgBody_Points)
      return "SKIP";
   
   double emaF5[], emaS5[];
   ArraySetAsSeries(emaF5, true);
   ArraySetAsSeries(emaS5, true);
   CopyBuffer(hEMA_Fast_M5, 0, 0, 2, emaF5);
   CopyBuffer(hEMA_Slow_M5, 0, 0, 2, emaS5);
   
   bool m5_bullish = (emaF5[0] > emaS5[0]);
   bool m5_bearish = (emaF5[0] < emaS5[0]);
   
   double rsi5[];
   ArraySetAsSeries(rsi5, true);
   CopyBuffer(hRSI_M5, 0, 0, 2, rsi5);
   
   bool m15_bullish = true, m15_bearish = true;
   bool h1_bullish = true, h1_bearish = true;
   
   if(UseMTF_Filter)
   {
      double emaF15[], emaS15[];
      ArraySetAsSeries(emaF15, true);
      ArraySetAsSeries(emaS15, true);
      CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15);
      CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15);
      m15_bullish = (emaF15[0] > emaS15[0]);
      m15_bearish = (emaF15[0] < emaS15[0]);
      
      double ma20[], ma50[];
      ArraySetAsSeries(ma20, true);
      ArraySetAsSeries(ma50, true);
      CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
      CopyBuffer(hMA50_H1, 0, 0, 1, ma50);
      h1_bullish = (ma20[0] > ma50[0]);
      h1_bearish = (ma20[0] < ma50[0]);
   }
   
   string direction = "SKIP";
   
   if(UseMTF_Scoring)
   {
      int buyScore = 0, sellScore = 0;
      if(m5_bullish) buyScore++;   else if(m5_bearish) sellScore++;
      if(m15_bullish) buyScore++;  else if(m15_bearish) sellScore++;
      if(h1_bullish) buyScore++;   else if(h1_bearish) sellScore++;
      
      if(bullish >= 2 && rsi5[0] > RSI_BuyAbove && buyScore >= MTF_MinScore)
         direction = "BUY";
      else if(bearish >= 2 && rsi5[0] < RSI_SellBelow && sellScore >= MTF_MinScore)
         direction = "SELL";
   }
   else
   {
      if(bullish >= 2 && m5_bullish && rsi5[0] > RSI_BuyAbove && m15_bullish && h1_bullish)
         direction = "BUY";
      else if(bearish >= 2 && m5_bearish && rsi5[0] < RSI_SellBelow && m15_bearish && h1_bearish)
         direction = "SELL";
   }
   
   {
   }
   
   return direction;
}

//+------------------------------------------------------------------+
// #12 v12 helper: does a mean-reversion signal in direction "signalDir"
// ("BUY" or "SELL") satisfy the configured MeanRev_Mode relative to
// CandleDirection (the trend bias DecideDirection() already picked this
// candle)? See the #12 note in the version-header block for details.
//+------------------------------------------------------------------+
bool MeanRevDirectionAllowed(string signalDir)
{
   switch(MeanRev_Mode)
   {
      case MEANREV_SKIP_ONLY:
         return (CandleDirection == "SKIP");
      case MEANREV_AGREE_WITH_TREND:
         return (CandleDirection == signalDir);
      case MEANREV_INDEPENDENT:
      default:
         return true;
   }
}

//+------------------------------------------------------------------+
// #12 v12 helper: is price currently stretched at least
// MeanRev_MinEMA_DistanceATR ATRs away from the M5 fast EMA? RSI-extreme
// alone doesn't confirm price has actually moved away from "the mean" it
// would be reverting to; this adds that confirmation using the same
// EMA/ATR handles already used elsewhere in the EA. Returns true (i.e.
// does not block) when the filter is disabled.
//+------------------------------------------------------------------+
bool MeanRevExtensionOK(double currentPrice)
{
   if(!MeanRev_RequireEMA_Extension) return true;

   double emaF5[];
   ArraySetAsSeries(emaF5, true);
   if(CopyBuffer(hEMA_Fast_M5, 0, 0, 1, emaF5) <= 0) return true; // fail open if indicator data unavailable

   double atr = GetATR();
   if(atr <= 0) return true;

   double distanceATR = MathAbs(currentPrice - emaF5[0]) / atr;
   return (distanceATR >= MeanRev_MinEMA_DistanceATR);
}

//+------------------------------------------------------------------+
void CheckM1Confirmation()
{
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 != LastM1Time)
   {
      LastM1Time = currentM1;
      M1BarsElapsed++;
   }

   if(M1BarsElapsed < ConfirmWaitBars)
      return;

   if(M1BarsElapsed > 3)
   {
      CandleDirection = "SKIP";
      Print("[SKIP] Too late in candle. M1 bars: ", M1BarsElapsed);
      return;
   }

   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, m1) <= 0)
      return;

   double m1Body = (m1[0].close - m1[0].open) / _Point;
   double m1AbsBody = MathAbs(m1Body);
   bool m1Bullish = (m1[0].close > m1[0].open);
   bool m1Bearish = (m1[0].close < m1[0].open);

   // -----------------------------------------------------------------
   // Mean-reversion branch
   // -----------------------------------------------------------------
   // This branch is evaluated before the standard momentum confirmation.
   // The idea is to detect short-term exhaustion and allow a reversal entry
   // only when BOTH timeframes are stretched in the same direction:
   // 1) closed M1 RSI is overbought/oversold
   // 2) M5 RSI is also overbought/oversold
   // 3) the latest CLOSED M1 candle shows a small reversal clue:
   //    - bearish candle for overbought SELL mean reversion
   //    - bullish candle for oversold BUY mean reversion
   // 4) the reversal candle body must still have a minimum size so that a
   //    tiny indecision candle does not trigger a reversal trade.
   //
   // This branch is separated from the existing momentum logic on purpose.
   // If mean reversion fires, the trade is executed immediately and the
   // function returns, so the normal momentum confirmation does not run.
   if(UseMeanReversion)
   {
      double rsiM1[];
      double rsiM5[];
      ArraySetAsSeries(rsiM1, true);
      ArraySetAsSeries(rsiM5, true);

      int m5Shift = (MeanRev_UseClosedM5RSI ? 1 : 0);

      // closed M1 RSI is always read with shift=1 because the user asked for
      // the closed-candle variant. M5 RSI can be taken from current candle
      // or closed candle depending on MeanRev_UseClosedM5RSI.
      if(CopyBuffer(hRSI_M1, 0, 1, 1, rsiM1) > 0 && CopyBuffer(hRSI_M5, 0, m5Shift, 1, rsiM5) > 0)
      {
         double m1RsiVal = rsiM1[0];
         double m5RsiVal = rsiM5[0];

         // SELL mean reversion:
         // If both M1 and M5 RSI are above the overbought threshold and the
         // latest closed M1 candle is bearish, treat it as an exhaustion clue
         // and allow a SELL reversal entry.
         if(m1RsiVal >= MeanRev_RSI_Overbought &&
            m5RsiVal >= MeanRev_RSI_Overbought &&
            m1Bearish &&
            m1AbsBody >= MeanRev_MinM1Body)
         {
            if(!MeanRevDirectionAllowed("SELL"))
            {
               Print("[MEAN REVERSAL] SELL signal blocked by MeanRev_Mode=", EnumToString(MeanRev_Mode),
                     " (CandleDirection=", CandleDirection, ")");
            }
            else if(!MeanRevExtensionOK(SymbolInfoDouble(_Symbol, SYMBOL_BID)))
            {
               Print("[MEAN REVERSAL] SELL signal blocked - price not stretched >= ",
                     DoubleToString(MeanRev_MinEMA_DistanceATR,2), "xATR from EMA_Fast_M5");
            }
            else
            {
               Print("[MEAN REVERSAL] SELL | M1 RSI=", DoubleToString(m1RsiVal, 1),
                     " | M5 RSI=", DoubleToString(m5RsiVal, 1),
                     " | M1 body=", DoubleToString(m1AbsBody, 1), "pts");
               ExecuteSell();
               return;
            }
         }

         // BUY mean reversion:
         // If both M1 and M5 RSI are below the oversold threshold and the
         // latest closed M1 candle is bullish, treat it as a bounce clue
         // and allow a BUY reversal entry.
         if(m1RsiVal <= MeanRev_RSI_Oversold &&
            m5RsiVal <= MeanRev_RSI_Oversold &&
            m1Bullish &&
            m1AbsBody >= MeanRev_MinM1Body)
         {
            if(!MeanRevDirectionAllowed("BUY"))
            {
               Print("[MEAN REVERSAL] BUY signal blocked by MeanRev_Mode=", EnumToString(MeanRev_Mode),
                     " (CandleDirection=", CandleDirection, ")");
            }
            else if(!MeanRevExtensionOK(SymbolInfoDouble(_Symbol, SYMBOL_ASK)))
            {
               Print("[MEAN REVERSAL] BUY signal blocked - price not stretched >= ",
                     DoubleToString(MeanRev_MinEMA_DistanceATR,2), "xATR from EMA_Fast_M5");
            }
            else
            {
               Print("[MEAN REVERSAL] BUY | M1 RSI=", DoubleToString(m1RsiVal, 1),
                     " | M5 RSI=", DoubleToString(m5RsiVal, 1),
                     " | M1 body=", DoubleToString(m1AbsBody, 1), "pts");
               ExecuteBuy();
               return;
            }
         }
      }
   }

   // -----------------------------------------------------------------
   // Standard momentum confirmation branch
   // -----------------------------------------------------------------
   // If mean reversion did not trigger, continue with the original logic:
   // 1) use M1 RSI as a safety filter to avoid buying when M1 is too hot
   //    or selling when M1 is too stretched to the downside
   // 2) require the latest closed M1 candle to have enough body size
   // 3) require candle direction alignment with CandleDirection
   // 4) require price to be on the correct side of the current M5 open
   if(UseM1_RSI_Filter)
   {
      double rsi1[];
      ArraySetAsSeries(rsi1, true);
      if(CopyBuffer(hRSI_M1, 0, 1, 1, rsi1) > 0)
      {
         double rsiVal = rsi1[0];

         if(CandleDirection == "BUY" && rsiVal >= M1_RSI_Overbought)
         {
            Print("[FILTER] M1 RSI overbought (", DoubleToString(rsiVal, 1), "). Skipping BUY confirmation.");
            return;
         }
         if(CandleDirection == "SELL" && rsiVal <= M1_RSI_Oversold)
         {
            Print("[FILTER] M1 RSI oversold (", DoubleToString(rsiVal, 1), "). Skipping SELL confirmation.");
            return;
         }
      }
   }

   if(m1AbsBody < MinM1ConfirmBody)
      return;

   double m5Open = iOpen(_Symbol, PERIOD_M5, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(CandleDirection == "BUY")
   {
      if(!m1Bullish) return;
      if(RequireM1BreakHigh && currentBid <= m5Open) return;

      Print("[CONFIRMED] BUY after ", M1BarsElapsed, " M1 bars");
      ExecuteBuy();
   }

   if(CandleDirection == "SELL")
   {
      if(!m1Bearish) return;
      if(RequireM1BreakLow && currentAsk >= m5Open) return;

      Print("[CONFIRMED] SELL after ", M1BarsElapsed, " M1 bars");
      ExecuteSell();
   }
}

//+------------------------------------------------------------------+
void GetSLTP(double &sl_dist, double &tp_dist)
{
   // Fixed SL at Fixed_SL_Points always, regardless of lot size or volatility
   sl_dist = Fixed_SL_Points * _Point;

   double tp_pts;

   if(TP_Mode == TP_MODE_RR)
   {
      // NEW: TP is a direct ratio of the SL distance, not ATR-derived.
      tp_pts = Fixed_SL_Points * TP_RiskReward_Ratio;

      if(tp_pts < RR_Min_TP_Points) tp_pts = RR_Min_TP_Points;
      if(RR_Max_TP_Points > 0 && tp_pts > RR_Max_TP_Points) tp_pts = RR_Max_TP_Points;

      Print("[SLTP] Mode=RR | SL=", DoubleToString(Fixed_SL_Points,0),
            "pts | TP=", DoubleToString(tp_pts,0),
            "pts | ratio=1:", DoubleToString(TP_RiskReward_Ratio,2));
   }
   else // TP_MODE_ATR - legacy behavior, completely unchanged
   {
      double atr = GetATR();
      double atrPoints = atr / _Point;
      tp_pts = atrPoints * ATR_TP_Mult;

      if(tp_pts < Min_TP_Points) tp_pts = Min_TP_Points;
      if(tp_pts > Max_TP_Points) tp_pts = Max_TP_Points;

      Print("[SLTP] Mode=ATR | Fixed SL=", DoubleToString(Fixed_SL_Points,0),
            "pts | TP=", DoubleToString(tp_pts,0), "pts");
   }

   tp_dist = tp_pts * _Point;
}

//+------------------------------------------------------------------+
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr) <= 0) return 30 * _Point;
   return atr[0];
}

//+------------------------------------------------------------------+
// *** FIXED LOT CHANGE ***
// This function used to calculate lot size dynamically based on either
// risk-percent-of-balance sizing (UseRiskSizing = true) or a static
// LotSize input (UseRiskSizing = false). Both of those code paths have
// been removed for this EA version.
//
// CalcLot() is called from BOTH ExecuteBuy() and ExecuteSell() (see below),
// so returning a single constant value here guarantees that every BUY and
// every SELL trade opened by this EA uses the exact same fixed lot size -
// there is no direction-based (BUY vs SELL), balance-based, or
// SL-distance-based variation anymore.
//
// The sl_dist parameter is intentionally left in the function signature
// (unused) so the rest of the code — which calls CalcLot(sl_dist) from
// ExecuteBuy()/ExecuteSell() — does not need to be modified elsewhere.
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
   // Always trade a fixed 0.27 lots, regardless of BUY/SELL direction,
   // account balance, risk percent, or stop-loss distance.
   double lot = Fixed_Entry_Lot;

   // Still respect the broker's minimum/maximum volume bounds so the
   // fixed lot never gets rejected by the trade server.
   if(lot < MinLot) lot = MinLot;
   if(lot > MaxLot) lot = MaxLot;

   return lot;
}

//+------------------------------------------------------------------+
// lotOverride: -1 (default) means "use CalcLot() as before" - the normal
// entry path (CheckM1Confirmation) always calls these with no argument, so
// its behavior is completely unchanged. The ladder subsystem is the only
// caller that passes an explicit lot for trade #2 onward.
void ExecuteBuy(double lotOverride = -1)
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = (lotOverride > 0) ? lotOverride : CalcLot(sl_dist);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - sl_dist, _Digits);
   double tp = NormalizeDouble(ask + tp_dist, _Digits);

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, "M5v4 BUY"))
      Print("[ERROR] BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      if(UseLadder)
      {
         TradesThisCandle++;
         LadderDirection = "BUY";
         LadderOpenTicket = FindLatestPositionTicket();
      }
      Print("[ENTRY] BUY ", lot, " lots | SL:", sl, " TP:", tp);
   }
}

//+------------------------------------------------------------------+
void ExecuteSell(double lotOverride = -1)
{
   double sl_dist, tp_dist;
   GetSLTP(sl_dist, tp_dist);
   double lot = (lotOverride > 0) ? lotOverride : CalcLot(sl_dist);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + sl_dist, _Digits);
   double tp = NormalizeDouble(bid - tp_dist, _Digits);

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, "M5v4 SELL"))
      Print("[ERROR] SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   else
   {
      TradeOpenThisCandle = true;
      TodayTrades++;
      if(UseLadder)
      {
         TradesThisCandle++;
         LadderDirection = "SELL";
         LadderOpenTicket = FindLatestPositionTicket();
      }
      Print("[ENTRY] SELL ", lot, " lots | SL:", sl, " TP:", tp);
   }
}

//+------------------------------------------------------------------+
// Shared by CheckProfitTarget(), HandleCandleEndClose(), ManageTrailing(),
// and ManageLossRecovery() - true for any position that is a protective
// "leg" managed by its own dedicated basket function rather than by the
// EA's normal per-trade exit logic:
//   "RECOVERY_"     - legs opened by the v9 loss-recovery subsystem
//   "LADDER_HEDGE_" - legs opened by the v10 ladder's loss-triggered hedge
// Original strategy trades (including every ladder trade itself, which
// keeps the normal "M5v4 BUY/SELL" comment) are NOT excluded by this -
// they stay fully subject to every existing system, as intended.
//+------------------------------------------------------------------+
bool IsExcludedComment(string comment)
{
   return (StringFind(comment, "RECOVERY_") == 0 || StringFind(comment, "LADDER_HEDGE_") == 0);
}

//+------------------------------------------------------------------+
void CheckProfitTarget()
{
   // v11: The two checks below (fixed-dollar close and dynamic-ATR close)
   // used to run unconditionally, every tick, alongside the broker-side TP
   // price set in GetSLTP(). Because $12.03 profit is reached at a tiny
   // fraction of the RR-linked TP distance, this secondary check was almost
   // always firing first - silently overriding the RR-linked TP before it
   // could ever be hit. They're now gated behind UseLegacySecondaryTP
   // (default false) so GetSLTP()'s price-level TP is the sole active
   // target. Flip UseLegacySecondaryTP back to true to restore the exact
   // old always-on behavior for comparison - nothing else here changed.
   if(!UseLegacySecondaryTP) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(IsExcludedComment(PositionGetString(POSITION_COMMENT))) continue; // recovery/ladder-hedge legs are managed by their own basket functions instead
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double priceCurrent = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (priceCurrent - priceOpen) / _Point;
      
      if(profit >= TakeProfit_Dollars)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[TP HIT] +$", DoubleToString(profit, 2), " | Points: ", IntegerToString((int)profitPoints));
         continue;
      }
      
      double atr = GetATR() / _Point;
      double dynamicTP = atr * Legacy_DynamicTP_ATR_Mult;
      
      if(profitPoints >= dynamicTP)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
         TodayWins++;
         TradeOpenThisCandle = false;
         Print("[DYNAMIC TP] Profit: ", IntegerToString((int)profitPoints), "pts | Closed at optimal level");
      }
   }
}

//+------------------------------------------------------------------+
void HandleCandleEndClose()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(IsExcludedComment(PositionGetString(POSITION_COMMENT))) continue; // recovery/ladder-hedge legs are managed by their own basket functions instead
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (type == POSITION_TYPE_BUY) ? (bid - openPrice)/_Point : (openPrice - ask)/_Point;
      
      if(HoldWinnersPastCandle && profitPts >= HoldMinProfitPoints)
      {
         Print("[HOLD] Winner running (+", IntegerToString((int)profitPts), "pts). Trail buffer: ", 
               IntegerToString((int)HoldTrailBuffer), "pts");
         continue;
      }
      
      if(profit >= -1.00)
      {
         trade.PositionClose(ticket);
         if(profit > 0) TodayWins++; else TodayLosses++;
         Print("[CANDLE END] ", (profit>0 ? "WIN +$" : "LOSS $"), DoubleToString(profit, 2));
      }
   }
}

//+------------------------------------------------------------------+
// *** BREAKEVEN + ATR TRAIL CHANGE ***
// This function now protects a trade in TWO stages instead of one:
//
//  Stage 1 - BREAKEVEN (new): as soon as profit reaches the effective
//            trigger distance, the SL is moved to entry price
//            (+/- the effective lock distance) to lock in a small
//            guaranteed profit and remove the original (often wide)
//            Fixed_SL_Points risk. This fires EARLIER than the ATR trail
//            because the trigger is expected to be smaller than
//            Trail_StartPoints. As of v12, when UseATR_BreakEven=true the
//            effective trigger/lock distances scale with live M5 ATR
//            (BreakEven_TriggerPoints/BreakEven_LockPoints act as floors) -
//            see the #11 note in the version-header block up top.
//
//  Stage 2 - ATR TRAIL (unchanged mechanic): once profit reaches
//            Trail_StartPoints, the SL trails behind price at a distance
//            of ATR * Trail_ATR_Mult, tightening as the trade runs.
//
// Both candidate stop levels are computed every tick, and the SL is only
// ever moved to whichever candidate is MOST PROTECTIVE (closest to current
// price in the trade's favor) and strictly better than the current SL -
// so the stop can only ratchet forward, never backward, and Stage 2 will
// naturally take over from Stage 1 once the ATR trail overtakes breakeven.
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double atr = GetATR();
   double trailDist = atr * Trail_ATR_Mult;
   double trailStep = Trail_StepPoints * _Point;

   // #11 v12: ATR-relative breakeven. BreakEven_TriggerPoints/BreakEven_LockPoints
   // remain hard FLOORS - effTriggerPts/effLockPts are never smaller than them,
   // they only grow when live ATR calls for more room. Set UseATR_BreakEven=false
   // to force the old fixed-point-only behavior.
   double atrPts = atr / _Point;
   double effTriggerPts = BreakEven_TriggerPoints;
   double effLockPts    = BreakEven_LockPoints;
   if(UseATR_BreakEven)
   {
      effTriggerPts = MathMax(BreakEven_TriggerPoints, atrPts * BreakEven_TriggerATR_Mult);
      effLockPts    = MathMax(BreakEven_LockPoints,    atrPts * BreakEven_LockATR_Mult);
   }
   double beLockDist = effLockPts * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(IsExcludedComment(PositionGetString(POSITION_COMMENT))) continue; // recovery/ladder-hedge legs are managed by their own basket functions instead
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set

         // --- Stage 1: breakeven candidate (ATR-relative when UseATR_BreakEven) ---
         if(UseBreakEven && profitPts >= effTriggerPts)
         {
            double beSL = NormalizeDouble(openPrice + beLockDist, _Digits);
            if(beSL > bestSL) bestSL = beSL;
         }

         // --- Stage 2: ATR trail candidate ---
         if(profitPts >= Trail_StartPoints)
         {
            double trailSL = NormalizeDouble(bid - trailDist, _Digits);
            if(trailSL > bestSL) bestSL = trailSL;
         }

         // Only modify if the best candidate is a real, meaningful improvement
         if(bestSL > curSL + trailStep)
         {
            trade.PositionModify(ticket, bestSL, curTP);
            string stage = (bestSL == NormalizeDouble(openPrice + beLockDist, _Digits)) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] BUY SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts") : ""));
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask)/_Point;
         double bestSL = curSL;   // start from whatever SL is already set
         bool haveCandidate = false;

         // --- Stage 1: breakeven candidate (ATR-relative when UseATR_BreakEven) ---
         if(UseBreakEven && profitPts >= effTriggerPts)
         {
            double beSL = NormalizeDouble(openPrice - beLockDist, _Digits);
            if(!haveCandidate || beSL < bestSL) { bestSL = beSL; haveCandidate = true; }
         }

         // --- Stage 2: ATR trail candidate ---
         if(profitPts >= Trail_StartPoints)
         {
            double trailSL = NormalizeDouble(ask + trailDist, _Digits);
            if(!haveCandidate || trailSL < bestSL) { bestSL = trailSL; haveCandidate = true; }
         }

         // Only modify if we have a candidate and it's a real improvement
         // (tighter/closer to price than the current SL, or SL was unset)
         if(haveCandidate && (curSL == 0 || bestSL < curSL - trailStep))
         {
            trade.PositionModify(ticket, bestSL, curTP);
            string stage = (UseBreakEven && bestSL == NormalizeDouble(openPrice - beLockDist, _Digits)) ? "BREAKEVEN" : "TRAIL";
            Print("[", stage, "] SELL SL -> ", bestSL, " | Profit: ", IntegerToString((int)profitPts), "pts",
                  (stage == "BREAKEVEN" ? (" | eff.trigger=" + DoubleToString(effTriggerPts,0) + "pts eff.lock=" + DoubleToString(effLockPts,0) + "pts") : ""));
         }
      }
   }
}

//+------------------------------------------------------------------+
// *** LOSS RECOVERY SUBSYSTEM ***
// Everything below is new and entirely additive - it never touches
// entries, and the three functions above (CheckProfitTarget,
// HandleCandleEndClose, ManageTrailing) already skip any position whose
// comment starts with "RECOVERY_", so this subsystem is the only thing
// that manages recovery legs.
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// Lightweight trend-alignment check reusing the EA's existing MTF signals
// (same EMAs/MAs as DecideDirection()) - NOT a full re-entry evaluation,
// just "how many of the 3 timeframes still agree with 'direction' right
// now". Returns 0-3.
//+------------------------------------------------------------------+
int GetTrendAlignmentScore(string direction)
{
   double emaF5[], emaS5[], emaF15[], emaS15[], ma20[], ma50[];
   ArraySetAsSeries(emaF5, true);  ArraySetAsSeries(emaS5, true);
   ArraySetAsSeries(emaF15, true); ArraySetAsSeries(emaS15, true);
   ArraySetAsSeries(ma20, true);   ArraySetAsSeries(ma50, true);

   CopyBuffer(hEMA_Fast_M5, 0, 0, 1, emaF5);
   CopyBuffer(hEMA_Slow_M5, 0, 0, 1, emaS5);
   CopyBuffer(hEMA_Fast_M15, 0, 0, 1, emaF15);
   CopyBuffer(hEMA_Slow_M15, 0, 0, 1, emaS15);
   CopyBuffer(hMA20_H1, 0, 0, 1, ma20);
   CopyBuffer(hMA50_H1, 0, 0, 1, ma50);

   bool m5_bull  = emaF5[0]  > emaS5[0];
   bool m15_bull = emaF15[0] > emaS15[0];
   bool h1_bull  = ma20[0]   > ma50[0];

   int score = 0;
   if(direction == "BUY")
   {
      if(m5_bull)  score++;
      if(m15_bull) score++;
      if(h1_bull)  score++;
   }
   else // SELL
   {
      if(!m5_bull)  score++;
      if(!m15_bull) score++;
      if(!h1_bull)  score++;
   }
   return score;
}

//+------------------------------------------------------------------+
// AUTO mode's decision rule. This is a heuristic, not a guarantee -
// no rule can predict where price goes next.
//   3/3 timeframes still agree with the original direction -> thesis
//       looks intact, so AVERAGE (add at a better price).
//   0/3 timeframes agree -> trend has fully flipped against the trade,
//       so CLOSE (cut the loss rather than fight the trend).
//   1-2/3 -> mixed/uncertain -> HEDGE (protect without fully giving up
//       the level, but don't add more risk into an unclear trend either).
//+------------------------------------------------------------------+
ENUM_RECOVERY_MODE DecideRecoveryMode(string originalDirection)
{
   int score = GetTrendAlignmentScore(originalDirection);
   if(score == 3) return RECOVERY_AVERAGE;
   if(score == 0) return RECOVERY_CLOSE;
   return RECOVERY_HEDGE;
}

//+------------------------------------------------------------------+
// Finds the most recently opened position for this symbol/magic - used
// right after opening a recovery order to get its ticket, since a fresh
// trade.Buy()/trade.Sell() call doesn't return the position ticket
// directly (only the order ticket).
//+------------------------------------------------------------------+
ulong FindLatestPositionTicket()
{
   ulong best = 0;
   long bestTime = -1;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      long t = (long)PositionGetInteger(POSITION_TIME);
      if(t > bestTime)
      {
         bestTime = t;
         best = PositionGetInteger(POSITION_TICKET);
      }
   }
   return best;
}

//+------------------------------------------------------------------+
// Opens the HEDGE or AVERAGE recovery order. Direction is opposite the
// original for HEDGE, same as the original for AVERAGE. Uses the same
// Fixed_SL_Points safety backstop as normal entries (so a recovery leg is
// never left completely unprotected) but NO fixed TP - its exit is
// entirely managed by ManageRecoveryBaskets() against the combined basket
// profit target instead.
// Returns the new position ticket, or 0 on failure.
//+------------------------------------------------------------------+
ulong OpenRecoveryOrder(string modeStr, string originalDirection)
{
   string dir = (modeStr == "HEDGE") ? (originalDirection == "BUY" ? "SELL" : "BUY") : originalDirection;
   string comment = "RECOVERY_" + modeStr + "_" + dir;
   double sl_dist = Fixed_SL_Points * _Point;
   bool ok;

   if(dir == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = NormalizeDouble(ask - sl_dist, _Digits);
      ok = trade.Buy(LossRecovery_Lot, _Symbol, ask, sl, 0, comment);
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = NormalizeDouble(bid + sl_dist, _Digits);
      ok = trade.Sell(LossRecovery_Lot, _Symbol, bid, sl, 0, comment);
   }

   if(!ok)
   {
      Print("[RECOVERY] Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return 0;
   }

   ulong newTicket = FindLatestPositionTicket();
   Print("[RECOVERY] Opened ", comment, " | ", DoubleToString(LossRecovery_Lot,2), " lots | ticket ", newTicket);
   return newTicket;
}

//+------------------------------------------------------------------+
bool IsRecoveryHandled(ulong ticket)
{
   for(int i = 0; i < ArraySize(RecoveryHandledTickets); i++)
      if(RecoveryHandledTickets[i] == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
void MarkRecoveryHandled(ulong ticket)
{
   int n = ArraySize(RecoveryHandledTickets);
   ArrayResize(RecoveryHandledTickets, n + 1);
   RecoveryHandledTickets[n] = ticket;
}

//+------------------------------------------------------------------+
void AddRecoveryBasket(ulong origTicket, ulong recTicket)
{
   int n = ArraySize(RecoveryBaskets);
   ArrayResize(RecoveryBaskets, n + 1);
   RecoveryBaskets[n].originalTicket = origTicket;
   RecoveryBaskets[n].recoveryTicket = recTicket;
   RecoveryBaskets[n].active = true;
}

//+------------------------------------------------------------------+
// Watches every ORIGINAL strategy position (never a recovery leg itself -
// those are identified and skipped by their "RECOVERY_" comment prefix).
// Once a position's floating loss reaches LossRecovery_TriggerDollars, this
// makes exactly ONE decision for it and marks it handled permanently - it
// will never re-trigger on that ticket again, even if the loss keeps
// growing afterward. That one-shot rule is what keeps this from turning
// into an open-ended martingale ladder.
//+------------------------------------------------------------------+
void ManageLossRecovery()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(IsExcludedComment(PositionGetString(POSITION_COMMENT))) continue; // never re-trigger off a recovery leg or a ladder-hedge leg

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(IsRecoveryHandled(ticket)) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > -LossRecovery_TriggerDollars) continue; // not in enough loss yet

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string origDir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";

      ENUM_RECOVERY_MODE mode = LossRecoveryMode;
      if(mode == RECOVERY_AUTO) mode = DecideRecoveryMode(origDir);

      MarkRecoveryHandled(ticket); // one-shot, regardless of what happens next

      if(mode == RECOVERY_CLOSE)
      {
         Print("[RECOVERY] CLOSE | cutting loss at $", DoubleToString(profit,2), " on ticket ", ticket);
         trade.PositionClose(ticket);
         TodayLosses++;
         continue;
      }

      string modeStr = (mode == RECOVERY_HEDGE) ? "HEDGE" : "AVERAGE";
      Print("[RECOVERY] ", modeStr, " triggered | original loss=$", DoubleToString(profit,2),
            " on ticket ", ticket, " | opening ", DoubleToString(LossRecovery_Lot,2), " lot recovery order");

      ulong recTicket = OpenRecoveryOrder(modeStr, origDir);
      if(recTicket != 0)
         AddRecoveryBasket(ticket, recTicket);
      else
         Print("[RECOVERY] Failed to open recovery order for ticket ", ticket, " - original trade left under normal SL/trail management only.");
   }
}

//+------------------------------------------------------------------+
// Watches every active basket's COMBINED floating profit (original leg +
// recovery leg) and closes BOTH together once it reaches
// LossRecovery_CloseInProfit ("close the trade in positive"). Also
// contains a safety cleanup: if one leg of a basket was already closed
// independently by something else (e.g. its own SL was hit), the other
// leg is now orphaned from its intended pairing and is closed too rather
// than left to run unmanaged.
//+------------------------------------------------------------------+
void ManageRecoveryBaskets()
{
   for(int i = ArraySize(RecoveryBaskets) - 1; i >= 0; i--)
   {
      if(!RecoveryBaskets[i].active) continue;

      bool origExists = PositionSelectByTicket(RecoveryBaskets[i].originalTicket);
      double origProfit = origExists ? PositionGetDouble(POSITION_PROFIT) : 0;

      bool recExists = PositionSelectByTicket(RecoveryBaskets[i].recoveryTicket);
      double recProfit = recExists ? PositionGetDouble(POSITION_PROFIT) : 0;

      if(!origExists && !recExists)
      {
         RecoveryBaskets[i].active = false; // both already gone
         continue;
      }

      double basketProfit = origProfit + recProfit;

      if(basketProfit >= LossRecovery_CloseInProfit)
      {
         Print("[RECOVERY] Basket target reached (+$", DoubleToString(basketProfit,2), "). Closing both legs.");
         if(origExists) trade.PositionClose(RecoveryBaskets[i].originalTicket);
         if(recExists)  trade.PositionClose(RecoveryBaskets[i].recoveryTicket);
         RecoveryBaskets[i].active = false;
         TodayWins++;
         continue;
      }

      if(origExists != recExists)
      {
         Print("[RECOVERY] One leg of the basket closed independently - closing the other leg too rather than leaving it unmanaged.");
         if(origExists) trade.PositionClose(RecoveryBaskets[i].originalTicket);
         if(recExists)  trade.PositionClose(RecoveryBaskets[i].recoveryTicket);
         RecoveryBaskets[i].active = false;
      }
   }
}

//+------------------------------------------------------------------+
// *** SEQUENTIAL LOT-LADDER SUBSYSTEM ***
// See the version-header comment block at the top of this file for the
// full explanation. Trade #1 of each candle is untouched - it comes from
// the EA's normal DecideDirection()/CheckM1Confirmation() flow. Everything
// below only handles trade #2 onward within the same candle.
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// Lot size for a given trade number within the ladder (1-based).
// Decreases by Ladder_LotStep per trade, floored at Ladder_FloorLot and
// held there for any further trades.
//+------------------------------------------------------------------+
double GetLadderLot(int tradeIndex)
{
   double lot = Ladder_StartLot - (tradeIndex - 1) * Ladder_LotStep;
   if(lot < Ladder_FloorLot) lot = Ladder_FloorLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
// Latest CLOSED M5 candle's tick volume vs its own N-bar average.
// Returns true (doesn't block) if there isn't enough history yet, rather
// than failing closed on a data hiccup.
//+------------------------------------------------------------------+
bool LadderVolumeConfirms()
{
   long vol[];
   ArraySetAsSeries(vol, true);
   int need = Ladder_VolumeAvgBars + 1;
   if(CopyTickVolume(_Symbol, PERIOD_M5, 1, need, vol) < need) return true;

   double avg = 0;
   for(int i = 1; i < need; i++) avg += (double)vol[i];
   avg /= (need - 1);
   if(avg <= 0) return true;

   double latest = (double)vol[0]; // most recently closed M5 candle
   return (latest / avg) >= Ladder_MinVolumeRatio;
}

//+------------------------------------------------------------------+
// Don't pyramid into an already-overextended move: skip re-entry if
// current price is more than Ladder_MaxEMA_DistanceATR * ATR away from
// the M5 fast EMA.
//+------------------------------------------------------------------+
bool LadderEMA_DistanceOK()
{
   double emaF5[];
   ArraySetAsSeries(emaF5, true);
   if(CopyBuffer(hEMA_Fast_M5, 0, 0, 1, emaF5) <= 0) return true;

   double atr = GetATR();
   if(atr <= 0) return true;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distance = MathAbs(price - emaF5[0]);
   return (distance <= atr * Ladder_MaxEMA_DistanceATR);
}

//+------------------------------------------------------------------+
// Latest CLOSED M5 candle's body must still meet the same minimum body
// size the normal strategy requires for a fresh entry (MinAvgBody_Points).
//+------------------------------------------------------------------+
bool LadderBodyConfirms()
{
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   if(CopyRates(_Symbol, PERIOD_M5, 1, 1, m5) <= 0) return true;
   double body = MathAbs(m5[0].close - m5[0].open) / _Point;
   return (body >= MinAvgBody_Points);
}

//+------------------------------------------------------------------+
// All four re-entry gates combined. Reuses GetTrendAlignmentScore() from
// the v9 recovery subsystem (0-3 timeframes agreeing with 'direction').
//+------------------------------------------------------------------+
bool LadderReentryConditionsMet(string direction)
{
   if(GetTrendAlignmentScore(direction) < Ladder_MinTrendScore) return false;
   if(!LadderVolumeConfirms()) return false;
   if(!LadderEMA_DistanceOK()) return false;
   if(!LadderBodyConfirms()) return false;
   return true;
}

//+------------------------------------------------------------------+
// Fires trade #2, #3, ... within the current candle. Runs unconditionally
// every tick (called from OnTick outside the HasPosition() block) so it
// can react the moment the previous ladder trade closes.
//+------------------------------------------------------------------+
void ManageLadderReentry()
{
   if(!UseLadder) return;
   if(!LadderActiveThisCandle) return;

   // Clear the tracked ticket once its position no longer exists.
   if(LadderOpenTicket != 0 && !PositionSelectByTicket(LadderOpenTicket))
      LadderOpenTicket = 0;

   if(LadderOpenTicket != 0) return;    // previous ladder trade still open - wait for it to close
   if(TradesThisCandle < 1) return;     // trade #1 hasn't happened yet this candle
   if(LadderDirection == "NONE") return;
   if(HasPosition()) return;            // safety: never overlap with any other open position (e.g. a hedge basket)

   // Only evaluate once per new M1 bar close, not every tick, so a stretch
   // of ticks within the same minute can't fire multiple re-entries.
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 == LastLadderCheckM1Time) return;
   LastLadderCheckM1Time = currentM1;

   if(!LadderReentryConditionsMet(LadderDirection)) return;

   int nextTradeIndex = TradesThisCandle + 1;
   double lot = GetLadderLot(nextTradeIndex);

   Print("[LADDER] Re-entry #", nextTradeIndex, " | direction=", LadderDirection, " | lot=", DoubleToString(lot, 2));

   if(LadderDirection == "BUY")       ExecuteBuy(lot);
   else if(LadderDirection == "SELL") ExecuteSell(lot);
}

//+------------------------------------------------------------------+
// Watches the currently open ladder trade once it reaches trade #
// Ladder_HedgeStartTrade onward. If ITS floating loss exceeds
// Ladder_HedgeTriggerDollars, opens an EQUAL-LOT opposite-direction hedge
// (a true P&L freeze) and ends the ladder for this candle.
//+------------------------------------------------------------------+
void ManageLadderHedge()
{
   if(!UseLadder) return;
   if(LadderOpenTicket == 0) return;
   if(TradesThisCandle < Ladder_HedgeStartTrade) return;
   if(!PositionSelectByTicket(LadderOpenTicket)) { LadderOpenTicket = 0; return; }

   // Already hedged (an active basket already references this ticket)?
   for(int i = 0; i < ArraySize(LadderBaskets); i++)
      if(LadderBaskets[i].active && LadderBaskets[i].originalTicket == LadderOpenTicket)
         return;

   double profit = PositionGetDouble(POSITION_PROFIT);
   if(profit > -Ladder_HedgeTriggerDollars) return; // not in enough loss yet

   double lot = PositionGetDouble(POSITION_VOLUME); // EQUAL lot - a true freeze, not a mismatched bet
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   string hedgeDir = (type == POSITION_TYPE_BUY) ? "SELL" : "BUY";
   string comment = "LADDER_HEDGE_" + hedgeDir;
   double sl_dist = Fixed_SL_Points * _Point;
   bool ok;

   if(hedgeDir == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = NormalizeDouble(ask - sl_dist, _Digits);
      ok = trade.Buy(lot, _Symbol, ask, sl, 0, comment);
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = NormalizeDouble(bid + sl_dist, _Digits);
      ok = trade.Sell(lot, _Symbol, bid, sl, 0, comment);
   }

   if(!ok)
   {
      Print("[LADDER HEDGE] Failed to open hedge: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return;
   }

   ulong hedgeTicket = FindLatestPositionTicket();
   Print("[LADDER HEDGE] Trade #", TradesThisCandle, " lost $", DoubleToString(profit, 2),
         " -> opened equal-lot (", DoubleToString(lot, 2), ") ", hedgeDir, " hedge, ticket ", hedgeTicket,
         ". Ladder ends for this candle.");

   int n = ArraySize(LadderBaskets);
   ArrayResize(LadderBaskets, n + 1);
   LadderBaskets[n].originalTicket = LadderOpenTicket;
   LadderBaskets[n].hedgeTicket = hedgeTicket;
   LadderBaskets[n].active = true;

   LadderActiveThisCandle = false; // ladder is done for this candle, even after the basket eventually closes
}

//+------------------------------------------------------------------+
// Watches every active ladder-hedge basket's COMBINED floating profit and
// closes both legs together once it reaches Ladder_HedgeCloseInProfit.
// Also cleans up if one leg already closed independently (e.g. its own
// SL was hit) by closing the orphaned other leg too.
//+------------------------------------------------------------------+
void ManageLadderBaskets()
{
   if(!UseLadder) return;

   for(int i = ArraySize(LadderBaskets) - 1; i >= 0; i--)
   {
      if(!LadderBaskets[i].active) continue;

      bool origExists = PositionSelectByTicket(LadderBaskets[i].originalTicket);
      double origProfit = origExists ? PositionGetDouble(POSITION_PROFIT) : 0;

      bool hedgeExists = PositionSelectByTicket(LadderBaskets[i].hedgeTicket);
      double hedgeProfit = hedgeExists ? PositionGetDouble(POSITION_PROFIT) : 0;

      if(!origExists && !hedgeExists)
      {
         LadderBaskets[i].active = false;
         continue;
      }

      double combined = origProfit + hedgeProfit;

      if(combined >= Ladder_HedgeCloseInProfit)
      {
         Print("[LADDER HEDGE] Basket target reached (+$", DoubleToString(combined, 2), "). Closing both legs.");
         if(origExists)  trade.PositionClose(LadderBaskets[i].originalTicket);
         if(hedgeExists) trade.PositionClose(LadderBaskets[i].hedgeTicket);
         LadderBaskets[i].active = false;
         TodayWins++;
         continue;
      }

      if(origExists != hedgeExists)
      {
         Print("[LADDER HEDGE] One leg closed independently - closing the other leg too rather than leaving it unmanaged.");
         if(origExists)  trade.PositionClose(LadderBaskets[i].originalTicket);
         if(hedgeExists) trade.PositionClose(LadderBaskets[i].hedgeTicket);
         LadderBaskets[i].active = false;
      }
   }
}

//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - DailyStartBalance;
   
   if(dailyPL >= DailyProfitTarget)
   {
      if(!DailyLimitHit)
      {
         Print("[DAILY LIMIT] Profit target reached. Stopping.");
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   if(dailyPL <= -DailyLossLimit)
   {
      if(!DailyLimitHit)
      {
         Print("[DAILY LIMIT] Loss limit reached. Stopping.");
         CloseAllPositions();
         DailyLimitHit = true;
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            trade.PositionClose(PositionGetInteger(POSITION_TICKET));
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}