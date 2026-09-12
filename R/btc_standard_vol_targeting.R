# ==============================================================================
# BTC STANDARD VOLATILITY-TARGETING BACKTEST — BINANCE 5m
# HARQ / Realized-GARCH / Ensemble
# ==============================================================================
#
# PURPOSE
# -------
# Turn next-day BTC realized-volatility forecasts into a standard volatility-
# targeting strategy:
#
#     weight_t = target_vol / forecast_vol_{t+1}
#
# with optional leverage cap and transaction costs.
#
# IMPORTANT:
# - Forecasts at date t use information available only through t.
# - Strategy return on t+1 uses weight_t.
# - No future information enters the position.
#
# DATA
# ----
# Binance Spot BTCUSDT 5-minute candles, UTC.
#
# REALIZED VARIANCE
# -----------------
# RV_t = sum_i r_{t,i}^2
#
# REALIZED QUARTICITY
# -------------------
# RQ_t = (M_t / 3) * sum_i r_{t,i}^4
#
# MODELS
# ------
# HARQ, Realized-GARCH, and a 50/50 variance-forecast ensemble.
#
# STRATEGY
# --------
# Example:
#   target annualized vol = 20%
#   forecast annualized vol = 40%
#   weight = 20 / 40 = 0.50
#
# COSTS
# -----
# cost_t = transaction_cost_bps / 10000 * |w_t - w_{t-1}|
#
# Cash return is assumed 0.
#
# ==============================================================================

QUICK_RUN <- FALSE

cfg <- list(
  seed = 12345L,
  symbol = "BTCUSDT",
  interval = "5m",
  start_date = as.Date("2019-01-01"),
  end_date = Sys.Date() - 1L,
  raw_cache = "cache/binance_raw/BTCUSDT_5m.rds",
  rest_base = "https://data-api.binance.vision",
  api_limit = 1000L,
  request_pause = 0.06,
  max_retries = 6L,
  retry_base_seconds = 1.0,
  expected_bars_per_day = 288L,
  min_bars_per_day = 285L,
  drop_incomplete_days = TRUE,

  # "HARQ", "REALGARCH", or "ENSEMBLE"
  forecast_model = "ENSEMBLE",

  test_start = as.Date("2025-01-01"),
  train_window = if (QUICK_RUN) 730L else 1460L,
  har_week = 5L,
  har_month = 22L,
  min_har_rows = 180L,
  harq_range_guard = TRUE,

  annualization_days = 365,
  target_vol_annual = 0.20,
  min_weight = 0.0,
  max_weight = 1.50,
  weight_smoothing = 1.0,
  min_rebalance_change = 0.00,
  transaction_cost_bps = 10.0,

  rv_floor = 1e-10,
  forecast_floor = 1e-10,

  output_dir = "results/btc_vol_targeting"
)

set.seed(cfg$seed)

dir.create(dirname(cfg$raw_cache), recursive = TRUE, showWarnings = FALSE)
dir.create(cfg$output_dir, recursive = TRUE, showWarnings = FALSE)

required_pkgs <- c("curl", "jsonlite", "xts", "rugarch", "ggplot2")

install_if_missing <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0L) {
    install.packages(missing, repos = "https://cloud.r-project.org")
  }
  still_missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(still_missing) > 0L) {
    stop("Missing packages: ", paste(still_missing, collapse = ", "))
  }
}

install_if_missing(required_pkgs)

interval_to_ms <- function(interval) {
  lookup <- c(
    "1m" = 60000,
    "3m" = 180000,
    "5m" = 300000,
    "15m" = 900000,
    "30m" = 1800000,
    "1h" = 3600000
  )
  if (!interval %in% names(lookup)) stop("Unsupported interval: ", interval)
  unname(lookup[[interval]])
}

date_to_ms <- function(x) {
  as.numeric(as.POSIXct(as.Date(x), tz = "UTC")) * 1000
}

empty_klines <- function() {
  data.frame(
    open_time_ms = numeric(), open = numeric(), high = numeric(), low = numeric(),
    close = numeric(), volume = numeric(), close_time_ms = numeric(),
    quote_volume = numeric(), number_of_trades = numeric(),
    taker_buy_base_volume = numeric(), taker_buy_quote_volume = numeric(),
    stringsAsFactors = FALSE
  )
}

standardize_klines <- function(x) {
  if (is.null(x) || length(x) == 0L) return(empty_klines())
  x <- as.data.frame(x, stringsAsFactors = FALSE)
  if (ncol(x) < 11L) stop("Unexpected Binance kline format.")

  open_raw <- suppressWarnings(as.numeric(x[[1L]]))
  close_raw <- suppressWarnings(as.numeric(x[[7L]]))

  open_ms <- ifelse(abs(open_raw) >= 1e14, open_raw / 1000, open_raw)
  close_ms <- ifelse(abs(close_raw) >= 1e14, close_raw / 1000, close_raw)

  out <- data.frame(
    open_time_ms = open_ms,
    open = suppressWarnings(as.numeric(x[[2L]])),
    high = suppressWarnings(as.numeric(x[[3L]])),
    low = suppressWarnings(as.numeric(x[[4L]])),
    close = suppressWarnings(as.numeric(x[[5L]])),
    volume = suppressWarnings(as.numeric(x[[6L]])),
    close_time_ms = close_ms,
    quote_volume = suppressWarnings(as.numeric(x[[8L]])),
    number_of_trades = suppressWarnings(as.numeric(x[[9L]])),
    taker_buy_base_volume = suppressWarnings(as.numeric(x[[10L]])),
    taker_buy_quote_volume = suppressWarnings(as.numeric(x[[11L]])),
    stringsAsFactors = FALSE
  )

  out <- out[
    is.finite(out$open_time_ms) &
      is.finite(out$close) &
      out$close > 0,
    ,
    drop = FALSE
  ]
  rownames(out) <- NULL
  out
}

fetch_binance_rest <- function(symbol, interval, start_ms, end_ms, cfg) {
  if (start_ms > end_ms) return(empty_klines())

  step_ms <- interval_to_ms(interval)
  cursor <- start_ms
  chunks <- list()
  cc <- 1L

  message("Downloading missing Binance candles...")

  while (cursor <= end_ms) {
    url <- paste0(
      cfg$rest_base,
      "/api/v3/klines",
      "?symbol=", symbol,
      "&interval=", interval,
      "&startTime=", sprintf("%.0f", cursor),
      "&endTime=", sprintf("%.0f", end_ms),
      "&limit=", cfg$api_limit
    )

    response <- NULL

    for (attempt in seq_len(cfg$max_retries)) {
      response <- tryCatch(curl::curl_fetch_memory(url), error = function(e) e)

      if (!inherits(response, "error") && response$status_code == 200L) break

      wait <- cfg$retry_base_seconds * 2^(attempt - 1L)
      Sys.sleep(wait)
    }

    if (inherits(response, "error") || is.null(response) || response$status_code != 200L) {
      stop("Binance REST download failed.")
    }

    parsed <- jsonlite::fromJSON(rawToChar(response$content), simplifyVector = TRUE)
    if (length(parsed) == 0L) break

    chunk <- standardize_klines(parsed)
    if (nrow(chunk) == 0L) break

    chunks[[cc]] <- chunk
    cc <- cc + 1L

    last_open <- max(chunk$open_time_ms)
    cursor <- last_open + step_ms

    if (nrow(chunk) < cfg$api_limit) break
    Sys.sleep(cfg$request_pause)
  }

  if (length(chunks) == 0L) return(empty_klines())

  out <- do.call(rbind, chunks)
  out <- out[!duplicated(out$open_time_ms), , drop = FALSE]
  out <- out[order(out$open_time_ms), , drop = FALSE]
  rownames(out) <- NULL
  out
}

load_binance_raw <- function(cfg) {
  requested_start <- cfg$start_date - 1L
  requested_end <- cfg$end_date

  start_ms <- date_to_ms(requested_start)
  end_ms <- date_to_ms(requested_end + 1L) - 1

  cached <- NULL
  if (file.exists(cfg$raw_cache)) {
    cached <- tryCatch(readRDS(cfg$raw_cache), error = function(e) NULL)
  }

  step_ms <- interval_to_ms(cfg$interval)
  pieces <- list()
  pp <- 1L

  if (!is.null(cached) && nrow(cached) > 0L) {
    cached <- standardize_klines(cached)
    pieces[[pp]] <- cached
    pp <- pp + 1L

    cache_min <- min(cached$open_time_ms)
    cache_max <- max(cached$open_time_ms)

    if (cache_min > start_ms) {
      left <- fetch_binance_rest(
        cfg$symbol, cfg$interval, start_ms, cache_min - step_ms, cfg
      )
      if (nrow(left) > 0L) {
        pieces[[pp]] <- left
        pp <- pp + 1L
      }
    }

    if (cache_max < end_ms - step_ms) {
      right <- fetch_binance_rest(
        cfg$symbol, cfg$interval, cache_max + step_ms, end_ms, cfg
      )
      if (nrow(right) > 0L) pieces[[pp]] <- right
    }
  } else {
    pieces[[1L]] <- fetch_binance_rest(
      cfg$symbol, cfg$interval, start_ms, end_ms, cfg
    )
  }

  raw <- do.call(rbind, pieces)
  raw <- raw[!duplicated(raw$open_time_ms), , drop = FALSE]
  raw <- raw[order(raw$open_time_ms), , drop = FALSE]

  saveRDS(raw, cfg$raw_cache)
  raw
}

build_daily_measures <- function(raw, cfg) {
  raw$datetime <- as.POSIXct(
    raw$open_time_ms / 1000,
    origin = "1970-01-01",
    tz = "UTC"
  )

  raw <- raw[!is.na(raw$datetime), , drop = FALSE]
  raw <- raw[order(raw$datetime), , drop = FALSE]
  raw <- raw[!duplicated(raw$datetime), , drop = FALSE]

  raw$r5_pct <- c(NA_real_, 100 * diff(log(raw$close)))
  raw$date <- as.Date(raw$datetime, tz = "UTC")

  split_idx <- split(seq_len(nrow(raw)), raw$date)

  daily_list <- lapply(
    split_idx,
    function(ii) {
      rr <- raw$r5_pct[ii]
      rr <- rr[is.finite(rr)]

      m <- length(rr)
      n_bars <- length(ii)

      if (m < cfg$min_bars_per_day - 1L) {
        return(
          data.frame(
            date = raw$date[ii[length(ii)]],
            close = raw$close[ii[length(ii)]],
            n_bars = n_bars,
            RV = NA_real_,
            RQ = NA_real_,
            stringsAsFactors = FALSE
          )
        )
      }

      rv <- sum(rr^2)
      rq <- (m / 3) * sum(rr^4)

      data.frame(
        date = raw$date[ii[length(ii)]],
        close = raw$close[ii[length(ii)]],
        n_bars = n_bars,
        RV = rv,
        RQ = rq,
        stringsAsFactors = FALSE
      )
    }
  )

  out <- do.call(rbind, daily_list)

  out <- out[
    out$date >= cfg$start_date &
      out$date <= cfg$end_date,
    ,
    drop = FALSE
  ]

  out$complete_day <- out$n_bars >= cfg$expected_bars_per_day

  if (cfg$drop_incomplete_days) {
    out <- out[out$complete_day, , drop = FALSE]
  }

  out <- out[is.finite(out$RV) & is.finite(out$RQ), , drop = FALSE]

  out$RV <- pmax(out$RV, cfg$rv_floor)
  out$RQ <- pmax(out$RQ, cfg$rv_floor^2)

  out$ret_pct <- c(NA_real_, 100 * diff(log(out$close)))

  out <- out[is.finite(out$ret_pct), , drop = FALSE]

  rownames(out) <- NULL
  out$index <- seq_len(nrow(out))
  out
}

build_harq_frame <- function(RV, RQ, week, month) {
  n <- length(RV)
  if (n <= month + 1L) return(NULL)

  origins <- month:(n - 1L)

  rows <- lapply(
    origins,
    function(s) {
      rv_d <- RV[s]
      rv_w <- mean(RV[(s - week + 1L):s])
      rv_m <- mean(RV[(s - month + 1L):s])
      rq_d <- RQ[s]

      data.frame(
        y = RV[s + 1L],
        rv_d = rv_d,
        rv_w = rv_w,
        rv_m = rv_m,
        qint_d = sqrt(rq_d) * rv_d,
        stringsAsFactors = FALSE
      )
    }
  )

  do.call(rbind, rows)
}

forecast_harq <- function(RV, RQ, cfg) {
  df <- build_harq_frame(RV, RQ, cfg$har_week, cfg$har_month)

  if (is.null(df) || nrow(df) < cfg$min_har_rows) {
    return(list(forecast = NA_real_, raw = NA_real_, guarded = NA))
  }

  fit <- tryCatch(
    stats::lm(y ~ rv_d + qint_d + rv_w + rv_m, data = df),
    error = function(e) NULL
  )

  if (is.null(fit)) {
    return(list(forecast = NA_real_, raw = NA_real_, guarded = NA))
  }

  n <- length(RV)

  cur <- data.frame(
    rv_d = RV[n],
    rv_w = mean(tail(RV, cfg$har_week)),
    rv_m = mean(tail(RV, cfg$har_month)),
    qint_d = sqrt(RQ[n]) * RV[n]
  )

  raw <- tryCatch(
    as.numeric(stats::predict(fit, newdata = cur)),
    error = function(e) NA_real_
  )

  if (!is.finite(raw)) {
    return(list(forecast = NA_real_, raw = raw, guarded = NA))
  }

  guarded <- FALSE
  pred <- raw

  if (cfg$harq_range_guard) {
    lo <- min(df$y, na.rm = TRUE)
    hi <- max(df$y, na.rm = TRUE)

    if (pred <= 0 || pred < lo || pred > hi) {
      pred <- mean(df$y, na.rm = TRUE)
      guarded <- TRUE
    }
  }

  pred <- pmax(pred, cfg$forecast_floor)

  list(
    forecast = pred,
    raw = raw,
    guarded = guarded
  )
}

forecast_realgarch_1d <- function(ret_pct, RV, dates, cfg) {
  ok <- is.finite(ret_pct) & is.finite(RV) & RV > 0

  r <- ret_pct[ok]
  rv <- RV[ok]
  d <- as.Date(dates[ok])

  if (length(r) < 250L) {
    return(
      list(
        forecast = NA_real_,
        convergence = NA_integer_,
        used_realized_forecast = FALSE
      )
    )
  }

  ret_xts <- xts::xts(r, order.by = d)
  realized_vol_xts <- xts::xts(sqrt(rv), order.by = d)

  spec <- rugarch::ugarchspec(
    variance.model = list(model = "realGARCH", garchOrder = c(1L, 1L)),
    mean.model = list(armaOrder = c(0L, 0L), include.mean = TRUE),
    distribution.model = "std"
  )

  fit <- tryCatch(
    suppressWarnings(
      rugarch::ugarchfit(
        spec = spec,
        data = ret_xts,
        realizedVol = realized_vol_xts,
        solver = "hybrid",
        solver.control = list(trace = 0)
      )
    ),
    error = function(e) NULL
  )

  if (is.null(fit)) {
    return(
      list(
        forecast = NA_real_,
        convergence = 999L,
        used_realized_forecast = FALSE
      )
    )
  }

  fc <- tryCatch(
    suppressWarnings(rugarch::ugarchforecast(fit, n.ahead = 1L)),
    error = function(e) NULL
  )

  if (is.null(fc)) {
    return(
      list(
        forecast = NA_real_,
        convergence = fit@fit$convergence,
        used_realized_forecast = FALSE
      )
    )
  }

  fslot <- tryCatch(methods::slot(fc, "forecast"), error = function(e) NULL)

  realized_for <- NULL
  if (!is.null(fslot) && !is.null(fslot$realizedFor)) {
    realized_for <- as.numeric(fslot$realizedFor[, 1L])
  }

  if (
    !is.null(realized_for) &&
      length(realized_for) >= 1L &&
      is.finite(realized_for[1L]) &&
      realized_for[1L] > 0
  ) {
    return(
      list(
        forecast = pmax(realized_for[1L]^2, cfg$forecast_floor),
        convergence = fit@fit$convergence,
        used_realized_forecast = TRUE
      )
    )
  }

  sig <- tryCatch(as.numeric(rugarch::sigma(fc)), error = function(e) numeric())

  if (length(sig) >= 1L && is.finite(sig[1L])) {
    return(
      list(
        forecast = pmax(sig[1L]^2, cfg$forecast_floor),
        convergence = fit@fit$convergence,
        used_realized_forecast = FALSE
      )
    )
  }

  list(
    forecast = NA_real_,
    convergence = fit@fit$convergence,
    used_realized_forecast = FALSE
  )
}

raw <- load_binance_raw(cfg)
message("Raw Binance candles: ", nrow(raw))

dat <- build_daily_measures(raw, cfg)
message("Valid daily observations: ", nrow(dat))

valid_origins <- which(
  dat$date >= cfg$test_start &
    dat$index >= cfg$train_window &
    dat$index <= nrow(dat) - 1L
)

if (length(valid_origins) == 0L) {
  stop("No OOS origins. Check test_start/train_window.")
}

if (QUICK_RUN && length(valid_origins) > 180L) {
  valid_origins <- tail(valid_origins, 180L)
}

message(
  "OOS origins: ",
  length(valid_origins),
  " | ",
  dat$date[min(valid_origins)],
  " to ",
  dat$date[max(valid_origins)]
)

forecast_rows <- vector("list", length(valid_origins))

pb <- utils::txtProgressBar(
  min = 0,
  max = length(valid_origins),
  style = 3
)

for (k in seq_along(valid_origins)) {
  i <- valid_origins[k]

  train_start <- max(1L, i - cfg$train_window + 1L)
  ii <- train_start:i

  RV <- dat$RV[ii]
  RQ <- dat$RQ[ii]
  ret <- dat$ret_pct[ii]
  d <- dat$date[ii]

  harq <- forecast_harq(RV, RQ, cfg)
  rg <- forecast_realgarch_1d(ret, RV, d, cfg)

  ensemble <- if (is.finite(harq$forecast) && is.finite(rg$forecast)) {
    0.5 * harq$forecast + 0.5 * rg$forecast
  } else if (is.finite(harq$forecast)) {
    harq$forecast
  } else {
    rg$forecast
  }

  selected <- switch(
    toupper(cfg$forecast_model),
    HARQ = harq$forecast,
    REALGARCH = rg$forecast,
    ENSEMBLE = ensemble,
    stop("forecast_model must be HARQ, REALGARCH or ENSEMBLE")
  )

  forecast_rows[[k]] <- data.frame(
    origin_date = dat$date[i],
    next_date = dat$date[i + 1L],
    next_return_pct = dat$ret_pct[i + 1L],
    next_actual_rv = dat$RV[i + 1L],
    harq_rv_forecast = harq$forecast,
    harq_raw_forecast = harq$raw,
    harq_guarded = harq$guarded,
    realgarch_rv_forecast = rg$forecast,
    realgarch_convergence = rg$convergence,
    realgarch_used_realized_forecast = rg$used_realized_forecast,
    ensemble_rv_forecast = ensemble,
    selected_rv_forecast = selected,
    stringsAsFactors = FALSE
  )

  utils::setTxtProgressBar(pb, k)
}

close(pb)

fc <- do.call(rbind, forecast_rows)

fc <- fc[
  is.finite(fc$selected_rv_forecast) &
    is.finite(fc$next_return_pct) &
    is.finite(fc$next_actual_rv),
  ,
  drop = FALSE
]

if (nrow(fc) < 30L) {
  stop("Too few valid OOS strategy observations.")
}

fc$forecast_vol_daily <- sqrt(
  pmax(fc$selected_rv_forecast, cfg$forecast_floor)
) / 100

fc$forecast_vol_annual <- fc$forecast_vol_daily * sqrt(cfg$annualization_days)

fc$raw_target_weight <- cfg$target_vol_annual /
  pmax(fc$forecast_vol_annual, 1e-8)

fc$target_weight <- pmin(
  pmax(fc$raw_target_weight, cfg$min_weight),
  cfg$max_weight
)

n <- nrow(fc)
implemented_weight <- numeric(n)
prev_w <- 0

for (i in seq_len(n)) {
  desired <- fc$target_weight[i]

  candidate <- cfg$weight_smoothing * desired +
    (1 - cfg$weight_smoothing) * prev_w

  if (abs(candidate - prev_w) < cfg$min_rebalance_change) {
    candidate <- prev_w
  }

  candidate <- pmin(
    pmax(candidate, cfg$min_weight),
    cfg$max_weight
  )

  implemented_weight[i] <- candidate
  prev_w <- candidate
}

fc$weight <- implemented_weight

fc$turnover <- abs(
  fc$weight -
    c(0, head(fc$weight, -1L))
)

fc$trading_cost_decimal <- cfg$transaction_cost_bps / 10000 * fc$turnover
fc$btc_return_decimal <- fc$next_return_pct / 100

fc$strategy_gross_return <- fc$weight * fc$btc_return_decimal
fc$strategy_net_return <- fc$strategy_gross_return - fc$trading_cost_decimal
fc$buy_hold_return <- fc$btc_return_decimal

fc$strategy_equity <- cumprod(1 + fc$strategy_net_return)
fc$strategy_gross_equity <- cumprod(1 + fc$strategy_gross_return)
fc$buy_hold_equity <- cumprod(1 + fc$buy_hold_return)

max_drawdown <- function(r) {
  wealth <- cumprod(1 + r)
  peak <- cummax(wealth)
  dd <- wealth / peak - 1
  min(dd, na.rm = TRUE)
}

performance_metrics <- function(r, annualization_days) {
  r <- r[is.finite(r)]
  n <- length(r)

  if (n < 2L) return(data.frame())

  wealth <- prod(1 + r)
  years <- n / annualization_days

  cagr <- if (wealth > 0 && years > 0) {
    wealth^(1 / years) - 1
  } else {
    NA_real_
  }

  ann_vol <- stats::sd(r) * sqrt(annualization_days)
  ann_mean <- mean(r) * annualization_days

  sharpe <- if (is.finite(ann_vol) && ann_vol > 0) {
    ann_mean / ann_vol
  } else {
    NA_real_
  }

  data.frame(
    observations = n,
    total_return = wealth - 1,
    CAGR = cagr,
    annualized_mean_return = ann_mean,
    annualized_volatility = ann_vol,
    Sharpe_zero_rf = sharpe,
    max_drawdown = max_drawdown(r),
    best_day = max(r),
    worst_day = min(r),
    positive_day_rate = mean(r > 0),
    stringsAsFactors = FALSE
  )
}

strategy_net_perf <- performance_metrics(
  fc$strategy_net_return,
  cfg$annualization_days
)

strategy_gross_perf <- performance_metrics(
  fc$strategy_gross_return,
  cfg$annualization_days
)

buy_hold_perf <- performance_metrics(
  fc$buy_hold_return,
  cfg$annualization_days
)

strategy_net_perf$strategy <- paste0(
  "VOL_TARGET_",
  toupper(cfg$forecast_model),
  "_NET"
)

strategy_gross_perf$strategy <- paste0(
  "VOL_TARGET_",
  toupper(cfg$forecast_model),
  "_GROSS"
)

buy_hold_perf$strategy <- "BTC_BUY_HOLD"

performance_summary <- rbind(
  strategy_net_perf,
  strategy_gross_perf,
  buy_hold_perf
)

performance_summary <- performance_summary[
  ,
  c("strategy", setdiff(names(performance_summary), "strategy"))
]

qlike_loss <- function(actual, forecast, eps = 1e-12) {
  actual <- pmax(actual, eps)
  forecast <- pmax(forecast, eps)
  ratio <- actual / forecast
  ratio - log(ratio) - 1
}

forecast_eval <- function(actual, forecast, name) {
  ok <- is.finite(actual) & is.finite(forecast)
  a <- actual[ok]
  f <- forecast[ok]

  data.frame(
    model = name,
    n = length(a),
    RMSE = sqrt(mean((f - a)^2)),
    MAE = mean(abs(f - a)),
    QLIKE = mean(qlike_loss(a, f, cfg$forecast_floor)),
    bias = mean(f - a),
    stringsAsFactors = FALSE
  )
}

forecast_metrics <- rbind(
  forecast_eval(fc$next_actual_rv, fc$harq_rv_forecast, "HARQ"),
  forecast_eval(fc$next_actual_rv, fc$realgarch_rv_forecast, "REALGARCH"),
  forecast_eval(fc$next_actual_rv, fc$ensemble_rv_forecast, "ENSEMBLE")
)

turnover_summary <- data.frame(
  forecast_model = cfg$forecast_model,
  target_vol_annual = cfg$target_vol_annual,
  max_weight = cfg$max_weight,
  transaction_cost_bps = cfg$transaction_cost_bps,
  average_weight = mean(fc$weight),
  median_weight = stats::median(fc$weight),
  p10_weight = as.numeric(stats::quantile(fc$weight, 0.10, names = FALSE)),
  p90_weight = as.numeric(stats::quantile(fc$weight, 0.90, names = FALSE)),
  fraction_at_max_weight = mean(abs(fc$weight - cfg$max_weight) < 1e-12),
  annualized_turnover = mean(fc$turnover) * cfg$annualization_days,
  total_turnover = sum(fc$turnover),
  total_cost_fraction = sum(fc$trading_cost_decimal),
  avg_forecast_vol_annual = mean(fc$forecast_vol_annual),
  realized_strategy_vol_annual =
    stats::sd(fc$strategy_net_return) * sqrt(cfg$annualization_days),
  stringsAsFactors = FALSE
)

make_drawdown <- function(equity) {
  equity / cummax(equity) - 1
}

fc$strategy_drawdown <- make_drawdown(fc$strategy_equity)
fc$buy_hold_drawdown <- make_drawdown(fc$buy_hold_equity)

eq_long <- rbind(
  data.frame(
    date = fc$next_date,
    strategy = paste0("Vol target ", cfg$forecast_model),
    equity = fc$strategy_equity
  ),
  data.frame(
    date = fc$next_date,
    strategy = "BTC buy & hold",
    equity = fc$buy_hold_equity
  )
)

p_eq <- ggplot2::ggplot(
  eq_long,
  ggplot2::aes(date, equity, linetype = strategy)
) +
  ggplot2::geom_line(linewidth = 0.7) +
  ggplot2::labs(
    title = "BTC volatility targeting vs buy & hold",
    subtitle = paste0(
      "Target vol=",
      round(100 * cfg$target_vol_annual, 1),
      "% | max weight=",
      cfg$max_weight,
      " | cost=",
      cfg$transaction_cost_bps,
      " bps"
    ),
    x = NULL,
    y = "Growth of $1",
    linetype = NULL
  ) +
  ggplot2::theme_minimal(base_size = 11)

ggplot2::ggsave(
  file.path(cfg$output_dir, "equity_curve.png"),
  p_eq,
  width = 11,
  height = 6,
  dpi = 150
)

dd_long <- rbind(
  data.frame(
    date = fc$next_date,
    strategy = paste0("Vol target ", cfg$forecast_model),
    drawdown = fc$strategy_drawdown
  ),
  data.frame(
    date = fc$next_date,
    strategy = "BTC buy & hold",
    drawdown = fc$buy_hold_drawdown
  )
)

p_dd <- ggplot2::ggplot(
  dd_long,
  ggplot2::aes(date, drawdown, linetype = strategy)
) +
  ggplot2::geom_line(linewidth = 0.7) +
  ggplot2::labs(
    title = "Drawdown",
    x = NULL,
    y = "Drawdown",
    linetype = NULL
  ) +
  ggplot2::theme_minimal(base_size = 11)

ggplot2::ggsave(
  file.path(cfg$output_dir, "drawdown.png"),
  p_dd,
  width = 11,
  height = 6,
  dpi = 150
)

p_w <- ggplot2::ggplot(
  fc,
  ggplot2::aes(next_date, weight)
) +
  ggplot2::geom_line(linewidth = 0.65) +
  ggplot2::geom_hline(yintercept = 1, linetype = "dashed", linewidth = 0.4) +
  ggplot2::labs(
    title = "BTC volatility-targeted exposure",
    subtitle = "1.0 = fully invested BTC; >1 = leveraged; <1 = partial BTC/cash",
    x = NULL,
    y = "BTC weight"
  ) +
  ggplot2::theme_minimal(base_size = 11)

ggplot2::ggsave(
  file.path(cfg$output_dir, "weights.png"),
  p_w,
  width = 11,
  height = 5.5,
  dpi = 150
)

forecast_long <- rbind(
  data.frame(
    date = fc$next_date,
    series = "Forecast",
    vol_pct = sqrt(fc$selected_rv_forecast)
  ),
  data.frame(
    date = fc$next_date,
    series = "Realized",
    vol_pct = sqrt(fc$next_actual_rv)
  )
)

p_f <- ggplot2::ggplot(
  forecast_long,
  ggplot2::aes(date, vol_pct, linetype = series)
) +
  ggplot2::geom_line(linewidth = 0.65) +
  ggplot2::labs(
    title = paste0(cfg$forecast_model, " next-day BTC volatility"),
    x = NULL,
    y = "Daily volatility, %",
    linetype = NULL
  ) +
  ggplot2::theme_minimal(base_size = 11)

ggplot2::ggsave(
  file.path(cfg$output_dir, "forecast_vs_realized_vol.png"),
  p_f,
  width = 11,
  height = 5.5,
  dpi = 150
)

utils::write.csv(
  fc,
  file.path(cfg$output_dir, "daily_strategy.csv"),
  row.names = FALSE
)

utils::write.csv(
  performance_summary,
  file.path(cfg$output_dir, "performance_summary.csv"),
  row.names = FALSE
)

utils::write.csv(
  forecast_metrics,
  file.path(cfg$output_dir, "forecast_metrics.csv"),
  row.names = FALSE
)

utils::write.csv(
  turnover_summary,
  file.path(cfg$output_dir, "turnover_summary.csv"),
  row.names = FALSE
)

run_config <- c(
  paste0("Run time: ", Sys.time()),
  paste0("QUICK_RUN: ", QUICK_RUN),
  paste0("Data: Binance Spot ", cfg$symbol, " ", cfg$interval),
  paste0("Forecast model: ", cfg$forecast_model),
  paste0("OOS start: ", cfg$test_start),
  paste0("Train window: ", cfg$train_window),
  paste0("Target annualized volatility: ", cfg$target_vol_annual),
  paste0("Weight bounds: [", cfg$min_weight, ", ", cfg$max_weight, "]"),
  paste0("Weight smoothing: ", cfg$weight_smoothing),
  paste0("Minimum rebalance change: ", cfg$min_rebalance_change),
  paste0("Transaction cost bps: ", cfg$transaction_cost_bps),
  paste0("Annualization days: ", cfg$annualization_days),
  "",
  "Weight formula:",
  "weight_t = target_vol_annual / forecast_vol_annual",
  "forecast_vol_annual = sqrt(forecast_RV_t+1)/100 * sqrt(365)",
  "",
  "Timing:",
  "Forecast formed using data through t.",
  "Weight_t applied to BTC return from t to t+1.",
  "Therefore the strategy is leakage-safe by construction."
)

writeLines(
  run_config,
  file.path(cfg$output_dir, "run_config.txt")
)

cat("\n================ PERFORMANCE SUMMARY ================\n")
print(performance_summary, row.names = FALSE, digits = 5)

cat("\n================ FORECAST METRICS ====================\n")
print(forecast_metrics, row.names = FALSE, digits = 5)

cat("\n================ TURNOVER / EXPOSURE =================\n")
print(turnover_summary, row.names = FALSE, digits = 5)

cat("\n======================================================\n")
cat(
  "Outputs written to: ",
  normalizePath(cfg$output_dir, winslash = "/", mustWork = FALSE),
  "\n",
  sep = ""
)
cat("======================================================\n\n")

cat(
  "READ THESE FIRST:\n",
  "  1. strategy net CAGR / Sharpe / max drawdown\n",
  "  2. realized strategy vol vs target vol\n",
  "  3. average weight and annualized turnover\n",
  "  4. strategy net vs BTC buy & hold\n",
  "  5. rerun HARQ, REALGARCH and ENSEMBLE separately\n\n",
  sep = ""
)
