//+------------------------------------------------------------------+
//| arbitrage_v2_improved.mq5                                         |
//| Spot-Futures Basis / Statistical Arbitrage EA — Improved Edition |
//| Based on arbitrage_base.mq5 with the following upgrades:          |
//|   1. Volatility-based hedge ratio (dollar-neutral legs)           |
//|   2. Z-score driven entry/exit (adapts to volatility regime)      |
//|   3. Rolling correlation health check (avoids trading a broken    |
//|      spot-futures relationship / structural basis shift)          |
//|   4. Volatility-scaled TP/SL (std-based instead of fixed points)  |
//|   5. Partial profit-taking on convergence (captures more of the   |
//|      typical mean-reversion curve)                                |
//|   6. Unique Magic + Tag per instance to support running multiple  |
//|      parallel pair instances for diversification                 |
//+------------------------------------------------------------------+

#property copyright "2026"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//============================ INPUTS ================================
input group "=== Instruments ==="

input string   SymA = "XAUUSD.";      // leg A
input string   SymB = "XAUUSD.Q26";     // leg B

input datetime ExpiryB      = D'2026.07.28';
input int      CloseBeforeH = 48;

input group "=== Spread Statistics ==="
input int    SmoothSecs      = 300;   // EMA smoothing period for mean & variance of spread
input int    ATR_Period      = 14;
input ENUM_TIMEFRAMES ATR_TF = PERIOD_M5;

input group "=== Z-Score Entry/Exit (NEW) ==="
input bool   UseZScore        = true;
input double ZEntry           = 2.0;   // enter when |zscore| >= this
input double ZExit            = 0.3;   // exit when |zscore| <= this
input double ZPartialExit     = 0.5;   // take partial profit when |zscore| <= this
input double PartialCloseFrac = 0.5;   // fraction of position to close at ZPartialExit
input double MinLevel         = 3.00;  // absolute floor on raw spread before considering entry
input bool   AllowReverse     = true;
input int    MinSecsBetween   = 480;
input int    MaxConcurrent    = 6;
input double MaxSpreadA       = 0.60;
input double MaxSpreadB       = 0.80;

input group "=== Correlation / Relationship Health (NEW) ==="
input bool   UseCorrelationFilter = true;
input int    CorrWindow            = 200;   // number of return samples used for correlation
input double MinCorrelation        = 0.85;
input int    CorrCheckEverySecs    = 30;

input group "=== Volume / Hedge Ratio (NEW) ==="
input double BaseLot         = 0.03;
input double Tier2ZThresh    = 3.0;   // z-score tier boundaries (replaces fixed dollar tiers)
input double Tier2Lot        = 0.06;
input double Tier3ZThresh    = 4.0;
input double Tier3Lot        = 0.12;
input bool   ScaleSecondLeg  = true;  // NEW default: true — volatility-based dollar-neutral hedge
input double MaxRatioB       = 3.0;

input group "=== Management (volatility-scaled, NEW) ==="
input double TargetStdMult   = 0.5;   // full close target = TargetStdMult * spreadStd (used if UseZScore=false)
input double StopStdMult     = 3.0;   // stop = StopStdMult * spreadStd (used if UseZScore=false)
input double TargetClose     = 1.00;  // legacy fixed fallback (used only if UseZScore=false and std unavailable)
input double MaxAdverse      = 3.50;  // legacy fixed fallback
input double TargetMoney     = 0.0;
input int    MaxHoldH        = 60;
input int    CleanupSec      = 15;

input group "=== Control ==="
input int    MaxFails     = 10;
input int    StaleTickSec = 20;
input long   Magic        = 246814;   // NEW unique magic to distinguish from base EA / other pair instances
input int    Slippage     = 30;
input string Tag          = "WPV2";   // NEW unique tag for this instance (supports multi-pair diversification)
input bool   DebugLog     = true;

//============================ GLOBALS ===============================
double   g_ref = 0.0;        bool g_refInit = false;
double   g_spreadVar = 0.0;  // EMA variance of spread deviation
datetime g_lastEntry = 0, g_lastRefUpd = 0;
int      g_nextId = 1, g_fails = 0;
bool     g_halt = false;

int      hATR_A = INVALID_HANDLE, hATR_B = INVALID_HANDLE;

// correlation tracking (return series of mid prices)
double   g_histA[]; double g_histB[];
int      g_histHead = 0; int g_histCount = 0;
double   g_lastMidA = 0.0, g_lastMidB = 0.0; bool g_midInit = false;
datetime g_lastCorrCheck = 0;
bool     g_relationshipHealthy = true;

// partial profit tracking
int      g_partialIds[]; bool g_partialDone[];

//+------------------------------------------------------------------+
string FillStr(string sym)
{
   long fm=(long)SymbolInfoInteger(sym,SYMBOL_FILLING_MODE); string s="";
   if((fm & SYMBOL_FILLING_FOK)!=0) s+="FOK ";
   if((fm & SYMBOL_FILLING_IOC)!=0) s+="IOC ";
   if(s=="") s="RET";
   return(s);
}
string ExecStr(string sym)
{
   long e=SymbolInfoInteger(sym,SYMBOL_TRADE_EXEMODE);
   switch((int)e){ case 0:return("REQUEST"); case 1:return("INSTANT"); case 2:return("MARKET"); case 3:return("EXCHANGE"); }
   return("?");
}

int OnInit()
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Slippage);

   if(!SymbolSelect(SymA,true) || !SymbolSelect(SymB,true))
   { if(DebugLog) Print("init: symbol select failed"); return(INIT_PARAMETERS_INCORRECT); }
   if(SymA==SymB)
   { if(DebugLog) Print("init: identical symbols"); return(INIT_PARAMETERS_INCORRECT); }

   hATR_A = iATR(SymA, ATR_TF, ATR_Period);
   hATR_B = iATR(SymB, ATR_TF, ATR_Period);
   if(hATR_A==INVALID_HANDLE || hATR_B==INVALID_HANDLE)
   { if(DebugLog) Print("init: ATR handle failed"); return(INIT_FAILED); }

   ArrayResize(g_histA, CorrWindow);
   ArrayResize(g_histB, CorrWindow);
   ArrayInitialize(g_histA, 0.0);
   ArrayInitialize(g_histB, 0.0);

   if(DebugLog)
   {
      PrintFormat("init A=%s exec=%s fill=[%s] step=%.2f tv=%.4f volMax=%.2f",
         SymA,ExecStr(SymA),FillStr(SymA),
         SymbolInfoDouble(SymA,SYMBOL_VOLUME_STEP),SymbolInfoDouble(SymA,SYMBOL_TRADE_TICK_VALUE),SymbolInfoDouble(SymA,SYMBOL_VOLUME_MAX));
      PrintFormat("init B=%s exec=%s fill=[%s] step=%.2f tv=%.4f volMax=%.2f",
         SymB,ExecStr(SymB),FillStr(SymB),
         SymbolInfoDouble(SymB,SYMBOL_VOLUME_STEP),SymbolInfoDouble(SymB,SYMBOL_TRADE_TICK_VALUE),SymbolInfoDouble(SymB,SYMBOL_VOLUME_MAX));
   }

   g_nextId = MathMax(1, HighestId()+1);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(hATR_A!=INVALID_HANDLE) IndicatorRelease(hATR_A);
   if(hATR_B!=INVALID_HANDLE) IndicatorRelease(hATR_B);
}

void OnTick(){}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_halt) return;
   double aBid,aAsk,bBid,bAsk;
   if(!GetQ(aBid,aAsk,bBid,bAsk)) return;

   double mid = (bBid+bAsk)/2.0 - (aBid+aAsk)/2.0;
   UpdateRefAndVar(mid);
   UpdateCorrelationHistory((aBid+aAsk)/2.0, (bBid+bAsk)/2.0);

   datetime now = TimeCurrent();
   if(UseCorrelationFilter && (now - g_lastCorrCheck) >= CorrCheckEverySecs)
   {
      g_relationshipHealthy = RelationshipHealthy();
      g_lastCorrCheck = now;
      if(DebugLog && !g_relationshipHealthy) Print("[CORR] relationship unhealthy - entries paused");
   }

   Sweep();
   Manage(aBid,aAsk,bBid,bAsk);
   TryEntry(aBid,aAsk,bBid,bAsk);
}

//+------------------------------------------------------------------+
bool GetQ(double &aBid,double &aAsk,double &bBid,double &bAsk)
{
   MqlTick a,b;
   if(!SymbolInfoTick(SymA,a)) return(false);
   if(!SymbolInfoTick(SymB,b)) return(false);
   aBid=a.bid; aAsk=a.ask; bBid=b.bid; bAsk=b.ask;
   return(aBid>0 && aAsk>0 && bBid>0 && bAsk>0);
}

//+------------------------------------------------------------------+
// FIX #2: track EMA mean AND EMA variance of the spread so we can
// compute a self-adjusting z-score instead of fixed dollar thresholds.
//+------------------------------------------------------------------+
void UpdateRefAndVar(double v)
{
   datetime now = TimeCurrent();
   if(!g_refInit)
   {
      g_ref = v; g_refInit = true; g_lastRefUpd = now; g_spreadVar = 0.0;
      return;
   }
   int dt = (int)(now - g_lastRefUpd); if(dt<=0) dt=1;
   double k = 1.0 - MathExp(-(double)dt / MathMax(1,SmoothSecs));

   double devBefore = v - g_ref;
   g_ref += k * (v - g_ref);
   g_spreadVar += k * (devBefore*devBefore - g_spreadVar);
}

double SpreadStd()
{
   return (g_spreadVar > 0) ? MathSqrt(g_spreadVar) : 0.0;
}

double ZScoreOf(double rawSpread)
{
   double std = SpreadStd();
   if(std <= 0.0000001) return 0.0;
   return (rawSpread - g_ref) / std;
}

//+------------------------------------------------------------------+
// FIX #3: rolling correlation of return series (not raw price levels,
// which would be spuriously high since both track the same commodity).
// A drop below MinCorrelation signals a possible structural break in
// the spot-futures relationship (e.g. supply shock hitting one leg).
//+------------------------------------------------------------------+
void UpdateCorrelationHistory(double midA, double midB)
{
   if(!g_midInit) { g_lastMidA=midA; g_lastMidB=midB; g_midInit=true; return; }
   double dA = midA - g_lastMidA;
   double dB = midB - g_lastMidB;
   g_lastMidA = midA; g_lastMidB = midB;

   g_histA[g_histHead] = dA;
   g_histB[g_histHead] = dB;
   g_histHead = (g_histHead + 1) % CorrWindow;
   if(g_histCount < CorrWindow) g_histCount++;
}

bool RelationshipHealthy()
{
   if(!UseCorrelationFilter) return true;
   if(g_histCount < MathMin(30, CorrWindow)) return true; // not enough data yet, don't block

   double sumA=0, sumB=0;
   for(int i=0;i<g_histCount;i++){ sumA+=g_histA[i]; sumB+=g_histB[i]; }
   double meanA = sumA/g_histCount, meanB = sumB/g_histCount;

   double cov=0, varA=0, varB=0;
   for(int i=0;i<g_histCount;i++)
   {
      double da = g_histA[i]-meanA, db = g_histB[i]-meanB;
      cov += da*db; varA += da*da; varB += db*db;
   }
   if(varA<=0 || varB<=0) return true;
   double corr = cov / MathSqrt(varA*varB);

   if(corr < MinCorrelation)
   {
      if(DebugLog) PrintFormat("[CORR] corr=%.3f below MinCorrelation=%.3f", corr, MinCorrelation);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool Ok(string sym)
{
   long m = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   return(m==SYMBOL_TRADE_MODE_FULL || m==SYMBOL_TRADE_MODE_LONGONLY || m==SYMBOL_TRADE_MODE_SHORTONLY);
}

bool BothFresh()
{
   MqlTick a,b;
   if(!SymbolInfoTick(SymA,a) || !SymbolInfoTick(SymB,b)) return(false);
   datetime now = TimeCurrent();
   if((now-(datetime)a.time) > StaleTickSec) return(false);
   if((now-(datetime)b.time) > StaleTickSec) return(false);
   return(true);
}

//+------------------------------------------------------------------+
void TryEntry(double aBid,double aAsk,double bBid,double bAsk)
{
   if(!g_refInit) return;
   if(Locked()) return;
   if(Count() >= MaxConcurrent) return;
   if((TimeCurrent() - g_lastEntry) < MinSecsBetween) return;
   if(!BothFresh()) return;
   if(!Ok(SymA) || !Ok(SymB)) return;
   if(UseCorrelationFilter && !g_relationshipHealthy) return;
   if((aAsk-aBid) > MaxSpreadA) return;
   if((bAsk-bBid) > MaxSpreadB) return;

   double d1 = bBid - aAsk;   // sell A / buy B direction raw spread
   double d2 = bAsk - aBid;   // buy A / sell B direction raw spread
   double e1 = d1 - g_ref;
   double e2 = g_ref - d2;

   double z1 = ZScoreOf(d1);
   double z2 = -ZScoreOf(d2); // mirrored direction

   bool sig1 = UseZScore ? (z1 >= ZEntry) : (e1 >= 0.80);
   bool sig2 = UseZScore ? (z2 >= ZEntry) : (e2 >= 0.80);

   if(d1 >= MinLevel && sig1)
      Open(true, LotForZ(MathAbs(z1)), d1, z1);
   else if(AllowReverse && sig2)
      Open(false, LotForZ(MathAbs(z2)), d2, z2);
}

double LotForZ(double absZ)
{
   if(absZ >= Tier3ZThresh) return(Tier3Lot);
   if(absZ >= Tier2ZThresh) return(Tier2Lot);
   return(BaseLot);
}

//+------------------------------------------------------------------+
// FIX #1: volatility-based hedge ratio using each leg's ATR and tick
// value, so the two legs carry equal dollar risk (dollar-neutral)
// instead of just matching lot counts.
//+------------------------------------------------------------------+
double GetATRValue(int handle)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 0, 1, buf) <= 0) return 0.0;
   return buf[0];
}

double LotB(double lotA)
{
   if(!ScaleSecondLeg) return(lotA);

   double volA = GetATRValue(hATR_A);
   double volB = GetATRValue(hATR_B);
   double tvA  = SymbolInfoDouble(SymA, SYMBOL_TRADE_TICK_VALUE);
   double tvB  = SymbolInfoDouble(SymB, SYMBOL_TRADE_TICK_VALUE);

   if(volA<=0 || volB<=0 || tvA<=0 || tvB<=0) return(lotA);

   double hedgeRatio = (volA * tvA) / (volB * tvB);
   double v = lotA * hedgeRatio;
   double cap = lotA * MaxRatioB;
   if(v > cap) v = cap;
   if(v < lotA / MaxRatioB) v = lotA / MaxRatioB;
   return(v);
}

double NormalizeLot(string sym, double lot)
{
   double mn=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(st<=0) st=0.01;
   lot = MathRound(lot/st)*st;
   if(lot<mn) lot=mn;
   if(lot>mx) lot=mx;
   return(NormalizeDouble(lot,2));
}

//+------------------------------------------------------------------+
bool SendLeg(bool isBuy, double lot, string sym, string comment, uint &ret, ulong &deal)
{
   ENUM_ORDER_TYPE_FILLING modes[3]; int n=0;
   long fm = (long)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK)!=0) modes[n++]=ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC)!=0) modes[n++]=ORDER_FILLING_IOC;
   modes[n++]=ORDER_FILLING_RETURN;

   lot = NormalizeLot(sym, lot);
   bool done=false;
   for(int i=0;i<n && !done;i++)
   {
      trade.SetTypeFilling(modes[i]);
      if(isBuy) done = trade.Buy(lot, sym, 0.0, 0.0, 0.0, comment);
      else      done = trade.Sell(lot, sym, 0.0, 0.0, 0.0, comment);
      ret = trade.ResultRetcode();
      deal = trade.ResultDeal();
      if(done) break;
      if(!Transient(ret)) continue; else break;
   }
   return(done);
}

//+------------------------------------------------------------------+
void Open(bool mainMode, double lotA, double refval, double zscore)
{
   lotA = NormalizeLot(SymA, lotA);
   double lotB = NormalizeLot(SymB, LotB(lotA));

   int id = g_nextId++;
   string comment = Tag + "#" + IntegerToString(id);

   uint ret; ulong deal;
   // mainMode=true  -> sell A / buy  B  (B rich vs A)
   // mainMode=false -> buy  A / sell B  (A rich vs B)
   bool bOk = SendLeg(!mainMode, lotB, SymB, comment, ret, deal);
   if(!bOk) { Fail(id, 1, ret); return; } // nothing else opened

   bool aOk = SendLeg(mainMode, lotA, SymA, comment, ret, deal);
   if(!aOk) { Fail(id, 2, ret); CloseId(id); return; } // A failed -> unwind B now

   g_fails = 0;
   g_lastEntry = TimeCurrent();
   if(DebugLog) PrintFormat("[OPEN] id=%d lotB=%.2f lotA=%.2f ref=%.2f z=%.2f", id, lotB, lotA, refval, zscore);
}

bool Transient(uint r){ return(r==10018||r==10004||r==10021||r==10031||r==10006); }

void Fail(int id, int leg, uint ret)
{
   if(DebugLog) PrintFormat("[FAIL] id=%d leg=%d ret=%u (%s)", id, leg, ret, RetDesc(ret));
   if(Transient(ret)) return;
   g_fails++;
   if(g_fails >= MaxFails) { g_halt=true; if(DebugLog) Print("[HALT] max fails reached"); }
}

string RetDesc(uint r)
{
   switch(r)
   {
      case 10004: return("requote");
      case 10006: return("rejected by dealer");
      case 10013: return("invalid request");
      case 10014: return("invalid volume");
      case 10015: return("invalid price");
      case 10016: return("invalid stops");
      case 10018: return("market closed");
      case 10019: return("no money");
      case 10021: return("no/off quotes");
      case 10027: return("autotrading disabled");
      case 10030: return("unsupported filling");
      case 10031: return("no connection");
      default: return("retcode");
   }
}

//+------------------------------------------------------------------+
void Sweep()
{
   int ids[]; int n = Ids(ids);
   for(int i=0;i<n;i++)
   {
      int legs=0; datetime ot0=0;
      CountLegs(ids[i], legs, ot0);
      if(legs==1 && (TimeCurrent()-ot0) >= CleanupSec)
      {
         if(DebugLog) PrintFormat("[SWEEP] orphan leg id=%d - closing", ids[i]);
         CloseId(ids[i]);
      }
   }
}

//+------------------------------------------------------------------+
// FIX #4 + #5: volatility-scaled exits (std-based target/stop instead
// of fixed points) plus partial profit-taking on the way to full
// convergence, which captures more of the typical reversion curve.
//+------------------------------------------------------------------+
void Manage(double aBid,double aAsk,double bBid,double bAsk)
{
   int ids[]; int n = Ids(ids);
   bool lock = Locked();
   double std = SpreadStd();

   for(int i=0;i<n;i++)
   {
      int id = ids[i];
      double money=0; datetime ot=0; double entryRef=0; bool mainMode=false;
      if(!PositionsFor(id, money, ot, entryRef, mainMode)) continue;

      double curSpread = mainMode ? (bBid-aAsk) : (bAsk-aBid);
      double conv = mainMode ? (entryRef - curSpread) : (curSpread - entryRef); // positive = converging favorably
      double adv  = -conv; // positive = moving against us

      double z = ZScoreOf(curSpread);
      double absZ = MathAbs(z);

      bool doPartial = UseZScore && (absZ <= ZPartialExit) && !HasPartial(id);
      if(doPartial)
      {
         if(DebugLog) PrintFormat("[PARTIAL] id=%d z=%.2f closing %.0f%%", id, z, PartialCloseFrac*100);
         PartialCloseId(id, PartialCloseFrac);
         MarkPartial(id);
      }

      bool t1;
      if(UseZScore) t1 = (absZ <= ZExit);
      else if(TargetMoney>0) t1 = (money >= TargetMoney);
      else if(std>0) t1 = (conv >= std*TargetStdMult);
      else t1 = (conv >= TargetClose);

      bool t2;
      if(UseZScore) t2 = false; // z-score exit handles convergence; adverse handled by std stop below
      else t2 = (MaxAdverse>0 && adv >= MaxAdverse);
      bool stdStop = (std>0) && (adv >= std*StopStdMult);

      bool t3 = (MaxHoldH>0 && (TimeCurrent()-ot) >= MaxHoldH*3600);

      if(t1 || t2 || stdStop || t3 || lock)
      {
         if(DebugLog) PrintFormat("[CLOSE] id=%d reason=%s z=%.2f conv=%.2f adv=%.2f",
            id, (t1?"target":(stdStop?"stdstop":(t2?"adverse":(t3?"timeout":"locked")))), z, conv, adv);
         CloseId(id);
         ClearPartial(id);
      }
   }
}

//============================ PARTIAL TRACKING ======================
bool HasPartial(int id)
{
   int n = ArraySize(g_partialIds);
   for(int i=0;i<n;i++) if(g_partialIds[i]==id) return g_partialDone[i];
   return false;
}
void MarkPartial(int id)
{
   int n = ArraySize(g_partialIds);
   for(int i=0;i<n;i++) if(g_partialIds[i]==id) { g_partialDone[i]=true; return; }
   ArrayResize(g_partialIds, n+1); ArrayResize(g_partialDone, n+1);
   g_partialIds[n]=id; g_partialDone[n]=true;
}
void ClearPartial(int id)
{
   int n = ArraySize(g_partialIds);
   for(int i=0;i<n;i++)
      if(g_partialIds[i]==id)
      {
         for(int k=i;k<n-1;k++){ g_partialIds[k]=g_partialIds[k+1]; g_partialDone[k]=g_partialDone[k+1]; }
         ArrayResize(g_partialIds, n-1); ArrayResize(g_partialDone, n-1);
         return;
      }
}
void PartialCloseId(int id, double frac)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(IdFrom(PositionGetString(POSITION_COMMENT))!=id) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double closeVol = NormalizeLot(sym, vol*frac);
      if(closeVol > 0 && closeVol < vol)
         trade.PositionClosePartial(tk, closeVol);
   }
}

//============================ HELPERS ==============================
int IdFrom(string c)
{
   string p = Tag + "#";
   int f = StringFind(c, p);
   if(f<0) return(-1);
   string t = StringSubstr(c, f+StringLen(p)), num="";
   for(int i=0;i<StringLen(t);i++)
   {
      ushort ch = StringGetCharacter(t,i);
      if(ch>='0' && ch<='9') num += ShortToString(ch);
      else break;
   }
   return(StringLen(num)==0 ? -1 : (int)StringToInteger(num));
}

int HighestId()
{
   int hi=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      int id = IdFrom(PositionGetString(POSITION_COMMENT));
      if(id>hi) hi=id;
   }
   return(hi);
}

int Ids(int &ids[])
{
   ArrayResize(ids,0);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      int id = IdFrom(PositionGetString(POSITION_COMMENT));
      if(id<0) continue;
      bool f=false;
      int n=ArraySize(ids);
      for(int k=0;k<n;k++) if(ids[k]==id) { f=true; break; }
      if(!f) { ArrayResize(ids, n+1); ids[n]=id; }
   }
   return(ArraySize(ids));
}

int Count()
{
   int ids[];
   return(Ids(ids));
}

void CountLegs(int id, int &legs, datetime &ot0)
{
   legs=0; ot0=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(IdFrom(PositionGetString(POSITION_COMMENT))!=id) continue;
      legs++;
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      if(ot0==0 || ot<ot0) ot0=ot;
   }
}

bool PositionsFor(int id, double &money, datetime &ot0, double &entryRef, bool &mainMode)
{
   money=0; ot0=0; entryRef=0;
   double ao=0,bo=0; long bt=0; bool ha=false, hb=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(IdFrom(PositionGetString(POSITION_COMMENT))!=id) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      long   typ = PositionGetInteger(POSITION_TYPE);
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      money += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(ot0==0 || ot<ot0) ot0=ot;

      if(sym==SymB) { bo=op; bt=typ; hb=true; }
      else if(sym==SymA) { ao=op; ha=true; }
   }
   if(!hb || !ha) return(false);
   mainMode = (bt==POSITION_TYPE_SELL);
   entryRef = bo - ao;
   return(true);
}

bool CloseId(int id)
{
   bool ok=true;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic) continue;
      if(IdFrom(PositionGetString(POSITION_COMMENT))!=id) continue;
      if(!trade.PositionClose(tk)) ok=false;
   }
   return(ok);
}

bool Locked()
{
   if(ExpiryB<=0) return(false);
   return(TimeCurrent() >= (ExpiryB - (datetime)CloseBeforeH*3600));
}
//+------------------------------------------------------------------+
