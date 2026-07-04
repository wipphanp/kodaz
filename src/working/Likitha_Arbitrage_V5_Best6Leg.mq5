//+------------------------------------------------------------------+
//|                                                  WP_Engine.mq5   |
//|                                                    WP_TAG_CODE   |
//+------------------------------------------------------------------+
#property copyright "WP_TAG_CODE"
#property version   "1.05"
#property strict

#include <Trade/Trade.mqh>

#define WP_TAG_CODE "WP"     // watermark / internal tag

//============================ INPUTS ================================
input group "=== Instruments ==="
input string   SymA            = "XAUUSD.";        // leg A
input string   SymB            = "XAUUSD.Q26";     // leg B
input datetime ExpiryB         = D'2026.07.28';
input int      CloseBeforeH    = 48;

input group "=== Parameters ==="
input int      SmoothSecs       = 300;
input double   EntryThresh      = 0.80;
input double   MinLevel         = 3.00;
input bool     AllowReverse     = true;
input int      MinSecsBetween    = 480;
input int      MaxConcurrent    = 3;
input double   MaxSpreadA       = 0.60;
input double   MaxSpreadB       = 0.80;

input group "=== Volume ==="
input double   BaseLot          = 0.03;
input double   Tier2Thresh      = 2.00;
input double   Tier2Lot         = 0.06;
input double   Tier3Thresh      = 4.00;
input double   Tier3Lot         = 0.12;
input bool     ScaleSecondLeg   = false;
input double   MaxRatioB        = 3.0;

input group "=== Management ==="
input double   BasketTP         = 10.00;   // Basket Take Profit ($)
input double   TargetClose      = 3.00;
input double   MaxAdverse       = 3.50;
input double   TargetMoney      = 0.0;
input int      MaxHoldH         = 60;
input int      CleanupSec       = 15;

input group "=== Control ==="
input int      MaxFails         = 10;
input int      StaleTickSec     = 20;     // skip entries if either symbol's last tick is older than this (market closed)
input long     Magic            = 246813;
input int     Slippage         = 30;
input string   Tag              = WP_TAG_CODE;
input bool     DebugLog         = true;   // ON for diagnosis; set false once futures fills cleanly

//============================ GLOBALS ===============================
CTrade   trade;
double   g_ref=0.0; bool g_refInit=false;
datetime g_lastEntry=0, g_lastRefUpd=0;
int      g_nextId=1, g_fails=0; bool g_halt=false;

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
   // Force overrides to defeat MetaTrader Strategy Tester persistent input cache

   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(Slippage);

   if(!SymbolSelect(SymA,true) || !SymbolSelect(SymB,true))
   { if(DebugLog) PrintFormat("init: symbol select failed for %s or %s", SymA, SymB); return(INIT_PARAMETERS_INCORRECT); }
   if(SymA==SymB)
   { if(DebugLog) Print("init: identical symbols"); return(INIT_PARAMETERS_INCORRECT); }

   if(DebugLog)
   {
      PrintFormat("init A=%s mode=%d exec=%s fill=[%s] step=%.2f tv=%.4f volMax=%.2f",
         SymA,(int)SymbolInfoInteger(SymA,SYMBOL_TRADE_MODE),ExecStr(SymA),FillStr(SymA),
         SymbolInfoDouble(SymA,SYMBOL_VOLUME_STEP),SymbolInfoDouble(SymA,SYMBOL_TRADE_TICK_VALUE),SymbolInfoDouble(SymA,SYMBOL_VOLUME_MAX));
      PrintFormat("init B=%s mode=%d exec=%s fill=[%s] step=%.2f tv=%.4f volMax=%.2f",
         SymB,(int)SymbolInfoInteger(SymB,SYMBOL_TRADE_MODE),ExecStr(SymB),FillStr(SymB),
         SymbolInfoDouble(SymB,SYMBOL_VOLUME_STEP),SymbolInfoDouble(SymB,SYMBOL_TRADE_TICK_VALUE),SymbolInfoDouble(SymB,SYMBOL_VOLUME_MAX));
   }

   g_nextId=MathMax(1,HighestId()+1);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason){ EventKillTimer(); }
void OnTick(){}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_halt) return;
   double aBid,aAsk,bBid,bAsk;
   if(!GetQ(aBid,aAsk,bBid,bAsk)) return;
   UpdateRef((bBid+bAsk)/2.0-(aBid+aAsk)/2.0);
   Sweep();
   Manage(aBid,aAsk,bBid,bAsk);
   TryEntry(aBid,aAsk,bBid,bAsk);
}

bool GetQ(double &aBid,double &aAsk,double &bBid,double &bAsk){
   MqlTick a,b; if(!SymbolInfoTick(SymA,a))return(false); if(!SymbolInfoTick(SymB,b))return(false);
   aBid=a.bid;aAsk=a.ask;bBid=b.bid;bAsk=b.ask; return(aBid>0&&aAsk>0&&bBid>0&&bAsk>0); }
void UpdateRef(double v){ datetime now=TimeCurrent();
   if(!g_refInit){g_ref=v;g_refInit=true;g_lastRefUpd=now;return;}
   int dt=(int)(now-g_lastRefUpd); if(dt<=0)dt=1; double k=1.0-MathExp(-(double)dt/MathMax(1,SmoothSecs));
   g_ref+=k*(v-g_ref); g_lastRefUpd=now; }
bool Ok(string sym){ long m=SymbolInfoInteger(sym,SYMBOL_TRADE_MODE);
   return(m==SYMBOL_TRADE_MODE_FULL||m==SYMBOL_TRADE_MODE_LONGONLY||m==SYMBOL_TRADE_MODE_SHORTONLY); }

bool BothFresh()
{
   MqlTick a,b;
   if(!SymbolInfoTick(SymA,a) || !SymbolInfoTick(SymB,b)) return(false);
   datetime now=TimeCurrent();
   if((now-(datetime)a.time) > StaleTickSec) return(false);   // SymA market closed/stale
   if((now-(datetime)b.time) > StaleTickSec) return(false);   // SymB market closed/stale
   return(true);
}

void TryEntry(double aBid,double aAsk,double bBid,double bAsk)
{
   if(!g_refInit) return;
   if(Locked()) return;
   if(Count()>=MaxConcurrent) return;
   if(TimeCurrent()-g_lastEntry<MinSecsBetween) return;
   if(!Ok(SymA)||!Ok(SymB)) return;
   if(!BothFresh()) return;                 // both markets must be open/streaming (avoids closed-session churn)
   if((aAsk-aBid)>MaxSpreadA) return;
   if((bAsk-bBid)>MaxSpreadB) return;

   double d1=bBid-aAsk, d2=bAsk-aBid;
   double e1=d1-g_ref, e2=g_ref-d2;
   if(d1>=MinLevel && e1>=EntryThresh) Open(true ,LotFor(e1),d1);
   else if(AllowReverse && e2>=EntryThresh) Open(false,LotFor(e2),d2);
}
double LotFor(double x){ if(x>=Tier3Thresh)return(Tier3Lot); if(x>=Tier2Thresh)return(Tier2Lot); return(BaseLot); }

bool SendLeg(bool isBuy,double lot,string sym,string comment,uint &ret,ulong &deal)
{
   long ex=SymbolInfoInteger(sym,SYMBOL_TRADE_EXEMODE);
   bool needPrice=(ex!=SYMBOL_TRADE_EXECUTION_MARKET);   // INSTANT/EXCHANGE/REQUEST need a price
   ENUM_ORDER_TYPE_FILLING modes[3]; int n=0;
   long fm=(long)SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK)!=0) modes[n++]=ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC)!=0) modes[n++]=ORDER_FILLING_IOC;
   modes[n++]=ORDER_FILLING_RETURN;
   for(int i=0;i<n;i++){
      trade.SetTypeFilling(modes[i]);
      double px=0.0;
      if(needPrice) px = isBuy ? SymbolInfoDouble(sym,SYMBOL_ASK) : SymbolInfoDouble(sym,SYMBOL_BID);
      bool ok=isBuy?trade.Buy(lot,sym,px,0,0,comment):trade.Sell(lot,sym,px,0,0,comment);
      ret=trade.ResultRetcode(); deal=trade.ResultDeal();
      if(ok && (ret==TRADE_RETCODE_DONE||ret==TRADE_RETCODE_PLACED||ret==TRADE_RETCODE_DONE_PARTIAL)) return(true);
      if(ret!=TRADE_RETCODE_INVALID_FILL) break;
   }
   return(false);
}

void Open(bool mainMode,double lotA,double refval)
{
   g_lastEntry=TimeCurrent();
   int id=g_nextId++; string comment=StringFormat("%s#%d",Tag,id);
   double lotB=NormalizeLot(SymB,LotB(lotA)); lotA=NormalizeLot(SymA,lotA);
   if(lotA<=0||lotB<=0) return;

   uint ret; ulong deal;
   bool bOk=SendLeg(!mainMode,lotB,SymB,comment,ret,deal);   // leg B first
   if(!bOk){ Fail(id,1,ret); return; }                       // B failed -> nothing else opened
   bool aOk=SendLeg(mainMode,lotA,SymA,comment,ret,deal);    // leg A immediately after
   if(!aOk){ Fail(id,2,ret); CloseId(id); return; }          // A failed -> unwind B now
   g_fails=0;
   if(DebugLog) PrintFormat("op %d %.2f/%.2f %.2f",id,lotB,lotA,refval);
}

bool Transient(uint r){ return(r==10018||r==10004||r==10021||r==10031||r==10006); } // closed/requote/offquote/noconn/dealer
void Fail(int id,int leg,uint ret){
   if(DebugLog) PrintFormat("fail %d L%d ret=%u (%s)",id,leg,ret,RetDesc(ret));
   if(Transient(ret)) return;               // do NOT halt on transient broker/session conditions
   g_fails++;
   if(g_fails>=MaxFails){ g_halt=true; if(DebugLog) Print("halt"); } }

string RetDesc(uint r){ switch(r){
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
   default:    return("retcode"); } }

double LotB(double lotA){
   if(!ScaleSecondLeg) return(lotA);
   double a=SymbolInfoDouble(SymA,SYMBOL_TRADE_TICK_VALUE),b=SymbolInfoDouble(SymB,SYMBOL_TRADE_TICK_VALUE);
   double sa=SymbolInfoDouble(SymA,SYMBOL_TRADE_TICK_SIZE),sb=SymbolInfoDouble(SymB,SYMBOL_TRADE_TICK_SIZE);
   if(b<=0||a<=0||sa<=0||sb<=0) return(lotA);
   double v=lotA*(a/sa)/(b/sb), cap=lotA*MaxRatioB; if(v>cap)v=cap; return(v); }
double NormalizeLot(string sym,double lot){ double mn=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   if(st<=0)st=0.01; lot=MathRound(lot/st)*st; if(lot<mn)lot=mn; if(lot>mx)lot=mx; return(NormalizeDouble(lot,2)); }

void Sweep(){ int ids[]; int n=Ids(ids);
   for(int i=0;i<n;i++){ int legs,lb,la; datetime oldest; Legs(ids[i],legs,lb,la,oldest);
      if((lb==0||la==0)&&(TimeCurrent()-oldest)>=CleanupSec) CloseId(ids[i]); } }

void Manage(double aBid,double aAsk,double bBid,double bAsk){ int ids[]; int n=Ids(ids); bool lock=Locked();
   
   // Basket Profit Checking Rule
   if(BasketTP > 0)
   {
      double totalProfit = 0;
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong tk=PositionGetTicket(i); if(tk==0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Magic) continue;
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      if(totalProfit >= BasketTP)
      {
         if(DebugLog) PrintFormat("Basket TP reached: %.2f. Closing all.", totalProfit);
         for(int i=0; i<n; i++) CloseId(ids[i]);
         return;
      }
   }

   for(int i=0; i<n; i++){ int id=ids[i]; bool mainMode; double entryRef,money; datetime ot;
      if(!Info(id,mainMode,entryRef,ot,money))continue;
      double cur=mainMode?(bAsk-aBid):(bBid-aAsk); double conv=mainMode?(entryRef-cur):(cur-entryRef); double adv=-conv;
      bool t1=(TargetMoney>0)?(money>=TargetMoney):(conv>=TargetClose);
      bool t2=(MaxAdverse>0&&adv>=MaxAdverse); bool t3=(MaxHoldH>0&&(TimeCurrent()-ot)>=MaxHoldH*3600);
      if(t1||t2||t3||lock) CloseId(id); } }

//============================ HELPERS ==============================
int IdFrom(string c){ string p=Tag+"#"; int f=StringFind(c,p); if(f<0)return(-1);
   string t=StringSubstr(c,f+StringLen(p)),num=""; for(int i=0;i<StringLen(t);i++){ ushort ch=StringGetCharacter(t,i); if(ch>='0'&&ch<='9')num+=ShortToString(ch); else break; }
   return(StringLen(num)==0?-1:(int)StringToInteger(num)); }
int HighestId(){ int hi=0; for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i); if(tk==0)continue;
   if(PositionGetInteger(POSITION_MAGIC)!=Magic)continue; int id=IdFrom(PositionGetString(POSITION_COMMENT)); if(id>hi)hi=id; } return(hi); }
int Ids(int &ids[]){ ArrayResize(ids,0); for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i); if(tk==0)continue;
   if(PositionGetInteger(POSITION_MAGIC)!=Magic)continue; int id=IdFrom(PositionGetString(POSITION_COMMENT)); if(id<0)continue;
   bool f=false; for(int k=0;k<ArraySize(ids);k++) if(ids[k]==id){f=true;break;} if(!f){int s=ArraySize(ids);ArrayResize(ids,s+1);ids[s]=id;} } return(ArraySize(ids)); }
int Count(){ int ids[]; return(Ids(ids)); }
void Legs(int id,int &legs,int &lb,int &la,datetime &oldest){ legs=0;lb=0;la=0;oldest=TimeCurrent();
   for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i); if(tk==0)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)continue; if(IdFrom(PositionGetString(POSITION_COMMENT))!=id)continue;
      legs++; datetime ot=(datetime)PositionGetInteger(POSITION_TIME); if(ot<oldest)oldest=ot;
      string sym=PositionGetString(POSITION_SYMBOL); if(sym==SymB)lb++; else if(sym==SymA)la++; } }
bool Info(int id,bool &mainMode,double &entryRef,datetime &ot0,double &money){ double bo=0,ao=0; long bt=-1; bool hb=false,ha=false; ot0=0; money=0;
   for(int i=PositionsTotal()-1; i>=0; i--){ ulong tk=PositionGetTicket(i); if(tk==0)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)continue; if(IdFrom(PositionGetString(POSITION_COMMENT))!=id)continue;
      string sym=PositionGetString(POSITION_SYMBOL); double op=PositionGetDouble(POSITION_PRICE_OPEN); long typ=PositionGetInteger(POSITION_TYPE);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME); money+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(ot>ot0)ot0=ot; if(sym==SymB){bo=op;bt=typ;hb=true;} else if(sym==SymA){ao=op;ha=true;} }
   if(!hb||!ha)return(false); mainMode=(bt==POSITION_TYPE_SELL); entryRef=bo-ao; return(true); }
bool CloseId(int id){ bool ok=true;
   for(int i=PositionsTotal()-1;i>=0;i--){ ulong tk=PositionGetTicket(i); if(tk==0)continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Magic)continue; if(IdFrom(PositionGetString(POSITION_COMMENT))!=id)continue;
      if(!trade.PositionClose(tk))ok=false; }
   return(ok); }   // one attempt per call; next timer tick retries if a leg is still open
bool Locked(){ if(ExpiryB<=0)return(false); return(TimeCurrent()>=(ExpiryB-(datetime)CloseBeforeH*3600)); }
//+------------------------------------------------------------------+