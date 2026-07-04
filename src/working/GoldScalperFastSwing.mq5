//+------------------------------------------------------------------+
//|                                         GoldScalperFastSwing.mq5 |
//|                        Copyright 2026, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//---------------------------- INPUTS --------------------------------
input double   LotSize          = 0.01;          // 0 → use RiskPercent
input double   RiskPercent      = 1.0;          // % equity per trade
input int      FastMAPeriod     = 9;
input int      SlowMAPeriod     = 21;
input ENUM_MA_METHOD   MAMethod   = MODE_EMA;
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_CLOSE;
input int      RSI_Period       = 14;
input int      RSI_Overbought   = 70;
input int      RSI_Oversold     = 30;
input int      StopLoss_Points  = 30;
input int      TakeProfit_Points= 60;
input bool     UseTrailingStop  = true;
input int      TrailStart_Points= 20;
input int      TrailStep_Points = 10;
input int      MaxSpread_Points = 10;
input double   BodyThreshold    = 60.0;          // % body of range
input bool     AllowBuy         = true;
input bool     AllowSell        = true;
input int      MagicNumber      = 123456;

//--- Higher‑timeframe swing filter ---------------------------------
input ENUM_TIMEFRAMES HigherTF = PERIOD_H1;
input int      HigherTF_Fast  = 50;
input int      HigherTF_Slow  = 100;
input bool     UseHigherTF   = true;

//---------------------------- GLOBALS -------------------------------
int   fastMA_handle, slowMA_handle, rsi_handle;
int   htFast_handle, htSlow_handle;   // higher‑TF MAs

double fastMA_buf[];
double slowMA_buf[];
double rsi_buf[];
double htFast_buf[];
double htSlow_buf[];

// static caches (updated only on bar close)
static datetime   last_bar_time=0;
static double     fast_prev, slow_prev, rsi_prev;
static double     htFast_prev, htSlow_prev;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1‑minute indicators
   fastMA_handle = iMA(_Symbol,_Period,FastMAPeriod,0,MAMethod,AppliedPrice);
   slowMA_handle = iMA(_Symbol,_Period,SlowMAPeriod,0,MAMethod,AppliedPrice);
   rsi_handle    = iRSI(_Symbol,_Period,RSI_Period,AppliedPrice);
   if(fastMA_handle==INVALID_HANDLE || slowMA_handle==INVALID_HANDLE ||
      rsi_handle==INVALID_HANDLE) return(INIT_FAILED);

   // Higher‑timeframe indicators (if filter enabled)
   if(UseHigherTF)
   {
      htFast_handle = iMA(_Symbol,HigherTF,HigherTF_Fast,0,MODE_EMA,AppliedPrice);
      htSlow_handle = iMA(_Symbol,HigherTF,HigherTF_Slow,0,MODE_EMA,AppliedPrice);
      if(htFast_handle==INVALID_HANDLE || htSlow_handle==INVALID_HANDLE)
         return(INIT_FAILED);
   }

   // set as series so index 0 = latest bar
   ArraySetAsSeries(fastMA_buf,true);
   ArraySetAsSeries(slowMA_buf,true);
   ArraySetAsSeries(rsi_buf,true);
   if(UseHigherTF){ ArraySetAsSeries(htFast_buf,true); ArraySetAsSeries(htSlow_buf,true); }

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(fastMA_handle);
   IndicatorRelease(slowMA_handle);
   IndicatorRelease(rsi_handle);
   if(UseHigherTF){ IndicatorRelease(htFast_handle); IndicatorRelease(htSlow_handle); }
  }
//+------------------------------------------------------------------+
//| Helper: lot size from risk%                                      |
//+------------------------------------------------------------------+
double CalcLotSize()
  {
   if(LotSize>0) return LotSize;
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);   // fixed
   double riskAmt  = equity * RiskPercent/100.0;
   double pointVal = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double slInPrice= StopLoss_Points * pointVal;
   if(slInPrice<=0) return 0.01;
   return MathMax(0.01, riskAmt/slInPrice);
  }
//+------------------------------------------------------------------+
//| Helper: candle‑strength test (body % of range)                  |
//+------------------------------------------------------------------+
bool IsStrongCandle(bool bullishReq)
  {
   MqlRates rt[];                              // fixed: MqlRates (plural)
   if(CopyRates(_Symbol,_Period,1,1,rt)<=0) return(false);
   double o=rt[0].open, h=rt[0].high, l=rt[0].low, c=rt[0].close;
   double rng=h-l;
   if(rng<=0) return(false);
   double body=MathAbs(c-o);
   double bodyPct=body/rng*100.0;
   bool bullish=c>o, bearish=c<o;
   return(bullishReq ? (bodyPct>=BodyThreshold && bullish)
                     : (bodyPct>=BodyThreshold && bearish));
  }
//+------------------------------------------------------------------+
//| Expert tick – only on new bar                                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime cur=iTime(_Symbol,_Period,0);
   if(cur==last_bar_time) return;          // same bar → skip
   last_bar_time=cur;
   Print("=== New bar detected ===");

   //--- spread filter (using SymbolInfoDouble with explicit enum cast)
   double spread = SymbolInfoDouble(_Symbol, (ENUM_SYMBOL_INFO_DOUBLE)SYMBOL_SPREAD);
   if(spread>MaxSpread_Points) return;

   //--- copy indicator values once per bar
   if(CopyBuffer(fastMA_handle,0,0,1,fastMA_buf)<=0 ||
      CopyBuffer(slowMA_handle,0,0,1,slowMA_buf)<=0 ||
      CopyBuffer(rsi_handle,0,0,1,rsi_buf)<=0) return;

   fast_prev=fastMA_buf[0]; slow_prev=slowMA_buf[0]; rsi_prev=rsi_buf[0];

   //--- higher‑TF MA values (once per bar)
   if(UseHigherTF)
   {
      if(CopyBuffer(htFast_handle,0,0,1,htFast_buf)<=0 ||
         CopyBuffer(htSlow_handle,0,0,1,htSlow_buf)<=0) return;
      htFast_prev=htFast_buf[0]; htSlow_prev=htSlow_buf[0];
   }

   //--- detect 1‑min EMA crossover
   static bool was_below=false;
   bool now_below=(fast_prev<slow_prev);

   //--- BUY conditions
   if(AllowBuy && !was_below && !now_below && rsi_prev<RSI_Overbought &&
      IsStrongCandle(true))
   {
      bool higherTF_ok=!UseHigherTF || (htFast_prev>htSlow_prev);
      if(higherTF_ok) ExecuteTrade(ORDER_TYPE_BUY);
   }
   //--- SELL conditions
   if(AllowSell && was_below && now_below && rsi_prev>RSI_Oversold &&
      IsStrongCandle(false))
   {
      bool higherTF_ok=!UseHigherTF || (htFast_prev<htSlow_prev);
      if(higherTF_ok) ExecuteTrade(ORDER_TYPE_SELL);
   }

   was_below=now_below;

   //--- optional trailing‑stop (run each tick – cheap)
   if(UseTrailingStop) ManageTrailingStop();
  }
//+------------------------------------------------------------------+
//| Send market order                                                |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
  {
   double lot=CalcLotSize();
   if(lot<0.01) lot=0.01;

   MqlTradeRequest  req;
   MqlTradeResult   res;
   ZeroMemory(req); ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.type     = type;
   req.price    = (type==ORDER_TYPE_BUY) ?
                  SymbolInfoDouble(_Symbol,SYMBOL_ASK) :
                  SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.sl       = (type==ORDER_TYPE_BUY) ?
                  req.price - StopLoss_Points*_Point :
                  req.price + StopLoss_Points*_Point;
   req.tp       = (type==ORDER_TYPE_BUY) ?
                  req.price + TakeProfit_Points*_Point :
                  req.price - TakeProfit_Points*_Point;
   req.deviation=5;
   req.magic    =MagicNumber;
   req.comment  ="GoldScalperFastSwing";
   req.type_time=ORDER_TIME_GTC;
   req.type_filling=ORDER_FILLING_IOC;

   if(!OrderSend(req,res))
   {
      Print("OrderSend failed, error ",GetLastError());
      return;
   }
   if(res.retcode!=TRADE_RETCODE_DONE)
   {
      Print("Trade failed. retcode=",res.retcode," comment=",res.comment);
   }
   else
   {
      PrintFormat("Trade opened: ticket=%I64u  %s %.2f lots SL=%d TP=%d",
                  res.order,
                  (type==ORDER_TYPE_BUY?"BUY":"SELL"),
                  lot,
                  StopLoss_Points,
                  TakeProfit_Points);
   }
  }
//+------------------------------------------------------------------+
//| Simple trailing‑stop manager                                     |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ?
                        SymbolInfoDouble(_Symbol,SYMBOL_BID) :
                        SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double profitPts=(curPrice-openPrice)/_Point;

      if(profitPts>=TrailStart_Points)
      {
         double newSL = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ?
                        curPrice - TrailStep_Points*_Point :
                        curPrice + TrailStep_Points*_Point;
         double curSL = PositionGetDouble(POSITION_SL);
         if((PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY && newSL>curSL) ||
            (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL && newSL<curSL))
         {
            MqlTradeRequest  req;
            MqlTradeResult   res;
            ZeroMemory(req); ZeroMemory(res);
            req.action   = TRADE_ACTION_SLTP;
            req.position = ticket;
            req.sl       = newSL;
            req.tp       = PositionGetDouble(POSITION_TP);
            req.deviation=5;
            req.magic    =MagicNumber;
            if(!OrderSend(req,res))
               Print("Trailing SL modify failed, error ",GetLastError());
         }
      }
   }
  }
//+------------------------------------------------------------------+
