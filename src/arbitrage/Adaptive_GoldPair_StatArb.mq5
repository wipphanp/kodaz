//+------------------------------------------------------------------+
//|                                    Adaptive_GoldPair_StatArb.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"


//+------------------------------------------------------------------+
//| Adaptive Gold Pair StatArb EA (MQL5 blueprint)                   |
//| Based on Kalman hedge ratio + EWMA z-score + ADF gating          |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//---------------- Inputs ----------------//
input string   SymA = "XAUUSD";
input string   SymB = "GOLD_AUG26";
input long     Magic = 26070301;

input datetime ExpiryB      = D'2026.07.28 23:59';
input int      CloseBeforeH = 48;

input double   BaseLot      = 0.03;
input double   MaxLot       = 0.50;
input double   k_size       = 1.00;
input double   z_entry      = 2.20;
input double   z_exit       = 0.45;
input double   z_hard_stop  = 4.80;

input int      EWMA_half_mu    = 300;
input int      EWMA_half_sigma = 300;

input double   Q_alpha = 1e-8;
input double   Q_beta  = 1e-5;
input double   R_obs   = 1e-2;

input int      ADFBufferSize      = 2048;
input int      ADFCadenceSec      = 300;
input double   ADF_t_threshold    = -2.86;

input double   SliceSizePct   = 0.33;
input int      IOC_timeout_ms = 250;
input int      CleanupSec     = 15;
input int      MinSecsBetween = 480;
input int      MaxConcurrent  = 1;

input double   MaxSpreadA     = 0.60;
input double   MaxSpreadB     = 0.80;
input int      StaleTickSec   = 20;
input int      MaxHoldMin     = 180;
input double   MaxAdverseUSD  = 75.0;
input double   TargetProfitUSD= 35.0;

input double   DailyDDKillPct = 3.0;
input bool     PauseOnADF     = true;
input bool     DebugLog       = true;

//---------------- State ----------------//
struct Kalman2 {
   double alpha, beta;
   double P00, P01, P10, P11;
};

struct EWMAState {
   double mu, var;
   datetime last_update;
   bool init;
};

Kalman2   K;
EWMAState E;

double residuals[];
int    residual_count = 0;
datetime last_adf_check = 0;
datetime last_entry_time = 0;
bool   tradingPaused = false;
double day_start_equity = 0.0;

//---------------- Helpers ----------------//
double Mid(const MqlTick &t) { return 0.5 * (t.bid + t.ask); }

double EWMA_Gain(int dt_seconds, int half_life_seconds)
{
   if(half_life_seconds <= 0) return 1.0;
   return 1.0 - MathExp(-(double)dt_seconds / (double)half_life_seconds);
}

void KalmanInit(Kalman2 &x)
{
   x.alpha = 0.0; x.beta = 1.0;
   x.P00 = 1.0; x.P01 = 0.0; x.P10 = 0.0; x.P11 = 1.0;
}

void KalmanUpdate(Kalman2 &x, double pA, double pB)
{
   x.P00 += Q_alpha;
   x.P11 += Q_beta;

   double H0 = 1.0, H1 = pA;
   double yhat  = x.alpha + x.beta * pA;
   double innov = pB - yhat;

   double S = H0*(x.P00*H0 + x.P01*H1) + H1*(x.P10*H0 + x.P11*H1) + R_obs;
   if(S < 1e-12) S = 1e-12;

   double Kg0 = (x.P00*H0 + x.P01*H1) / S;
   double Kg1 = (x.P10*H0 + x.P11*H1) / S;

   x.alpha += Kg0 * innov;
   x.beta  += Kg1 * innov;

   double P00 = x.P00, P01 = x.P01, P10 = x.P10, P11 = x.P11;
   x.P00 = (1.0 - Kg0*H0)*P00 - Kg0*H1*P10;
   x.P01 = (1.0 - Kg0*H0)*P01 - Kg0*H1*P11;
   x.P10 = -Kg1*H0*P00 + (1.0 - Kg1*H1)*P10;
   x.P11 = -Kg1*H0*P01 + (1.0 - Kg1*H1)*P11;
   x.P01 = x.P10 = 0.5*(x.P01 + x.P10);

   if(x.beta < 0.05) x.beta = 0.05;
   if(x.beta > 20.0) x.beta = 20.0;
}

void EWMAInit(EWMAState &s, double v)
{
   s.mu = v;
   s.var = 1.0;
   s.last_update = TimeCurrent();
   s.init = true;
}

void EWMAUpdate(EWMAState &s, double x)
{
   if(!s.init) { EWMAInit(s, x); return; }
   int dt = (int)(TimeCurrent() - s.last_update);
   if(dt <= 0) dt = 1;

   double k_mu  = EWMA_Gain(dt, EWMA_half_mu);
   double k_var = EWMA_Gain(dt, EWMA_half_sigma);

   double delta = x - s.mu;
   s.mu  += k_mu * delta;
   s.var += k_var * (delta*delta - s.var);

   if(s.var < 1e-10) s.var = 1e-10;
   s.last_update = TimeCurrent();
}

double ZScore(const EWMAState &s, double x)
{
   return (x - s.mu) / (MathSqrt(s.var) + 1e-12);
}

double ADF1_Test(const double &resids[], int n)
{
   if(n < 20) return 0.0;
   double sum_y1 = 0.0, sum_y1y1 = 0.0, sum_dy_y1 = 0.0;
   int m = 0;
   for(int i=1; i<n; ++i)
   {
      double y1 = resids[i-1];
      double dy = resids[i] - y1;
      sum_y1 += y1;
      sum_y1y1 += y1*y1;
      sum_dy_y1 += dy*y1;
      m++;
   }
   if(m < 10) return 0.0;
   double denom = sum_y1y1 - (sum_y1*sum_y1)/m;
   if(MathAbs(denom) < 1e-12) return 0.0;

   double phi = sum_dy_y1 / denom;
   double ssr = 0.0;
   for(int i=1; i<n; ++i)
   {
      double y1 = resids[i-1];
      double dy = resids[i] - y1;
      double eps = dy - phi*y1;
      ssr += eps*eps;
   }
   double se_phi = MathSqrt(ssr / MathMax(m - 1, 1)) / MathSqrt(denom);
   if(se_phi <= 0.0) return 0.0;
   return phi / se_phi;
}

double NormalizeVolume(string symbol, double vol)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   double v = MathRound(vol / step) * step;
   v = MathMax(v, minv);
   v = MathMin(v, maxv);
   int digits = (int)MathRound(-MathLog10(step));
   if(digits < 0) digits = 0;
   if(digits > 8) digits = 8;
   return NormalizeDouble(v, digits);
}

bool GetFreshTick(string symbol, MqlTick &tick)
{
   if(!SymbolInfoTick(symbol, tick)) return false;
   datetime now = TimeCurrent();
   if((int)(now - (datetime)tick.time) > StaleTickSec) return false;
   return true;
}

bool MarketOk(const MqlTick &a, const MqlTick &b)
{
   if((a.ask - a.bid) > MaxSpreadA) return false;
   if((b.ask - b.bid) > MaxSpreadB) return false;
   return true;
}

double ComputeLot(double z, double sigma)
{
   double edge = MathMin(MathAbs(z), 5.0);
   double vol_scale = 1.0 / MathSqrt(sigma + 1e-8);
   double lot = BaseLot * k_size * edge * vol_scale;
   lot = MathMax(lot, BaseLot);
   lot = MathMin(lot, MaxLot);
   return lot;
}

bool NearExpiry()
{
   if(ExpiryB <= 0) return false;
   return (TimeCurrent() >= (ExpiryB - CloseBeforeH * 3600));
}

int CountOpenPositions()
{
   int c = 0;
   for(int i=0; i<PositionsTotal(); ++i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         long mg = (long)PositionGetInteger(POSITION_MAGIC);
         string sym = PositionGetString(POSITION_SYMBOL);
         if(mg == Magic && (sym == SymA || sym == SymB)) c++;
      }
   }
   return c;
}

double BasketProfit()
{
   double pnl = 0.0;
   for(int i=0; i<PositionsTotal(); ++i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         long mg = (long)PositionGetInteger(POSITION_MAGIC);
         if(mg == Magic)
            pnl += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return pnl;
}

bool CloseAllMagic()
{
   bool ok = true;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         long mg = (long)PositionGetInteger(POSITION_MAGIC);
         string sym = PositionGetString(POSITION_SYMBOL);
         if(mg == Magic && (sym == SymA || sym == SymB))
            ok = trade.PositionClose(sym) && ok;
      }
   }
   return ok;
}

void PushResidual(double r)
{
   if(ArraySize(residuals) != ADFBufferSize)
      ArrayResize(residuals, ADFBufferSize);

   if(residual_count < ADFBufferSize)
   {
      residuals[residual_count++] = r;
      return;
   }

   for(int i=1; i<ADFBufferSize; ++i)
      residuals[i-1] = residuals[i];
   residuals[ADFBufferSize-1] = r;
}

bool EntryAllowed()
{
   if(tradingPaused) return false;
   if(NearExpiry()) return false;
   if((TimeCurrent() - last_entry_time) < MinSecsBetween) return false;
   if(CountOpenPositions() >= 2 * MaxConcurrent) return false;
   return true;
}

bool OpenLeg(string symbol, ENUM_ORDER_TYPE type, double vol)
{
   trade.SetExpertMagicNumber(Magic);
   trade.SetTypeFillingBySymbol(symbol);
   bool ok = false;
   if(type == ORDER_TYPE_BUY)  ok = trade.Buy(vol, symbol, 0.0, 0.0, 0.0, "PAIR");
   if(type == ORDER_TYPE_SELL) ok = trade.Sell(vol, symbol, 0.0, 0.0, 0.0, "PAIR");
   return ok;
}

bool OpenPair(bool shortB_longA, double lotA, double lotB)
{
   bool first_ok, second_ok;
   datetime t0 = TimeCurrent();

   if(shortB_longA)
   {
      first_ok = OpenLeg(SymB, ORDER_TYPE_SELL, lotB);
      if(!first_ok) return false;

      second_ok = OpenLeg(SymA, ORDER_TYPE_BUY, lotA);
      if(!second_ok)
      {
         while((TimeCurrent() - t0) < CleanupSec) Sleep(100);
         trade.PositionClose(SymB);
         return false;
      }
   }
   else
   {
      first_ok = OpenLeg(SymB, ORDER_TYPE_BUY, lotB);
      if(!first_ok) return false;

      second_ok = OpenLeg(SymA, ORDER_TYPE_SELL, lotA);
      if(!second_ok)
      {
         while((TimeCurrent() - t0) < CleanupSec) Sleep(100);
         trade.PositionClose(SymB);
         return false;
      }
   }

   last_entry_time = TimeCurrent();
   return true;
}

void ManageOpen(double z)
{
   if(CountOpenPositions() == 0) return;

   if(MathAbs(z) <= z_exit) { CloseAllMagic(); return; }
   if(MathAbs(z) >= z_hard_stop) { CloseAllMagic(); return; }
   if(BasketProfit() >= TargetProfitUSD) { CloseAllMagic(); return; }
   if(BasketProfit() <= -MaxAdverseUSD) { CloseAllMagic(); return; }
   if(NearExpiry()) { CloseAllMagic(); return; }
}

void RunADF()
{
   if((TimeCurrent() - last_adf_check) < ADFCadenceSec) return;
   last_adf_check = TimeCurrent();

   double t_stat = ADF1_Test(residuals, residual_count);
   tradingPaused = PauseOnADF && (residual_count >= 100) && (t_stat > ADF_t_threshold);

   if(DebugLog)
      PrintFormat("ADF t=%.4f paused=%s", t_stat, tradingPaused ? "true" : "false");
}

//---------------- Main ----------------//
int OnInit()
{
   SymbolSelect(SymA, true);
   SymbolSelect(SymB, true);
   KalmanInit(K);
   E.init = false;
   ArrayResize(residuals, ADFBufferSize);
   day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   MqlTick a, b;
   if(!GetFreshTick(SymA, a) || !GetFreshTick(SymB, b)) return;
   if(!MarketOk(a, b)) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(day_start_equity > 0.0)
   {
      double dd_pct = 100.0 * (day_start_equity - equity) / day_start_equity;
      if(dd_pct >= DailyDDKillPct)
      {
         tradingPaused = true;
         CloseAllMagic();
         return;
      }
   }

   double pA = Mid(a), pB = Mid(b);

   KalmanUpdate(K, pA, pB);
   double spread = pB - (K.beta * pA + K.alpha);

   EWMAUpdate(E, spread);
   double sigma = MathSqrt(E.var);
   double z = ZScore(E, spread);

   PushResidual(spread);
   RunADF();
   ManageOpen(z);

   if(!EntryAllowed()) return;

   if(MathAbs(z) >= z_entry)
   {
      double lotA = NormalizeVolume(SymA, ComputeLot(z, sigma));
      double rawB = ComputeLot(z, sigma) * MathMax(0.25, MathMin(K.beta, 4.0));
      double lotB = NormalizeVolume(SymB, rawB);

      bool shortB_longA = (z > 0.0);
      OpenPair(shortB_longA, lotA, lotB);
   }

   if(DebugLog)
      PrintFormat("beta=%.6f alpha=%.4f spread=%.5f mu=%.5f sig=%.5f z=%.3f paused=%s",
                  K.beta, K.alpha, spread, E.mu, sigma, z, tradingPaused ? "true":"false");
}


