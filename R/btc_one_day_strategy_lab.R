# BTC one-day volatility forecast strategy lab
# Uses the 1-day HARQ + Realized-GARCH RV forecasts from this project.
# All signals at t are formed from information available through t and applied to t->t+1 BTC returns.
#
# Strategies:
# BUY_HOLD, TREND, EWMA_VOL_TARGET, MODEL_VOL_TARGET, RAW_FORECAST_Z,
# MODEL_MINUS_EWMA_Z, VOL_CHANGE_Z, MODEL_DISAGREEMENT,
# ERROR_ADJUSTED_VOL_TARGET, COMPRESSION_BREAKOUT, VOL_STATE_MACHINE,
# TREND_EWMA, TREND_MODEL_VOL, TREND_X_VOL_Z, TREND_X_VOL_Z_X_CHANGE.
#
# Optional VRP diagnostic:
# create results/btc_options_iv.csv with columns date, iv_ann (decimal annualized IV).
# This creates a model-vs-IV signal only; it does not fake an options P&L without option returns/bid-ask data.

cfg <- list(
  forecast_file="results/btc_rv_horserace/forecasts.csv",
  realized_file="results/btc_rv_horserace/daily_realized_measures.csv",
  price_cache="cache/binance_raw/BTCUSDT_5m.rds",
  options_iv_file="results/btc_options_iv.csv",
  output_dir="results/btc_strategy_lab",
  annualization=365,
  ensemble_rg_weight=.50,
  ensemble_harq_weight=.50,
  target_vol=.20,
  min_weight=0,
  max_weight=1.5,
  ewma_lambda=.94,
  z_window=90L,
  z_min_obs=45L,
  z_clip=4,
  z_base_weight=1,
  z_level_k=.25,
  z_delta_k=.25,
  disagreement_k=.35,
  error_window=5L,
  error_lambda=.50,
  trend_fast=20L,
  trend_slow=100L,
  momentum_days=20L,
  breakout_days=20L,
  bb_window=20L,
  bb_sd=2,
  compression_z_threshold=-.50,
  breakout_exit_vol_z=1.0,
  state_low_falling=1.25,
  state_low_rising=.90,
  state_high_falling=.80,
  state_high_rising=.35,
  main_cost_bps=10,
  cost_grid_bps=c(0,2,5,10,25,50),
  common_vol_target=.20
)

dir.create(cfg$output_dir, recursive=TRUE, showWarnings=FALSE)

pkgs <- c("dplyr","tidyr","readr","ggplot2","scales","zoo")
miss <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly=TRUE)]
if(length(miss)) install.packages(miss, repos="https://cloud.r-project.org")
miss <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly=TRUE)]
if(length(miss)) stop("Missing packages: ", paste(miss, collapse=", "))

clip <- function(x,lo,hi) pmin(pmax(x,lo),hi)

lagged_z <- function(x, window=90L, min_obs=45L) {
  out <- rep(NA_real_, length(x))
  for(i in seq_along(x)) {
    j <- i-1L
    if(j < 1L) next
    h <- x[max(1L,j-window+1L):j]
    h <- h[is.finite(h)]
    if(length(h) < min_obs || !is.finite(x[i])) next
    s <- stats::sd(h)
    if(is.finite(s) && s > 0) out[i] <- (x[i]-mean(h))/s
  }
  out
}

lagged_mean <- function(x, window=5L, min_obs=3L) {
  out <- rep(NA_real_, length(x))
  for(i in seq_along(x)) {
    j <- i-1L
    if(j < 1L) next
    h <- x[max(1L,j-window+1L):j]
    h <- h[is.finite(h)]
    if(length(h) >= min_obs) out[i] <- mean(h)
  }
  out
}

lagged_max <- function(x, window=20L) {
  out <- rep(NA_real_, length(x))
  for(i in seq_along(x)) {
    j <- i-1L
    if(j < window) next
    h <- x[(j-window+1L):j]
    if(all(is.finite(h))) out[i] <- max(h)
  }
  out
}

max_dd <- function(r) {
  w <- cumprod(1 + ifelse(is.finite(r),r,0))
  min(w/cummax(w)-1, na.rm=TRUE)
}

cvar95 <- function(r) {
  r <- r[is.finite(r)]
  q <- stats::quantile(r,.05,names=FALSE,type=8)
  mean(r[r<=q])
}

metrics <- function(r, turn, w, ann=365) {
  ok <- is.finite(r)
  r <- r[ok]; turn <- turn[ok]; w <- w[ok]
  if(length(r)<2) return(data.frame())
  wealth <- prod(1+r)
  cagr <- wealth^(ann/length(r))-1
  am <- mean(r)*ann
  av <- stats::sd(r)*sqrt(ann)
  dsd <- sqrt(mean(pmin(r,0)^2))*sqrt(ann)
  mdd <- max_dd(r)
  data.frame(
    n=length(r),
    total_return=wealth-1,
    CAGR=cagr,
    ann_mean=am,
    ann_vol=av,
    Sharpe=ifelse(av>0,am/av,NA_real_),
    Sortino=ifelse(dsd>0,am/dsd,NA_real_),
    max_drawdown=mdd,
    Calmar=ifelse(mdd<0,cagr/abs(mdd),NA_real_),
    CVaR_95=cvar95(r),
    annual_turnover=sum(turn,na.rm=TRUE)*ann/length(r),
    total_turnover=sum(turn,na.rm=TRUE),
    avg_weight=mean(w,na.rm=TRUE),
    median_weight=stats::median(w,na.rm=TRUE),
    p10_weight=stats::quantile(w,.10,names=FALSE,na.rm=TRUE),
    p90_weight=stats::quantile(w,.90,names=FALSE,na.rm=TRUE)
  )
}

# Self-financing turnover against passively drifted risky weight.
run_strategy <- function(target_w, risky_r, cost_bps=10) {
  n <- length(target_w)
  gross <- net <- turn <- prew <- rep(NA_real_,n)
  prev_w <- 0
  prev_r <- 0
  for(i in seq_len(n)) {
    if(i==1L) {
      pw <- 0
    } else {
      den <- 1 + prev_w*prev_r
      pw <- ifelse(is.finite(den) && abs(den)>1e-12,
                   prev_w*(1+prev_r)/den, prev_w)
    }
    tw <- ifelse(is.finite(target_w[i]), target_w[i], 0)
    rr <- ifelse(is.finite(risky_r[i]), risky_r[i], 0)
    tr <- abs(tw-pw)
    gross[i] <- tw*rr
    net[i] <- gross[i] - cost_bps/10000*tr
    turn[i] <- tr
    prew[i] <- pw
    prev_w <- tw
    prev_r <- rr
  }
  data.frame(weight=target_w, pretrade_weight=prew, turnover=turn,
             gross_return=gross, net_return=net)
}

# ------------------------- Forecasts -------------------------

if(!file.exists(cfg$forecast_file)) stop("Run btc_binance_realized_vol_horserace.R first.")
fc <- readr::read_csv(cfg$forecast_file, show_col_types=FALSE)
req <- c("origin_date","horizon","model","forecast_rv")
if(length(setdiff(req,names(fc)))) stop("forecasts.csv missing required columns.")
fc$origin_date <- as.Date(fc$origin_date)
fc <- fc |> dplyr::filter(horizon==1, is.finite(forecast_rv))

rg <- fc |> dplyr::filter(model=="REALGARCH") |>
  dplyr::select(origin_date, rv_rg=forecast_rv)
hq <- fc |> dplyr::filter(model=="HARQ") |>
  dplyr::select(origin_date, rv_harq=forecast_rv)

model_fc <- dplyr::inner_join(rg,hq,by="origin_date") |>
  dplyr::mutate(
    rv_model=cfg$ensemble_rg_weight*rv_rg +
             cfg$ensemble_harq_weight*rv_harq
  )

# ------------------------- Realized RV -------------------------

if(file.exists(cfg$realized_file)) {
  rv <- readr::read_csv(cfg$realized_file, show_col_types=FALSE)
  rv$date <- as.Date(rv$date)
  rv <- rv |> dplyr::select(date, rv_actual=RV)
} else {
  rv <- NULL
}

# ------------------------- BTC daily close -------------------------

if(!file.exists(cfg$price_cache)) stop("Missing ",cfg$price_cache)
x <- as.data.frame(readRDS(cfg$price_cache))
x$close <- as.numeric(x$close)

if("open_time_ms" %in% names(x)) {
  z <- as.numeric(x$open_time_ms)
  z <- ifelse(abs(z)>=1e14,z/1000,z)
  x$datetime <- as.POSIXct(z/1000, origin="1970-01-01", tz="UTC")
} else if("datetime" %in% names(x)) {
  x$datetime <- as.POSIXct(x$datetime,tz="UTC")
} else stop("Could not identify time column in price cache.")

x <- x[is.finite(x$close) & !is.na(x$datetime),]
x$date <- as.Date(x$datetime,tz="UTC")
x <- x[order(x$datetime),]

px <- x |> dplyr::group_by(date) |>
  dplyr::summarise(close=dplyr::last(close),.groups="drop") |>
  dplyr::arrange(date) |>
  dplyr::mutate(
    btc_close_return=close/dplyr::lag(close)-1,
    btc_log_return=log(close/dplyr::lag(close)),
    sma_fast=zoo::rollmean(close,cfg$trend_fast,fill=NA,align="right"),
    sma_slow=zoo::rollmean(close,cfg$trend_slow,fill=NA,align="right"),
    momentum=close/dplyr::lag(close,cfg$momentum_days)-1,
    trend_flag=as.numeric(close>sma_slow & momentum>0),
    bb_mid=zoo::rollmean(close,cfg$bb_window,fill=NA,align="right"),
    bb_sd=zoo::rollapply(close,cfg$bb_window,stats::sd,fill=NA,align="right"),
    bb_upper=bb_mid+cfg$bb_sd*bb_sd,
    bb_lower=bb_mid-cfg$bb_sd*bb_sd,
    bb_width=(bb_upper-bb_lower)/bb_mid
  )

px$prior_breakout_high <- lagged_max(px$close,cfg$breakout_days)
px$bb_width_z <- lagged_z(px$bb_width,cfg$z_window,cfg$z_min_obs)

if(!is.null(rv)) {
  px <- dplyr::left_join(px,rv,by="date")
} else {
  px$rv_actual <- 10000*px$btc_log_return^2
}

# EWMA RV benchmark: at t, forecast t+1 from information through t.
ew <- rep(NA_real_,nrow(px))
first <- which(is.finite(px$rv_actual))
if(length(first)<60) stop("Too little realized RV history.")
j0 <- first[60]
ew[j0] <- mean(px$rv_actual[first[1:60]],na.rm=TRUE)
if(j0<nrow(px)) for(i in (j0+1L):nrow(px)) {
  if(is.finite(px$rv_actual[i-1]) && is.finite(ew[i-1])) {
    ew[i] <- cfg$ewma_lambda*ew[i-1] + (1-cfg$ewma_lambda)*px$rv_actual[i-1]
  } else ew[i] <- ew[i-1]
}
px$ewma_rv <- ew

# ------------------------- Align t -> t+1 -------------------------

dates <- px$date
lookup <- data.frame(origin_date=head(dates,-1), target_date=tail(dates,-1))

origin <- px |> dplyr::rename(origin_date=date, price_t=close, rv_t=rv_actual) |>
  dplyr::select(origin_date,price_t,rv_t,ewma_rv,sma_fast,sma_slow,momentum,
                trend_flag,bb_width,bb_width_z,prior_breakout_high)

target <- px |> dplyr::rename(target_date=date, price_t1=close, btc_return=btc_close_return) |>
  dplyr::select(target_date,price_t1,btc_return)

dat <- model_fc |> dplyr::inner_join(lookup,by="origin_date") |>
  dplyr::inner_join(origin,by="origin_date") |>
  dplyr::inner_join(target,by="target_date") |>
  dplyr::arrange(origin_date) |>
  dplyr::mutate(
    model_vol_ann=sqrt(pmax(rv_model,0))/100*sqrt(cfg$annualization),
    rg_vol_ann=sqrt(pmax(rv_rg,0))/100*sqrt(cfg$annualization),
    harq_vol_ann=sqrt(pmax(rv_harq,0))/100*sqrt(cfg$annualization),
    ewma_vol_ann=sqrt(pmax(ewma_rv,0))/100*sqrt(cfg$annualization),
    model_minus_ewma=model_vol_ann-ewma_vol_ann,
    disagreement=abs(rg_vol_ann-harq_vol_ann),
    model_vol_change=model_vol_ann-dplyr::lag(model_vol_ann)
  )

dat$model_vol_z <- clip(lagged_z(dat$model_vol_ann,cfg$z_window,cfg$z_min_obs),-cfg$z_clip,cfg$z_clip)
dat$model_minus_ewma_z <- clip(lagged_z(dat$model_minus_ewma,cfg$z_window,cfg$z_min_obs),-cfg$z_clip,cfg$z_clip)
dat$model_vol_change_z <- clip(lagged_z(dat$model_vol_change,cfg$z_window,cfg$z_min_obs),-cfg$z_clip,cfg$z_clip)
dat$disagreement_z <- clip(lagged_z(dat$disagreement,cfg$z_window,cfg$z_min_obs),-cfg$z_clip,cfg$z_clip)

# Forecast error known at t = RV_t - forecast formed at t-1 for t.
dat$forecast_error_current <- dat$rv_t - dplyr::lag(dat$rv_model)
dat$error_mean <- lagged_mean(dat$forecast_error_current,cfg$error_window,3L)
dat$rv_model_adj <- pmax(dat$rv_model + cfg$error_lambda*dat$error_mean,1e-10)
dat$error_adj_vol_ann <- sqrt(dat$rv_model_adj)/100*sqrt(cfg$annualization)

# ------------------------- Strategy weights -------------------------

dat$w_BUY_HOLD <- 1
dat$w_TREND <- dat$trend_flag
dat$w_EWMA_VOL_TARGET <- clip(cfg$target_vol/dat$ewma_vol_ann,cfg$min_weight,cfg$max_weight)
dat$w_MODEL_VOL_TARGET <- clip(cfg$target_vol/dat$model_vol_ann,cfg$min_weight,cfg$max_weight)
dat$w_RAW_FORECAST_Z <- clip(cfg$z_base_weight-cfg$z_level_k*dat$model_vol_z,cfg$min_weight,cfg$max_weight)
dat$w_MODEL_MINUS_EWMA_Z <- clip(cfg$z_base_weight-cfg$z_level_k*dat$model_minus_ewma_z,cfg$min_weight,cfg$max_weight)
dat$w_VOL_CHANGE_Z <- clip(cfg$z_base_weight-cfg$z_delta_k*dat$model_vol_change_z,cfg$min_weight,cfg$max_weight)
dat$w_MODEL_DISAGREEMENT <- clip(cfg$z_base_weight-cfg$disagreement_k*pmax(dat$disagreement_z,0),cfg$min_weight,cfg$max_weight)
dat$w_ERROR_ADJUSTED_VOL_TARGET <- clip(cfg$target_vol/dat$error_adj_vol_ann,cfg$min_weight,cfg$max_weight)

# Stateful compression -> upside breakout.
pos <- 0
wb <- rep(0,nrow(dat))
for(i in seq_len(nrow(dat))) {
  compression <- is.finite(dat$model_vol_z[i]) && is.finite(dat$bb_width_z[i]) &&
    dat$model_vol_z[i]<=cfg$compression_z_threshold &&
    dat$bb_width_z[i]<=cfg$compression_z_threshold
  breakout <- is.finite(dat$prior_breakout_high[i]) &&
    dat$price_t[i] > dat$prior_breakout_high[i]
  exit_rule <- (is.finite(dat$sma_fast[i]) && dat$price_t[i]<dat$sma_fast[i]) ||
    (is.finite(dat$model_vol_z[i]) && dat$model_vol_z[i]>cfg$breakout_exit_vol_z)
  if(pos==0 && compression && breakout) pos <- 1
  else if(pos==1 && exit_rule) pos <- 0
  wb[i] <- pos
}
dat$w_COMPRESSION_BREAKOUT <- wb

dat$vol_state <- dplyr::case_when(
  dat$model_vol_z<=0 & dat$model_vol_change<=0 ~ "LOW_FALLING",
  dat$model_vol_z<=0 & dat$model_vol_change>0  ~ "LOW_RISING",
  dat$model_vol_z>0  & dat$model_vol_change<=0 ~ "HIGH_FALLING",
  dat$model_vol_z>0  & dat$model_vol_change>0 ~ "HIGH_RISING",
  TRUE ~ NA_character_
)

dat$w_VOL_STATE_MACHINE <- dplyr::case_when(
  dat$vol_state=="LOW_FALLING" ~ cfg$state_low_falling,
  dat$vol_state=="LOW_RISING" ~ cfg$state_low_rising,
  dat$vol_state=="HIGH_FALLING" ~ cfg$state_high_falling,
  dat$vol_state=="HIGH_RISING" ~ cfg$state_high_rising,
  TRUE ~ 0
)
dat$w_VOL_STATE_MACHINE <- clip(dat$w_VOL_STATE_MACHINE,cfg$min_weight,cfg$max_weight)

dat$w_TREND_EWMA <- dat$trend_flag*dat$w_EWMA_VOL_TARGET
dat$w_TREND_MODEL_VOL <- dat$trend_flag*dat$w_MODEL_VOL_TARGET
dat$w_TREND_X_VOL_Z <- dat$trend_flag*clip(
  cfg$z_base_weight-cfg$z_level_k*dat$model_vol_z,cfg$min_weight,cfg$max_weight)
dat$w_TREND_X_VOL_Z_X_CHANGE <- dat$trend_flag*clip(
  cfg$z_base_weight-cfg$z_level_k*dat$model_vol_z-cfg$z_delta_k*dat$model_vol_change_z,
  cfg$min_weight,cfg$max_weight)

strategy_map <- c(
  BUY_HOLD="w_BUY_HOLD",
  TREND="w_TREND",
  EWMA_VOL_TARGET="w_EWMA_VOL_TARGET",
  MODEL_VOL_TARGET="w_MODEL_VOL_TARGET",
  RAW_FORECAST_Z="w_RAW_FORECAST_Z",
  MODEL_MINUS_EWMA_Z="w_MODEL_MINUS_EWMA_Z",
  VOL_CHANGE_Z="w_VOL_CHANGE_Z",
  MODEL_DISAGREEMENT="w_MODEL_DISAGREEMENT",
  ERROR_ADJUSTED_VOL_TARGET="w_ERROR_ADJUSTED_VOL_TARGET",
  COMPRESSION_BREAKOUT="w_COMPRESSION_BREAKOUT",
  VOL_STATE_MACHINE="w_VOL_STATE_MACHINE",
  TREND_EWMA="w_TREND_EWMA",
  TREND_MODEL_VOL="w_TREND_MODEL_VOL",
  TREND_X_VOL_Z="w_TREND_X_VOL_Z",
  TREND_X_VOL_Z_X_CHANGE="w_TREND_X_VOL_Z_X_CHANGE"
)

# Same OOS dates for all strategies.
ok <- is.finite(dat$model_vol_z) & is.finite(dat$model_minus_ewma_z) &
      is.finite(dat$model_vol_change_z) & is.finite(dat$disagreement_z) &
      is.finite(dat$btc_return) & is.finite(dat$model_vol_ann) & is.finite(dat$ewma_vol_ann)
bt <- dat[ok,]
if(nrow(bt)<100) stop("Common strategy sample too small.")

# ------------------------- Main backtest -------------------------

daily_out <- list()
metric_out <- list()

for(s in names(strategy_map)) {
  w <- bt[[strategy_map[[s]]]]
  z <- run_strategy(w,bt$btc_return,cfg$main_cost_bps)
  d <- data.frame(
    origin_date=bt$origin_date,
    target_date=bt$target_date,
    strategy=s,
    btc_return=bt$btc_return,
    weight=z$weight,
    pretrade_weight=z$pretrade_weight,
    turnover=z$turnover,
    gross_return=z$gross_return,
    net_return=z$net_return
  )
  d$equity_net <- cumprod(1+d$net_return)
  d$drawdown_net <- d$equity_net/cummax(d$equity_net)-1
  daily_out[[s]] <- d
  m <- metrics(d$net_return,d$turnover,d$weight,cfg$annualization)
  m$strategy <- s
  metric_out[[s]] <- m
}

strategy_daily <- dplyr::bind_rows(daily_out)
strategy_metrics_main <- dplyr::bind_rows(metric_out) |>
  dplyr::select(strategy,dplyr::everything()) |>
  dplyr::arrange(dplyr::desc(Sharpe))

# ------------------------- Cost sensitivity -------------------------

cost_out <- list()
k <- 1L
for(cst in cfg$cost_grid_bps) {
  for(s in names(strategy_map)) {
    z <- run_strategy(bt[[strategy_map[[s]]]],bt$btc_return,cst)
    m <- metrics(z$net_return,z$turnover,z$weight,cfg$annualization)
    m$strategy <- s
    m$cost_bps <- cst
    cost_out[[k]] <- m
    k <- k+1L
  }
}
cost_sensitivity <- dplyr::bind_rows(cost_out) |>
  dplyr::select(strategy,cost_bps,dplyr::everything())

# ------------------------- Common-vol diagnostic -------------------------

cv_out <- list()
for(s in unique(strategy_daily$strategy)) {
  d <- dplyr::filter(strategy_daily,strategy==s)
  av <- stats::sd(d$net_return,na.rm=TRUE)*sqrt(cfg$annualization)
  sf <- ifelse(is.finite(av) && av>0,cfg$common_vol_target/av,NA_real_)
  m <- metrics(d$net_return*sf,d$turnover*sf,d$weight*sf,cfg$annualization)
  m$strategy <- s
  m$common_vol_scale <- sf
  cv_out[[s]] <- m
}
strategy_metrics_common_vol <- dplyr::bind_rows(cv_out) |>
  dplyr::select(strategy,common_vol_scale,dplyr::everything()) |>
  dplyr::arrange(dplyr::desc(Sharpe))

# ------------------------- Diagnostics -------------------------

signal_diagnostics <- data.frame(
  n=nrow(bt),
  start_date=min(bt$origin_date),
  end_date=max(bt$target_date),
  mean_model_ann_vol=mean(bt$model_vol_ann,na.rm=TRUE),
  mean_ewma_ann_vol=mean(bt$ewma_vol_ann,na.rm=TRUE),
  mean_model_minus_ewma=mean(bt$model_minus_ewma,na.rm=TRUE),
  mean_model_disagreement=mean(bt$disagreement,na.rm=TRUE),
  corr_rg_harq=stats::cor(bt$rg_vol_ann,bt$harq_vol_ann,use="complete.obs"),
  corr_modelvol_abs_next_return=stats::cor(bt$model_vol_ann,abs(bt$btc_return),use="complete.obs"),
  corr_modelvol_next_squared_return=stats::cor(bt$model_vol_ann,bt$btc_return^2,use="complete.obs")
)

regime_summary <- bt |> dplyr::filter(!is.na(vol_state)) |>
  dplyr::group_by(vol_state) |>
  dplyr::summarise(
    n=dplyr::n(),
    avg_next_return=mean(btc_return,na.rm=TRUE),
    avg_abs_next_return=mean(abs(btc_return),na.rm=TRUE),
    next_return_vol=stats::sd(btc_return,na.rm=TRUE),
    positive_rate=mean(btc_return>0,na.rm=TRUE),
    avg_model_vol=mean(model_vol_ann,na.rm=TRUE),
    .groups="drop"
  )

# Optional VRP signal only.
if(file.exists(cfg$options_iv_file)) {
  iv <- readr::read_csv(cfg$options_iv_file,show_col_types=FALSE)
  if(all(c("date","iv_ann") %in% names(iv))) {
    iv$date <- as.Date(iv$date)
    vrp <- bt |> dplyr::select(origin_date,model_vol_ann) |>
      dplyr::inner_join(iv |> dplyr::select(date,iv_ann),
                        by=c("origin_date"="date")) |>
      dplyr::mutate(
        iv_minus_model_variance=iv_ann^2-model_vol_ann^2,
        interpretation=ifelse(iv_minus_model_variance>0,
                              "IV richer than model RV",
                              "IV cheaper than model RV")
      )
    readr::write_csv(vrp,file.path(cfg$output_dir,"vrp_signal.csv"))
  }
}

# ------------------------- Save tables -------------------------

readr::write_csv(strategy_daily,file.path(cfg$output_dir,"strategy_daily.csv"))
readr::write_csv(strategy_metrics_main,file.path(cfg$output_dir,"strategy_metrics_main.csv"))
readr::write_csv(strategy_metrics_common_vol,file.path(cfg$output_dir,"strategy_metrics_common_vol.csv"))
readr::write_csv(cost_sensitivity,file.path(cfg$output_dir,"cost_sensitivity.csv"))
readr::write_csv(signal_diagnostics,file.path(cfg$output_dir,"signal_diagnostics.csv"))
readr::write_csv(regime_summary,file.path(cfg$output_dir,"regime_summary.csv"))

# ------------------------- Plots -------------------------

BG <- "#F8F7F3"
theme_lab <- function() ggplot2::theme_minimal(base_size=12) +
  ggplot2::theme(
    plot.background=ggplot2::element_rect(fill=BG,color=NA),
    panel.background=ggplot2::element_rect(fill=BG,color=NA),
    panel.grid.minor=ggplot2::element_blank(),
    legend.position="bottom",
    plot.title=ggplot2::element_text(face="bold",size=16)
  )

focus <- c("BUY_HOLD","EWMA_VOL_TARGET","MODEL_VOL_TARGET",
           "MODEL_MINUS_EWMA_Z","VOL_STATE_MACHINE","TREND",
           "TREND_X_VOL_Z_X_CHANGE")

p1 <- strategy_daily |> dplyr::filter(strategy %in% focus) |>
  ggplot2::ggplot(ggplot2::aes(target_date,equity_net,color=strategy)) +
  ggplot2::geom_line(linewidth=.85) +
  ggplot2::labs(title="BTC strategy horse race",
                subtitle=paste0("Net of ",cfg$main_cost_bps," bp per unit turnover"),
                x=NULL,y="Growth of $1") + theme_lab()
ggplot2::ggsave(
  filename = file.path(cfg$output_dir, "01_equity_curves.png"),
  plot = p1,
  width = 12,
  height = 7,
  dpi = 220,
  bg = BG
)

p2 <- strategy_daily |> dplyr::filter(strategy %in% focus) |>
  ggplot2::ggplot(ggplot2::aes(target_date,drawdown_net,color=strategy)) +
  ggplot2::geom_line(linewidth=.8) +
  ggplot2::scale_y_continuous(labels=scales::label_percent()) +
  ggplot2::labs(title="Drawdown comparison",x=NULL,y="Drawdown") + theme_lab()
ggplot2::ggsave(
  filename = file.path(cfg$output_dir, "02_drawdowns.png"),
  plot = p2,
  width = 12,
  height = 7,
  dpi = 220,
  bg = BG
)

p3 <- strategy_daily |> dplyr::filter(strategy %in%
  c("EWMA_VOL_TARGET","MODEL_VOL_TARGET","MODEL_MINUS_EWMA_Z",
    "VOL_STATE_MACHINE","TREND_X_VOL_Z_X_CHANGE")) |>
  ggplot2::ggplot(ggplot2::aes(origin_date,weight,color=strategy)) +
  ggplot2::geom_line(linewidth=.7) +
  ggplot2::labs(title="BTC target weights",x=NULL,y="Weight") + theme_lab()
ggplot2::ggsave(
  filename = file.path(cfg$output_dir, "03_weights.png"),
  plot = p3,
  width = 12,
  height = 7,
  dpi = 220,
  bg = BG
)

zs <- bt |> dplyr::select(origin_date,model_vol_z,model_minus_ewma_z,
                          model_vol_change_z,disagreement_z) |>
  tidyr::pivot_longer(-origin_date,names_to="signal",values_to="z")
p4 <- ggplot2::ggplot(zs,ggplot2::aes(origin_date,z,color=signal)) +
  ggplot2::geom_hline(yintercept=0,color="grey70") +
  ggplot2::geom_line(linewidth=.7) +
  ggplot2::labs(title="Point-in-time volatility signals",x=NULL,y="Lagged rolling z-score") +
  theme_lab()
ggplot2::ggsave(
  filename = file.path(cfg$output_dir, "04_signal_zscores.png"),
  plot = p4,
  width = 12,
  height = 7,
  dpi = 220,
  bg = BG
)

p5 <- ggplot2::ggplot(strategy_metrics_main,
                      ggplot2::aes(ann_vol,CAGR,label=strategy)) +
  ggplot2::geom_point(size=3) +
  ggplot2::geom_text(nudge_y=.012,size=3,check_overlap=TRUE) +
  ggplot2::scale_x_continuous(labels=scales::label_percent()) +
  ggplot2::scale_y_continuous(labels=scales::label_percent()) +
  ggplot2::labs(title="Risk-return map",x="Annualized volatility",y="CAGR") +
  theme_lab() + ggplot2::theme(legend.position="none")
ggplot2::ggsave(
  filename = file.path(cfg$output_dir, "05_risk_return.png"),
  plot = p5,
  width = 11,
  height = 7,
  dpi = 220,
  bg = BG
)

cvp <- strategy_metrics_common_vol |> dplyr::arrange(Sharpe)
cvp$strategy <- factor(cvp$strategy,levels=cvp$strategy)
p6 <- ggplot2::ggplot(cvp,ggplot2::aes(Sharpe,strategy)) +
  ggplot2::geom_segment(ggplot2::aes(x=0,xend=Sharpe,y=strategy,yend=strategy),
                        color="grey65",linewidth=.9) +
  ggplot2::geom_point(size=3,color="#0072B2") +
  ggplot2::labs(title="Common-volatility Sharpe comparison",
                subtitle=paste0("Ex-post scaled to ",scales::percent(cfg$common_vol_target),
                                " annualized volatility; diagnostic only"),
                x="Sharpe",y=NULL) + theme_lab()
ggplot2::ggsave(
  filename = file.path(cfg$output_dir, "06_common_vol_sharpe.png"),
  plot = p6,
  width = 10,
  height = 8,
  dpi = 220,
  bg = BG
)

cat("\nBTC ONE-DAY VOL FORECAST STRATEGY LAB\n")
cat("Sample:",as.character(min(bt$origin_date)),"to",as.character(max(bt$target_date)),
    "| n =",nrow(bt),"\n")
cat("Main costs:",cfg$main_cost_bps,"bp per unit turnover\n\n")
print(strategy_metrics_main |>
        dplyr::select(strategy,CAGR,ann_vol,Sharpe,Sortino,max_drawdown,
                      Calmar,CVaR_95,annual_turnover,avg_weight),
      row.names=FALSE,digits=4)
cat("\nCommon-vol diagnostic:\n")
print(strategy_metrics_common_vol |>
        dplyr::select(strategy,common_vol_scale,CAGR,ann_vol,Sharpe,max_drawdown),
      row.names=FALSE,digits=4)
cat("\nOutputs:",normalizePath(cfg$output_dir,winslash="/",mustWork=FALSE),"\n")
cat("\nDo not choose parameters by maximizing this same OOS sample.\n")
cat("The key comparisons are MODEL vs EWMA and model-scaled TREND vs TREND alone.\n")
