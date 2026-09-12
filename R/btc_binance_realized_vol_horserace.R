# ==============================================================================
# BTC REALIZED-VOLATILITY MODEL HORSE RACE — BINANCE 5m
# HAR / HAR-J / HARQ / HARQ-F / Realized-GARCH / HEAVY-RM / GARCH
# ==============================================================================
#
# PURPOSE
# -------
# CEEMDAN did not show robust incremental value once tested against proper
# controls. This script moves to models designed specifically for realized
# volatility and high-frequency data.
#
# DATA:
#   Binance Spot BTCUSDT 5-minute candles, UTC.
#
# REALIZED MEASURES:
#
#   RV_t = sum_i r_{t,i}^2
#
#   BV_t = (pi/2) sum_i |r_{t,i}| |r_{t,i-1}|
#
#   J_t  = max(RV_t - BV_t, 0)
#
#   RQ_t = (M_t/3) sum_i r_{t,i}^4
#
#   RS+_t = sum_i r_{t,i}^2 I(r_{t,i}>0)
#   RS-_t = sum_i r_{t,i}^2 I(r_{t,i}<0)
#
# FORECAST TARGET:
#
#   y_{t,h} = mean(RV_{t+1}, ..., RV_{t+h})
#
# for h = 1, 5, 10 days.
#
# MODELS:
#   1. GARCH_11
#   2. HAR_RV
#   3. HAR_J
#   4. HARQ
#   5. HARQ_F
#   6. REALGARCH
#   7. HEAVY_RM
#
# HARQ:
#
#   y = b0 + b1 RV_d + b1Q sqrt(RQ_d)*RV_d
#            + b2 RV_w + b3 RV_m + e
#
# HARQ-F additionally allows weekly/monthly HAR coefficients to vary with
# corresponding realized-quarticity states.
#
# HAR-J in this script uses continuous/jump decomposition:
#
#   y = b0 + C_d + C_w + C_m + J_d + J_w + J_m + e
#
# where C is bipower variation and J=max(RV-BV,0).
#
# REALIZED-GARCH:
#   Uses rugarch::realGARCH with daily returns + sqrt(RV) as the realized
#   volatility input. We evaluate rugarch's realized-measure forecast after
#   squaring it back to variance units.
#
# HEAVY_RM:
#   We estimate the realized-measure equation
#
#       m_t = omega + alpha * RV_{t-1} + beta * m_{t-1}
#
#   by QLIKE/QMLE with variance targeting. This directly forecasts expected
#   realized variance and is the relevant HEAVY component for this horse race.
#
# ANTI-LEAKAGE:
#   Every forecast origin t is estimated using data available only through t.
#   Direct HAR/HARQ targets inside training end no later than t.
#
# IMPORTANT:
#   QUICK_RUN=TRUE keeps only the most recent 180 OOS origins.
#   Once the pipeline works, set QUICK_RUN=FALSE for the research run.
#
# ==============================================================================


# ==============================================================================
# 0. CONFIG
# ==============================================================================

QUICK_RUN <- FALSE

cfg <- list(
  seed = 12345L,

  # Binance
  symbol = "BTCUSDT",
  interval = "5m",
  start_date = as.Date("2019-01-01"),
  end_date = Sys.Date() - 1L,
  rest_base = "https://data-api.binance.vision",
  api_limit = 1000L,
  request_pause = 0.06,
  max_retries = 6L,
  retry_base_seconds = 1,

  # Reuses the raw cache created by the previous Binance scripts.
  raw_cache = "cache/binance_raw/BTCUSDT_5m.rds",
  refresh_cache = FALSE,

  # Daily-quality rules
  expected_bars_per_day = 288L,
  min_bars_per_day = 285L,
  drop_incomplete_days = TRUE,

  # Forecast experiment
  horizons = c(1L, 5L, 10L),
  test_start = as.Date("2025-01-01"),
  max_oos_origins = if (QUICK_RUN) 180L else NA_integer_,
  train_window = if (QUICK_RUN) 730L else 1460L,

  # HAR
  week = 5L,
  month = 22L,
  min_har_rows = 120L,

  # Literature-style stability rule for linear HAR-family models:
  # if an OOS forecast is outside the training target range, replace it with
  # the training mean. This prevents a single negative/absurd OLS forecast from
  # mechanically destroying QLIKE.
  har_range_guard = TRUE,

  # HEAVY
  heavy_min_rows = 250L,
  heavy_rho_max = 0.999,

  # Numerical
  rv_floor = 1e-10,
  forecast_floor = 1e-10,

  # Inference
  bootstrap_B = if (QUICK_RUN) 500L else 2000L,
  bootstrap_block_length = 14L,

  # Outputs/caches
  model_cache_dir = "cache/btc_rv_horserace_models",
  output_dir = "results/btc_rv_horserace"
)

set.seed(cfg$seed)

dir.create(dirname(cfg$raw_cache), recursive = TRUE, showWarnings = FALSE)
dir.create(cfg$model_cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cfg$output_dir, recursive = TRUE, showWarnings = FALSE)


# ==============================================================================
# 1. PACKAGES
# ==============================================================================

required_pkgs <- c(
  "curl",
  "jsonlite",
  "data.table",
  "xts",
  "rugarch",
  "ggplot2"
)

install_if_missing <- function(pkgs) {
  missing <- pkgs[
    !vapply(
      pkgs,
      requireNamespace,
      logical(1),
      quietly = TRUE
    )
  ]

  if (length(missing) > 0L) {
    message(
      "Installing missing packages: ",
      paste(missing, collapse = ", ")
    )

    install.packages(
      missing,
      repos = "https://cloud.r-project.org"
    )
  }

  still_missing <- pkgs[
    !vapply(
      pkgs,
      requireNamespace,
      logical(1),
      quietly = TRUE
    )
  ]

  if (length(still_missing) > 0L) {
    stop(
      "Could not install/load: ",
      paste(still_missing, collapse = ", ")
    )
  }
}

install_if_missing(required_pkgs)


# ==============================================================================
# 2. BINANCE RAW 5m DATA
# ==============================================================================

interval_to_ms <- function(interval) {
  lookup <- c(
    "1m" = 60000,
    "3m" = 180000,
    "5m" = 300000,
    "15m" = 900000,
    "30m" = 1800000,
    "1h" = 3600000
  )

  if (!interval %in% names(lookup)) {
    stop("Unsupported interval: ", interval)
  }

  unname(lookup[[interval]])
}


date_to_ms <- function(x) {
  as.numeric(
    as.POSIXct(
      as.Date(x),
      tz = "UTC"
    )
  ) * 1000
}


empty_klines <- function() {
  data.frame(
    open_time_ms = numeric(),
    open = numeric(),
    high = numeric(),
    low = numeric(),
    close = numeric(),
    volume = numeric(),
    close_time_ms = numeric(),
    quote_volume = numeric(),
    number_of_trades = numeric(),
    taker_buy_base_volume = numeric(),
    taker_buy_quote_volume = numeric(),
    stringsAsFactors = FALSE
  )
}


standardize_klines <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(empty_klines())
  }

  x <- as.data.frame(
    x,
    stringsAsFactors = FALSE
  )

  if (ncol(x) < 11L) {
    stop(
      "Unexpected Binance response: ",
      ncol(x),
      " columns."
    )
  }

  open_raw <- suppressWarnings(
    as.numeric(x[[1L]])
  )

  close_raw <- suppressWarnings(
    as.numeric(x[[7L]])
  )

  # Public archive data can use microseconds for recent data.
  # Normalize internal timestamps to milliseconds.
  open_ms <- ifelse(
    abs(open_raw) >= 1e14,
    open_raw / 1000,
    open_raw
  )

  close_ms <- ifelse(
    abs(close_raw) >= 1e14,
    close_raw / 1000,
    close_raw
  )

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


fetch_binance_rest <- function(
    symbol,
    interval,
    start_ms,
    end_ms,
    cfg
) {
  if (start_ms > end_ms) {
    return(empty_klines())
  }

  step_ms <- interval_to_ms(interval)
  cursor <- start_ms
  chunks <- list()
  cc <- 1L

  message(
    "Downloading missing Binance ",
    symbol,
    " ",
    interval,
    " candles..."
  )

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
      response <- tryCatch(
        curl::curl_fetch_memory(url),
        error = function(e) e
      )

      if (
        !inherits(response, "error") &&
          response$status_code == 200L
      ) {
        break
      }

      status <- if (
        inherits(response, "error")
      ) {
        "connection error"
      } else {
        paste0("HTTP ", response$status_code)
      }

      wait <- cfg$retry_base_seconds *
        2^(attempt - 1L)

      message(
        status,
        "; retry ",
        attempt,
        "/",
        cfg$max_retries,
        " in ",
        round(wait, 1),
        "s"
      )

      Sys.sleep(wait)
    }

    if (
      inherits(response, "error") ||
        is.null(response) ||
        response$status_code != 200L
    ) {
      stop(
        "Binance REST download failed after retries."
      )
    }

    parsed <- jsonlite::fromJSON(
      rawToChar(response$content),
      simplifyVector = TRUE
    )

    if (length(parsed) == 0L) {
      break
    }

    chunk <- standardize_klines(parsed)

    if (nrow(chunk) == 0L) {
      break
    }

    chunks[[cc]] <- chunk
    cc <- cc + 1L

    last_open <- max(chunk$open_time_ms)

    if (
      !is.finite(last_open) ||
        last_open < cursor
    ) {
      stop("Binance pagination failed to advance.")
    }

    cursor <- last_open + step_ms

    if (nrow(chunk) < cfg$api_limit) {
      break
    }

    Sys.sleep(cfg$request_pause)
  }

  if (length(chunks) == 0L) {
    return(empty_klines())
  }

  out <- do.call(rbind, chunks)

  out <- out[
    !duplicated(out$open_time_ms),
    ,
    drop = FALSE
  ]

  out <- out[
    order(out$open_time_ms),
    ,
    drop = FALSE
  ]

  rownames(out) <- NULL
  out
}


load_binance_raw <- function(cfg) {
  requested_start <- cfg$start_date - 1L
  requested_end <- cfg$end_date

  start_ms <- date_to_ms(requested_start)
  end_ms <- date_to_ms(requested_end + 1L) - 1

  cached <- NULL

  if (
    file.exists(cfg$raw_cache) &&
      !cfg$refresh_cache
  ) {
    cached <- tryCatch(
      readRDS(cfg$raw_cache),
      error = function(e) NULL
    )
  }

  step <- interval_to_ms(cfg$interval)
  pieces <- list()
  pp <- 1L

  if (
    !is.null(cached) &&
      nrow(cached) > 0L
  ) {
    cached <- standardize_klines(cached)

    pieces[[pp]] <- cached
    pp <- pp + 1L

    cmin <- min(cached$open_time_ms)
    cmax <- max(cached$open_time_ms)

    if (cmin > start_ms) {
      left <- fetch_binance_rest(
        cfg$symbol,
        cfg$interval,
        start_ms,
        cmin - step,
        cfg
      )

      if (nrow(left) > 0L) {
        pieces[[pp]] <- left
        pp <- pp + 1L
      }
    }

    if (cmax < end_ms - step) {
      right <- fetch_binance_rest(
        cfg$symbol,
        cfg$interval,
        cmax + step,
        end_ms,
        cfg
      )

      if (nrow(right) > 0L) {
        pieces[[pp]] <- right
      }
    }
  } else {
    pieces[[1L]] <- fetch_binance_rest(
      cfg$symbol,
      cfg$interval,
      start_ms,
      end_ms,
      cfg
    )
  }

  raw <- do.call(rbind, pieces)

  if (is.null(raw) || nrow(raw) == 0L) {
    stop("No Binance candles available.")
  }

  raw <- raw[
    !duplicated(raw$open_time_ms),
    ,
    drop = FALSE
  ]

  raw <- raw[
    order(raw$open_time_ms),
    ,
    drop = FALSE
  ]

  saveRDS(
    raw,
    cfg$raw_cache
  )

  raw
}


# ==============================================================================
# 3. DAILY REALIZED MEASURES
# ==============================================================================

build_daily_measures <- function(raw, cfg) {
  raw$datetime <- as.POSIXct(
    raw$open_time_ms / 1000,
    origin = "1970-01-01",
    tz = "UTC"
  )

  raw <- raw[
    !is.na(raw$datetime),
    ,
    drop = FALSE
  ]

  raw <- raw[
    order(raw$datetime),
    ,
    drop = FALSE
  ]

  raw <- raw[
    !duplicated(raw$datetime),
    ,
    drop = FALSE
  ]

  raw$r5 <- c(
    NA_real_,
    100 * diff(log(raw$close))
  )

  raw$date <- as.Date(
    raw$datetime,
    tz = "UTC"
  )

  split_idx <- split(
    seq_len(nrow(raw)),
    raw$date
  )

  daily_list <- lapply(
    split_idx,
    function(ii) {
      rr <- raw$r5[ii]
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
            BV = NA_real_,
            J = NA_real_,
            RQ = NA_real_,
            RS_plus = NA_real_,
            RS_minus = NA_real_,
            stringsAsFactors = FALSE
          )
        )
      }

      rv <- sum(rr^2)

      bv <- if (m >= 2L) {
        (pi / 2) *
          sum(
            abs(rr[-1L]) *
              abs(rr[-m])
          )
      } else {
        NA_real_
      }

      jump <- max(rv - bv, 0)

      # Realized quarticity:
      # RQ_t = (M/3) * sum r_i^4
      rq <- (m / 3) *
        sum(rr^4)

      rs_plus <- sum(
        rr[rr > 0]^2
      )

      rs_minus <- sum(
        rr[rr < 0]^2
      )

      data.frame(
        date = raw$date[ii[length(ii)]],
        close = raw$close[ii[length(ii)]],
        n_bars = n_bars,
        RV = rv,
        BV = bv,
        J = jump,
        RQ = rq,
        RS_plus = rs_plus,
        RS_minus = rs_minus,
        stringsAsFactors = FALSE
      )
    }
  )

  out <- do.call(
    rbind,
    daily_list
  )

  out <- out[
    out$date >= cfg$start_date &
      out$date <= cfg$end_date,
    ,
    drop = FALSE
  ]

  out$complete_day <- out$n_bars >=
    cfg$expected_bars_per_day

  utils::write.csv(
    out[
      ,
      c(
        "date",
        "n_bars",
        "complete_day"
      )
    ],
    file.path(
      cfg$output_dir,
      "binance_daily_quality.csv"
    ),
    row.names = FALSE
  )

  if (cfg$drop_incomplete_days) {
    out <- out[
      out$complete_day,
      ,
      drop = FALSE
    ]
  }

  out <- out[
    is.finite(out$RV) &
      is.finite(out$BV) &
      is.finite(out$J) &
      is.finite(out$RQ),
    ,
    drop = FALSE
  ]

  out$RV <- pmax(
    out$RV,
    cfg$rv_floor
  )

  out$BV <- pmax(
    out$BV,
    0
  )

  out$J <- pmax(
    out$J,
    0
  )

  out$RQ <- pmax(
    out$RQ,
    cfg$rv_floor^2
  )

  out$ret_pct <- c(
    NA_real_,
    100 * diff(log(out$close))
  )

  out <- out[
    is.finite(out$ret_pct),
    ,
    drop = FALSE
  ]

  rownames(out) <- NULL
  out$index <- seq_len(nrow(out))
  out
}


raw <- load_binance_raw(cfg)

message(
  "Raw 5m candles: ",
  nrow(raw)
)

dat <- build_daily_measures(
  raw,
  cfg
)

message(
  "Complete daily observations: ",
  nrow(dat)
)


# ==============================================================================
# 4. HELPERS
# ==============================================================================

qlike_loss <- function(actual, forecast, eps = 1e-12) {
  actual <- pmax(actual, eps)
  forecast <- pmax(forecast, eps)

  ratio <- actual / forecast
  ratio - log(ratio) - 1
}


future_average <- function(x, origin, h) {
  if (origin + h > length(x)) {
    return(NA_real_)
  }

  mean(
    x[(origin + 1L):(origin + h)]
  )
}


roll_mean_at <- function(x, i, k) {
  if (i < k) {
    return(NA_real_)
  }

  mean(
    x[(i - k + 1L):i]
  )
}


guard_har_forecast <- function(
    pred,
    training_targets,
    cfg
) {
  if (!is.finite(pred)) {
    return(
      list(
        forecast = NA_real_,
        guarded = NA
      )
    )
  }

  y <- training_targets[
    is.finite(training_targets)
  ]

  if (length(y) == 0L) {
    return(
      list(
        forecast = NA_real_,
        guarded = NA
      )
    )
  }

  if (!cfg$har_range_guard) {
    return(
      list(
        forecast = pmax(
          pred,
          cfg$forecast_floor
        ),
        guarded = pred <= 0
      )
    )
  }

  lo <- min(y)
  hi <- max(y)

  if (
    pred <= 0 ||
      pred < lo ||
      pred > hi
  ) {
    return(
      list(
        forecast = pmax(
          mean(y),
          cfg$forecast_floor
        ),
        guarded = TRUE
      )
    )
  }

  list(
    forecast = pmax(
      pred,
      cfg$forecast_floor
    ),
    guarded = FALSE
  )
}


# ==============================================================================
# 5. HAR-FAMILY TRAINING FRAMES
# ==============================================================================

build_direct_frame <- function(
    RV,
    BV,
    J,
    RQ,
    h,
    week,
    month
) {
  n <- length(RV)

  if (n < month + h + 50L) {
    return(NULL)
  }

  origins <- month:(n - h)

  rows <- lapply(
    origins,
    function(s) {
      y <- mean(
        RV[(s + 1L):(s + h)]
      )

      rv_d <- RV[s]
      rv_w <- mean(
        RV[(s - week + 1L):s]
      )
      rv_m <- mean(
        RV[(s - month + 1L):s]
      )

      bv_d <- BV[s]
      bv_w <- mean(
        BV[(s - week + 1L):s]
      )
      bv_m <- mean(
        BV[(s - month + 1L):s]
      )

      j_d <- J[s]
      j_w <- mean(
        J[(s - week + 1L):s]
      )
      j_m <- mean(
        J[(s - month + 1L):s]
      )

      rq_d <- RQ[s]
      rq_w <- mean(
        RQ[(s - week + 1L):s]
      )
      rq_m <- mean(
        RQ[(s - month + 1L):s]
      )

      data.frame(
        y = y,
        rv_d = rv_d,
        rv_w = rv_w,
        rv_m = rv_m,
        bv_d = bv_d,
        bv_w = bv_w,
        bv_m = bv_m,
        j_d = j_d,
        j_w = j_w,
        j_m = j_m,
        rq_d = rq_d,
        rq_w = rq_w,
        rq_m = rq_m,
        qint_d = sqrt(rq_d) * rv_d,
        qint_w = sqrt(rq_w) * rv_w,
        qint_m = sqrt(rq_m) * rv_m,
        stringsAsFactors = FALSE
      )
    }
  )

  do.call(rbind, rows)
}


current_direct_features <- function(
    RV,
    BV,
    J,
    RQ,
    week,
    month
) {
  n <- length(RV)

  rv_d <- RV[n]
  rv_w <- mean(tail(RV, week))
  rv_m <- mean(tail(RV, month))

  bv_d <- BV[n]
  bv_w <- mean(tail(BV, week))
  bv_m <- mean(tail(BV, month))

  j_d <- J[n]
  j_w <- mean(tail(J, week))
  j_m <- mean(tail(J, month))

  rq_d <- RQ[n]
  rq_w <- mean(tail(RQ, week))
  rq_m <- mean(tail(RQ, month))

  data.frame(
    rv_d = rv_d,
    rv_w = rv_w,
    rv_m = rv_m,
    bv_d = bv_d,
    bv_w = bv_w,
    bv_m = bv_m,
    j_d = j_d,
    j_w = j_w,
    j_m = j_m,
    rq_d = rq_d,
    rq_w = rq_w,
    rq_m = rq_m,
    qint_d = sqrt(rq_d) * rv_d,
    qint_w = sqrt(rq_w) * rv_w,
    qint_m = sqrt(rq_m) * rv_m
  )
}


fit_predict_lm <- function(
    df,
    formula,
    current,
    cfg
) {
  if (
    is.null(df) ||
      nrow(df) < cfg$min_har_rows
  ) {
    return(
      list(
        forecast = NA_real_,
        raw = NA_real_,
        guarded = NA
      )
    )
  }

  fit <- tryCatch(
    stats::lm(
      formula,
      data = df
    ),
    error = function(e) NULL
  )

  if (is.null(fit)) {
    return(
      list(
        forecast = NA_real_,
        raw = NA_real_,
        guarded = NA
      )
    )
  }

  raw <- tryCatch(
    as.numeric(
      stats::predict(
        fit,
        newdata = current
      )
    ),
    error = function(e) NA_real_
  )

  g <- guard_har_forecast(
    raw,
    df$y,
    cfg
  )

  list(
    forecast = g$forecast,
    raw = raw,
    guarded = g$guarded
  )
}


forecast_har_models <- function(
    RV,
    BV,
    J,
    RQ,
    h,
    cfg
) {
  df <- build_direct_frame(
    RV,
    BV,
    J,
    RQ,
    h,
    cfg$week,
    cfg$month
  )

  cur <- current_direct_features(
    RV,
    BV,
    J,
    RQ,
    cfg$week,
    cfg$month
  )

  har_rv <- fit_predict_lm(
    df,
    y ~ rv_d + rv_w + rv_m,
    cur,
    cfg
  )

  har_j <- fit_predict_lm(
    df,
    y ~ bv_d + bv_w + bv_m +
      j_d + j_w + j_m,
    cur,
    cfg
  )

  harq <- fit_predict_lm(
    df,
    y ~ rv_d + qint_d +
      rv_w + rv_m,
    cur,
    cfg
  )

  harq_f <- fit_predict_lm(
    df,
    y ~ rv_d + qint_d +
      rv_w + qint_w +
      rv_m + qint_m,
    cur,
    cfg
  )

  list(
    HAR_RV = har_rv,
    HAR_J = har_j,
    HARQ = harq,
    HARQ_F = harq_f
  )
}


# ==============================================================================
# 6. GARCH(1,1)-t
# ==============================================================================

forecast_garch <- function(
    ret_pct,
    max_h,
    dates,
    cfg
) {
  ok <- is.finite(ret_pct)

  r <- ret_pct[ok]
  d <- dates[ok]

  if (length(r) < 250L) {
    return(
      list(
        daily_var = rep(NA_real_, max_h),
        convergence = NA_integer_
      )
    )
  }

  x <- xts::xts(
    r,
    order.by = as.Date(d)
  )

  spec <- rugarch::ugarchspec(
    variance.model = list(
      model = "sGARCH",
      garchOrder = c(1L, 1L)
    ),
    mean.model = list(
      armaOrder = c(0L, 0L),
      include.mean = TRUE
    ),
    distribution.model = "std"
  )

  fit <- tryCatch(
    suppressWarnings(
      rugarch::ugarchfit(
        spec = spec,
        data = x,
        solver = "hybrid",
        solver.control = list(
          trace = 0
        )
      )
    ),
    error = function(e) NULL
  )

  if (is.null(fit)) {
    return(
      list(
        daily_var = rep(NA_real_, max_h),
        convergence = 999L
      )
    )
  }

  fc <- tryCatch(
    suppressWarnings(
      rugarch::ugarchforecast(
        fit,
        n.ahead = max_h
      )
    ),
    error = function(e) NULL
  )

  if (is.null(fc)) {
    return(
      list(
        daily_var = rep(NA_real_, max_h),
        convergence = fit@fit$convergence
      )
    )
  }

  sig <- as.numeric(
    rugarch::sigma(fc)
  )

  if (
    length(sig) < max_h ||
      any(!is.finite(sig[seq_len(max_h)]))
  ) {
    return(
      list(
        daily_var = rep(NA_real_, max_h),
        convergence = fit@fit$convergence
      )
    )
  }

  list(
    daily_var = pmax(
      sig[seq_len(max_h)]^2,
      cfg$forecast_floor
    ),
    convergence = fit@fit$convergence
  )
}


# ==============================================================================
# 7. REALIZED-GARCH
# ==============================================================================

forecast_realgarch <- function(
    ret_pct,
    RV,
    max_h,
    dates,
    cfg
) {
  ok <- is.finite(ret_pct) &
    is.finite(RV) &
    RV > 0

  r <- ret_pct[ok]
  rv <- RV[ok]
  d <- as.Date(dates[ok])

  if (length(r) < 250L) {
    return(
      list(
        daily_rv = rep(NA_real_, max_h),
        convergence = NA_integer_,
        used_realized_forecast = FALSE
      )
    )
  }

  ret_xts <- xts::xts(
    r,
    order.by = d
  )

  # rugarch's realGARCH interface expects a realized volatility series,
  # hence sqrt(RV) in the same percent units as returns.
  rvol_xts <- xts::xts(
    sqrt(rv),
    order.by = d
  )

  spec <- rugarch::ugarchspec(
    variance.model = list(
      model = "realGARCH",
      garchOrder = c(1L, 1L)
    ),
    mean.model = list(
      armaOrder = c(0L, 0L),
      include.mean = TRUE
    ),
    distribution.model = "std"
  )

  fit <- tryCatch(
    suppressWarnings(
      rugarch::ugarchfit(
        spec = spec,
        data = ret_xts,
        realizedVol = rvol_xts,
        solver = "hybrid",
        solver.control = list(
          trace = 0
        )
      )
    ),
    error = function(e) NULL
  )

  if (is.null(fit)) {
    return(
      list(
        daily_rv = rep(NA_real_, max_h),
        convergence = 999L,
        used_realized_forecast = FALSE
      )
    )
  }

  fc <- tryCatch(
    suppressWarnings(
      rugarch::ugarchforecast(
        fit,
        n.ahead = max_h
      )
    ),
    error = function(e) NULL
  )

  if (is.null(fc)) {
    return(
      list(
        daily_rv = rep(NA_real_, max_h),
        convergence = fit@fit$convergence,
        used_realized_forecast = FALSE
      )
    )
  }

  fslot <- tryCatch(
    methods::slot(
      fc,
      "forecast"
    ),
    error = function(e) NULL
  )

  realized_for <- NULL

  if (
    !is.null(fslot) &&
      !is.null(fslot$realizedFor)
  ) {
    realized_for <- as.numeric(
      fslot$realizedFor[, 1L]
    )
  }

  if (
    !is.null(realized_for) &&
      length(realized_for) >= max_h &&
      all(
        is.finite(
          realized_for[seq_len(max_h)]
        )
      ) &&
      all(
        realized_for[seq_len(max_h)] > 0
      )
  ) {
    return(
      list(
        daily_rv = pmax(
          realized_for[seq_len(max_h)]^2,
          cfg$forecast_floor
        ),
        convergence = fit@fit$convergence,
        used_realized_forecast = TRUE
      )
    )
  }

  # Fallback: conditional return variance if realized-measure forecast cannot be
  # extracted on a particular rugarch version.
  sig <- tryCatch(
    as.numeric(
      rugarch::sigma(fc)
    ),
    error = function(e) numeric()
  )

  if (
    length(sig) >= max_h &&
      all(
        is.finite(
          sig[seq_len(max_h)]
        )
      )
  ) {
    return(
      list(
        daily_rv = pmax(
          sig[seq_len(max_h)]^2,
          cfg$forecast_floor
        ),
        convergence = fit@fit$convergence,
        used_realized_forecast = FALSE
      )
    )
  }

  list(
    daily_rv = rep(NA_real_, max_h),
    convergence = fit@fit$convergence,
    used_realized_forecast = FALSE
  )
}


# ==============================================================================
# 8. HEAVY-RM
# ==============================================================================

heavy_decode <- function(theta, mu, cfg) {
  rho <- cfg$heavy_rho_max *
    stats::plogis(theta[1L])

  share <- stats::plogis(
    theta[2L]
  )

  alpha <- rho * share
  beta <- rho * (1 - share)
  omega <- mu * (1 - rho)

  c(
    omega = omega,
    alpha = alpha,
    beta = beta,
    rho = rho
  )
}


heavy_filter <- function(
    RV,
    pars
) {
  n <- length(RV)

  m <- numeric(n)

  mu <- mean(
    RV,
    na.rm = TRUE
  )

  m[1L] <- pmax(
    mu,
    1e-12
  )

  if (n >= 2L) {
    for (t in 2L:n) {
      m[t] <- pars["omega"] +
        pars["alpha"] * RV[t - 1L] +
        pars["beta"] * m[t - 1L]

      m[t] <- pmax(
        m[t],
        1e-12
      )
    }
  }

  m
}


heavy_objective <- function(
    theta,
    RV,
    cfg
) {
  mu <- mean(
    RV,
    na.rm = TRUE
  )

  pars <- heavy_decode(
    theta,
    mu,
    cfg
  )

  m <- heavy_filter(
    RV,
    pars
  )

  # One-step realized-measure QLIKE from t=2 onward.
  loss <- qlike_loss(
    RV[-1L],
    m[-1L],
    cfg$forecast_floor
  )

  val <- mean(
    loss,
    na.rm = TRUE
  )

  if (!is.finite(val)) {
    1e12
  } else {
    val
  }
}


fit_forecast_heavy <- function(
    RV,
    max_h,
    cfg
) {
  RV <- RV[
    is.finite(RV) &
      RV > 0
  ]

  if (length(RV) < cfg$heavy_min_rows) {
    return(
      list(
        daily_rv = rep(NA_real_, max_h),
        omega = NA_real_,
        alpha = NA_real_,
        beta = NA_real_,
        rho = NA_real_,
        convergence = NA_integer_
      )
    )
  }

  # Initial rho ~0.8, alpha/rho ~0.5
  init <- c(
    stats::qlogis(
      0.8 / cfg$heavy_rho_max
    ),
    0
  )

  fit <- tryCatch(
    stats::optim(
      par = init,
      fn = heavy_objective,
      RV = RV,
      cfg = cfg,
      method = "BFGS",
      control = list(
        maxit = 500L,
        reltol = 1e-10
      )
    ),
    error = function(e) NULL
  )

  if (
    is.null(fit) ||
      !is.finite(fit$value)
  ) {
    return(
      list(
        daily_rv = rep(NA_real_, max_h),
        omega = NA_real_,
        alpha = NA_real_,
        beta = NA_real_,
        rho = NA_real_,
        convergence = 999L
      )
    )
  }

  mu <- mean(RV)

  pars <- heavy_decode(
    fit$par,
    mu,
    cfg
  )

  m <- heavy_filter(
    RV,
    pars
  )

  daily_fc <- numeric(max_h)

  # t+1 uses observed RV_t.
  daily_fc[1L] <- pars["omega"] +
    pars["alpha"] * tail(RV, 1L) +
    pars["beta"] * tail(m, 1L)

  daily_fc[1L] <- pmax(
    daily_fc[1L],
    cfg$forecast_floor
  )

  # For k>=2, E_t[RV_{t+k-1}] is its HEAVY conditional mean.
  if (max_h >= 2L) {
    for (k in 2L:max_h) {
      daily_fc[k] <- pars["omega"] +
        (
          pars["alpha"] +
            pars["beta"]
        ) *
          daily_fc[k - 1L]

      daily_fc[k] <- pmax(
        daily_fc[k],
        cfg$forecast_floor
      )
    }
  }

  list(
    daily_rv = daily_fc,
    omega = unname(pars["omega"]),
    alpha = unname(pars["alpha"]),
    beta = unname(pars["beta"]),
    rho = unname(pars["rho"]),
    convergence = fit$convergence
  )
}


# ==============================================================================
# 9. OOS ORIGINS
# ==============================================================================

max_h <- max(cfg$horizons)

oos_idx <- which(
  dat$date >= cfg$test_start &
    dat$index >= cfg$train_window &
    dat$index <= nrow(dat) - max_h
)

if (length(oos_idx) == 0L) {
  stop(
    "No OOS origins. Check test_start/train_window/data."
  )
}

if (
  !is.na(cfg$max_oos_origins) &&
    length(oos_idx) > cfg$max_oos_origins
) {
  oos_idx <- tail(
    oos_idx,
    cfg$max_oos_origins
  )
}

message(
  "OOS origins: ",
  length(oos_idx),
  " (",
  dat$date[min(oos_idx)],
  " to ",
  dat$date[max(oos_idx)],
  ")"
)


# ==============================================================================
# 10. WALK-FORWARD HORSE RACE
# ==============================================================================

forecast_rows <- list()
failure_rows <- list()
heavy_param_rows <- list()

fc_counter <- 1L
fail_counter <- 1L
heavy_counter <- 1L

pb <- utils::txtProgressBar(
  min = 0,
  max = length(oos_idx),
  style = 3
)

for (oo in seq_along(oos_idx)) {
  i <- oos_idx[oo]

  train_start <- max(
    1L,
    i - cfg$train_window + 1L
  )

  ii <- train_start:i

  train_RV <- dat$RV[ii]
  train_BV <- dat$BV[ii]
  train_J <- dat$J[ii]
  train_RQ <- dat$RQ[ii]
  train_ret <- dat$ret_pct[ii]
  train_dates <- dat$date[ii]

  # GARCH and Realized-GARCH are fit once per origin for all horizons.
  garch <- tryCatch(
    forecast_garch(
      train_ret,
      max_h,
      train_dates,
      cfg
    ),
    error = function(e) {
      failure_rows[[fail_counter]] <<-
        data.frame(
          origin_date = dat$date[i],
          model = "GARCH_11",
          message = conditionMessage(e),
          stringsAsFactors = FALSE
        )
      fail_counter <<- fail_counter + 1L

      list(
        daily_var = rep(NA_real_, max_h),
        convergence = 999L
      )
    }
  )

  realgarch <- tryCatch(
    forecast_realgarch(
      train_ret,
      train_RV,
      max_h,
      train_dates,
      cfg
    ),
    error = function(e) {
      failure_rows[[fail_counter]] <<-
        data.frame(
          origin_date = dat$date[i],
          model = "REALGARCH",
          message = conditionMessage(e),
          stringsAsFactors = FALSE
        )
      fail_counter <<- fail_counter + 1L

      list(
        daily_rv = rep(NA_real_, max_h),
        convergence = 999L,
        used_realized_forecast = FALSE
      )
    }
  )

  heavy <- tryCatch(
    fit_forecast_heavy(
      train_RV,
      max_h,
      cfg
    ),
    error = function(e) {
      failure_rows[[fail_counter]] <<-
        data.frame(
          origin_date = dat$date[i],
          model = "HEAVY_RM",
          message = conditionMessage(e),
          stringsAsFactors = FALSE
        )
      fail_counter <<- fail_counter + 1L

      list(
        daily_rv = rep(NA_real_, max_h),
        omega = NA_real_,
        alpha = NA_real_,
        beta = NA_real_,
        rho = NA_real_,
        convergence = 999L
      )
    }
  )

  heavy_param_rows[[heavy_counter]] <- data.frame(
    origin_date = dat$date[i],
    omega = heavy$omega,
    alpha = heavy$alpha,
    beta = heavy$beta,
    rho = heavy$rho,
    convergence = heavy$convergence,
    stringsAsFactors = FALSE
  )

  heavy_counter <- heavy_counter + 1L

  for (h in cfg$horizons) {
    actual <- future_average(
      dat$RV,
      i,
      h
    )

    har <- tryCatch(
      forecast_har_models(
        train_RV,
        train_BV,
        train_J,
        train_RQ,
        h,
        cfg
      ),
      error = function(e) {
        failure_rows[[fail_counter]] <<-
          data.frame(
            origin_date = dat$date[i],
            model = paste0(
              "HAR_FAMILY_h",
              h
            ),
            message = conditionMessage(e),
            stringsAsFactors = FALSE
          )
        fail_counter <<- fail_counter + 1L
        NULL
      }
    )

    garch_h <- if (
      all(
        is.finite(
          garch$daily_var[seq_len(h)]
        )
      )
    ) {
      mean(
        garch$daily_var[seq_len(h)]
      )
    } else {
      NA_real_
    }

    realgarch_h <- if (
      all(
        is.finite(
          realgarch$daily_rv[seq_len(h)]
        )
      )
    ) {
      mean(
        realgarch$daily_rv[seq_len(h)]
      )
    } else {
      NA_real_
    }

    heavy_h <- if (
      all(
        is.finite(
          heavy$daily_rv[seq_len(h)]
        )
      )
    ) {
      mean(
        heavy$daily_rv[seq_len(h)]
      )
    } else {
      NA_real_
    }

    model_entries <- list(
      GARCH_11 = list(
        forecast = garch_h,
        raw = garch_h,
        guarded = FALSE,
        convergence = garch$convergence,
        realized_forecast = NA
      ),
      REALGARCH = list(
        forecast = realgarch_h,
        raw = realgarch_h,
        guarded = FALSE,
        convergence = realgarch$convergence,
        realized_forecast =
          realgarch$used_realized_forecast
      ),
      HEAVY_RM = list(
        forecast = heavy_h,
        raw = heavy_h,
        guarded = FALSE,
        convergence = heavy$convergence,
        realized_forecast = NA
      )
    )

    if (!is.null(har)) {
      for (nm in names(har)) {
        model_entries[[nm]] <- list(
          forecast = har[[nm]]$forecast,
          raw = har[[nm]]$raw,
          guarded = har[[nm]]$guarded,
          convergence = 0L,
          realized_forecast = NA
        )
      }
    }

    for (model_name in names(model_entries)) {
      z <- model_entries[[model_name]]

      forecast_rows[[fc_counter]] <- data.frame(
        origin_date = dat$date[i],
        origin_index = i,
        horizon = h,
        model = model_name,
        actual_rv = pmax(
          actual,
          cfg$rv_floor
        ),
        forecast_rv = if (
          is.finite(z$forecast)
        ) {
          pmax(
            z$forecast,
            cfg$forecast_floor
          )
        } else {
          NA_real_
        },
        raw_forecast_rv = z$raw,
        was_guarded = z$guarded,
        convergence = z$convergence,
        realgarch_used_realized_forecast =
          z$realized_forecast,
        train_start = dat$date[train_start],
        train_end = dat$date[i],
        stringsAsFactors = FALSE
      )

      fc_counter <- fc_counter + 1L
    }
  }

  utils::setTxtProgressBar(
    pb,
    oo
  )
}

close(pb)

forecasts <- do.call(
  rbind,
  forecast_rows
)

forecasts$origin_date <- as.Date(
  forecasts$origin_date
)

heavy_parameters <- do.call(
  rbind,
  heavy_param_rows
)

model_failures <- if (
  length(failure_rows) > 0L
) {
  do.call(
    rbind,
    failure_rows
  )
} else {
  data.frame(
    origin_date = as.Date(character()),
    model = character(),
    message = character()
  )
}


# ==============================================================================
# 11. METRICS
# ==============================================================================

metric_one <- function(df) {
  ok <- is.finite(df$actual_rv) &
    is.finite(df$forecast_rv)

  a <- df$actual_rv[ok]
  f <- df$forecast_rv[ok]

  if (length(a) == 0L) {
    return(
      data.frame(
        n = 0L,
        RMSE = NA_real_,
        MAE = NA_real_,
        QLIKE = NA_real_,
        log_RMSE = NA_real_,
        bias = NA_real_,
        guard_rate = NA_real_
      )
    )
  }

  guarded <- df$was_guarded[ok]
  guarded <- guarded[
    !is.na(guarded)
  ]

  data.frame(
    n = length(a),
    RMSE = sqrt(
      mean(
        (f - a)^2
      )
    ),
    MAE = mean(
      abs(f - a)
    ),
    QLIKE = mean(
      qlike_loss(
        a,
        f,
        cfg$forecast_floor
      )
    ),
    log_RMSE = sqrt(
      mean(
        (
          log(f) -
            log(a)
        )^2
      )
    ),
    bias = mean(
      f - a
    ),
    guard_rate = if (
      length(guarded) > 0L
    ) {
      mean(guarded)
    } else {
      NA_real_
    }
  )
}


groups <- split(
  forecasts,
  interaction(
    forecasts$horizon,
    forecasts$model,
    drop = TRUE
  )
)

metrics <- do.call(
  rbind,
  lapply(
    groups,
    function(df) {
      m <- metric_one(df)

      data.frame(
        horizon = unique(df$horizon),
        model = unique(df$model),
        m,
        stringsAsFactors = FALSE
      )
    }
  )
)

rownames(metrics) <- NULL

metrics <- metrics[
  order(
    metrics$horizon,
    metrics$QLIKE
  ),
  ,
  drop = FALSE
]


# ==============================================================================
# 12. DIEBOLD-MARIANO
# ==============================================================================

nw_long_run_variance <- function(
    x,
    lag
) {
  x <- x[is.finite(x)]

  n <- length(x)

  if (n < 5L) {
    return(NA_real_)
  }

  xc <- x - mean(x)

  gamma0 <- sum(
    xc^2
  ) / n

  lrv <- gamma0

  if (lag > 0L) {
    for (
      k in seq_len(
        min(lag, n - 1L)
      )
    ) {
      gamma_k <- sum(
        xc[(k + 1L):n] *
          xc[1L:(n - k)]
      ) / n

      w <- 1 -
        k / (lag + 1)

      lrv <- lrv +
        2 * w * gamma_k
    }
  }

  lrv
}


paired_loss_diff <- function(
    forecasts,
    h,
    model_a,
    model_b,
    loss = c(
      "QLIKE",
      "SE"
    )
) {
  loss <- match.arg(loss)

  a <- forecasts[
    forecasts$horizon == h &
      forecasts$model == model_a,
    c(
      "origin_date",
      "actual_rv",
      "forecast_rv"
    ),
    drop = FALSE
  ]

  b <- forecasts[
    forecasts$horizon == h &
      forecasts$model == model_b,
    c(
      "origin_date",
      "forecast_rv"
    ),
    drop = FALSE
  ]

  names(a)[3L] <- "fa"
  names(b)[2L] <- "fb"

  z <- merge(
    a,
    b,
    by = "origin_date"
  )

  z <- z[
    is.finite(z$actual_rv) &
      is.finite(z$fa) &
      is.finite(z$fb),
    ,
    drop = FALSE
  ]

  if (loss == "QLIKE") {
    la <- qlike_loss(
      z$actual_rv,
      z$fa,
      cfg$forecast_floor
    )

    lb <- qlike_loss(
      z$actual_rv,
      z$fb,
      cfg$forecast_floor
    )
  } else {
    la <- (
      z$actual_rv -
        z$fa
    )^2

    lb <- (
      z$actual_rv -
        z$fb
    )^2
  }

  list(
    dates = z$origin_date,
    diff = la - lb
  )
}


dm_test_from_diff <- function(
    d,
    h
) {
  d <- d[is.finite(d)]

  if (length(d) < 30L) {
    return(
      c(
        n = length(d),
        statistic = NA_real_,
        p_value = NA_real_,
        mean_loss_diff = NA_real_
      )
    )
  }

  lrv <- nw_long_run_variance(
    d,
    max(h - 1L, 0L)
  )

  if (
    !is.finite(lrv) ||
      lrv <= 0
  ) {
    return(
      c(
        n = length(d),
        statistic = NA_real_,
        p_value = NA_real_,
        mean_loss_diff = mean(d)
      )
    )
  }

  stat <- mean(d) /
    sqrt(
      lrv / length(d)
    )

  p <- 2 *
    stats::pnorm(
      -abs(stat)
    )

  c(
    n = length(d),
    statistic = stat,
    p_value = p,
    mean_loss_diff = mean(d)
  )
}


# ==============================================================================
# 13. MOVING-BLOCK BOOTSTRAP
# ==============================================================================

block_bootstrap_mean <- function(
    d,
    B,
    block_length,
    seed
) {
  d <- d[is.finite(d)]

  n <- length(d)

  if (n < 30L) {
    return(
      c(
        ci_low = NA_real_,
        ci_high = NA_real_,
        p_value = NA_real_
      )
    )
  }

  L <- min(
    max(1L, block_length),
    n
  )

  starts <- seq_len(
    n - L + 1L
  )

  n_blocks <- ceiling(
    n / L
  )

  draw_mean <- function(x) {
    chosen <- sample(
      starts,
      n_blocks,
      replace = TRUE
    )

    idx <- unlist(
      lapply(
        chosen,
        function(s) {
          s:(s + L - 1L)
        }
      )
    )

    idx <- idx[seq_len(n)]

    mean(
      x[idx]
    )
  }

  set.seed(seed)

  boot <- replicate(
    B,
    draw_mean(d)
  )

  ci <- stats::quantile(
    boot,
    c(0.025, 0.975),
    names = FALSE,
    na.rm = TRUE
  )

  # Null-centered bootstrap p-value.
  d0 <- d - mean(d)

  set.seed(seed + 99991L)

  null_boot <- replicate(
    B,
    draw_mean(d0)
  )

  p <- mean(
    abs(null_boot) >=
      abs(mean(d))
  )

  c(
    ci_low = ci[1L],
    ci_high = ci[2L],
    p_value = p
  )
}


comparison_pairs <- list(
  c("HAR_J", "HAR_RV"),
  c("HARQ", "HAR_RV"),
  c("HARQ_F", "HAR_RV"),
  c("HARQ_F", "HARQ"),
  c("REALGARCH", "GARCH_11"),
  c("REALGARCH", "HAR_RV"),
  c("HEAVY_RM", "GARCH_11"),
  c("HEAVY_RM", "HAR_RV"),
  c("HARQ", "GARCH_11"),
  c("HARQ_F", "GARCH_11")
)

dm_rows <- list()
boot_rows <- list()

cc <- 1L

for (h in cfg$horizons) {
  for (pair in comparison_pairs) {
    for (loss in c("QLIKE", "SE")) {
      ld <- paired_loss_diff(
        forecasts,
        h,
        pair[1L],
        pair[2L],
        loss
      )

      if (length(ld$diff) == 0L) {
        next
      }

      dm <- dm_test_from_diff(
        ld$diff,
        h
      )

      boot <- block_bootstrap_mean(
        ld$diff,
        cfg$bootstrap_B,
        max(
          cfg$bootstrap_block_length,
          2L * h
        ),
        cfg$seed +
          1000L * h +
          cc
      )

      dm_rows[[cc]] <- data.frame(
        horizon = h,
        model_A = pair[1L],
        model_B = pair[2L],
        loss = loss,
        n = unname(dm["n"]),
        mean_loss_diff_A_minus_B =
          unname(dm["mean_loss_diff"]),
        statistic =
          unname(dm["statistic"]),
        p_value =
          unname(dm["p_value"]),
        stringsAsFactors = FALSE
      )

      boot_rows[[cc]] <- data.frame(
        horizon = h,
        model_A = pair[1L],
        model_B = pair[2L],
        loss = loss,
        n = length(ld$diff),
        mean_loss_diff_A_minus_B =
          mean(ld$diff),
        ci_low =
          unname(boot["ci_low"]),
        ci_high =
          unname(boot["ci_high"]),
        p_boot_two_sided =
          unname(boot["p_value"]),
        block_length =
          max(
            cfg$bootstrap_block_length,
            2L * h
          ),
        B = cfg$bootstrap_B,
        stringsAsFactors = FALSE
      )

      cc <- cc + 1L
    }
  }
}

dm_tests <- if (
  length(dm_rows) > 0L
) {
  do.call(rbind, dm_rows)
} else {
  data.frame()
}

bootstrap_tests <- if (
  length(boot_rows) > 0L
) {
  do.call(rbind, boot_rows)
} else {
  data.frame()
}


# ==============================================================================
# 14. STABILITY DIAGNOSTICS
# ==============================================================================

diag_groups <- split(
  forecasts,
  interaction(
    forecasts$horizon,
    forecasts$model,
    drop = TRUE
  )
)

stability <- do.call(
  rbind,
  lapply(
    diag_groups,
    function(df) {
      z <- df[
        is.finite(df$actual_rv) &
          is.finite(df$forecast_rv),
        ,
        drop = FALSE
      ]

      if (nrow(z) == 0L) {
        return(
          data.frame(
            horizon = unique(df$horizon),
            model = unique(df$model),
            n = 0L,
            max_forecast_rv = NA_real_,
            p99_ratio = NA_real_,
            pct_ratio_gt_10 = NA_real_,
            pct_ratio_lt_0_1 = NA_real_
          )
        )
      }

      ratio <- z$forecast_rv /
        z$actual_rv

      data.frame(
        horizon = unique(z$horizon),
        model = unique(z$model),
        n = nrow(z),
        max_forecast_rv =
          max(z$forecast_rv),
        p99_ratio =
          as.numeric(
            stats::quantile(
              ratio,
              0.99,
              names = FALSE
            )
          ),
        pct_ratio_gt_10 =
          mean(ratio > 10),
        pct_ratio_lt_0_1 =
          mean(ratio < 0.1),
        stringsAsFactors = FALSE
      )
    }
  )
)

rownames(stability) <- NULL


# ==============================================================================
# 15. PLOTS
# ==============================================================================

for (h in cfg$horizons) {
  pdat <- forecasts[
    forecasts$horizon == h,
    ,
    drop = FALSE
  ]

  actual <- pdat[
    !duplicated(pdat$origin_date),
    c(
      "origin_date",
      "actual_rv"
    ),
    drop = FALSE
  ]

  actual$actual_vol <- sqrt(
    actual$actual_rv
  )

  pdat$forecast_vol <- sqrt(
    pdat$forecast_rv
  )

  p <- ggplot2::ggplot() +
    ggplot2::geom_line(
      data = actual,
      ggplot2::aes(
        origin_date,
        actual_vol
      ),
      linewidth = 0.7
    ) +
    ggplot2::geom_line(
      data = pdat,
      ggplot2::aes(
        origin_date,
        forecast_vol,
        linetype = model
      ),
      linewidth = 0.45,
      na.rm = TRUE
    ) +
    ggplot2::labs(
      title = paste0(
        "BTC realized-volatility horse race — h=",
        h
      ),
      subtitle = "Binance BTCUSDT 5m; actual line + model forecasts",
      x = NULL,
      y = "sqrt(average future RV), %",
      linetype = "Model"
    ) +
    ggplot2::theme_minimal(
      base_size = 11
    )

  ggplot2::ggsave(
    file.path(
      cfg$output_dir,
      paste0(
        "forecast_h",
        h,
        ".png"
      )
    ),
    p,
    width = 12,
    height = 6.5,
    dpi = 150
  )

  # Cumulative QLIKE relative to HAR_RV.
  har <- pdat[
    pdat$model == "HAR_RV",
    c(
      "origin_date",
      "actual_rv",
      "forecast_rv"
    ),
    drop = FALSE
  ]

  names(har)[3L] <- "har_fc"

  others <- setdiff(
    unique(pdat$model),
    "HAR_RV"
  )

  cum_rows <- list()
  kk <- 1L

  for (m in others) {
    x <- pdat[
      pdat$model == m,
      c(
        "origin_date",
        "forecast_rv"
      ),
      drop = FALSE
    ]

    names(x)[2L] <- "model_fc"

    z <- merge(
      har,
      x,
      by = "origin_date"
    )

    z <- z[
      is.finite(z$actual_rv) &
        is.finite(z$har_fc) &
        is.finite(z$model_fc),
      ,
      drop = FALSE
    ]

    if (nrow(z) == 0L) {
      next
    }

    d <- qlike_loss(
      z$actual_rv,
      z$model_fc,
      cfg$forecast_floor
    ) -
      qlike_loss(
        z$actual_rv,
        z$har_fc,
        cfg$forecast_floor
      )

    cum_rows[[kk]] <- data.frame(
      origin_date = z$origin_date,
      model = m,
      cumulative_qlike_diff = cumsum(d),
      stringsAsFactors = FALSE
    )

    kk <- kk + 1L
  }

  if (length(cum_rows) > 0L) {
    cdat <- do.call(
      rbind,
      cum_rows
    )

    p2 <- ggplot2::ggplot(
      cdat,
      ggplot2::aes(
        origin_date,
        cumulative_qlike_diff,
        linetype = model
      )
    ) +
      ggplot2::geom_hline(
        yintercept = 0,
        linewidth = 0.35
      ) +
      ggplot2::geom_line(
        linewidth = 0.6
      ) +
      ggplot2::labs(
        title = paste0(
          "Cumulative QLIKE relative to HAR-RV — h=",
          h
        ),
        subtitle = "Downward = model beats HAR-RV cumulatively",
        x = NULL,
        y = "Cumulative QLIKE(model - HAR-RV)",
        linetype = "Model"
      ) +
      ggplot2::theme_minimal(
        base_size = 11
      )

    ggplot2::ggsave(
      file.path(
        cfg$output_dir,
        paste0(
          "cumulative_qlike_vs_har_h",
          h,
          ".png"
        )
      ),
      p2,
      width = 12,
      height = 6.5,
      dpi = 150
    )
  }
}


# ==============================================================================
# 16. SAVE OUTPUTS
# ==============================================================================

utils::write.csv(
  forecasts,
  file.path(
    cfg$output_dir,
    "forecasts.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  metrics,
  file.path(
    cfg$output_dir,
    "metrics.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  dm_tests,
  file.path(
    cfg$output_dir,
    "dm_tests.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  bootstrap_tests,
  file.path(
    cfg$output_dir,
    "bootstrap_tests.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  stability,
  file.path(
    cfg$output_dir,
    "stability_diagnostics.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  heavy_parameters,
  file.path(
    cfg$output_dir,
    "heavy_parameters.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  model_failures,
  file.path(
    cfg$output_dir,
    "model_failures.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  dat[
    ,
    c(
      "date",
      "RV",
      "BV",
      "J",
      "RQ",
      "RS_plus",
      "RS_minus",
      "ret_pct"
    )
  ],
  file.path(
    cfg$output_dir,
    "daily_realized_measures.csv"
  ),
  row.names = FALSE
)


config_lines <- c(
  paste0(
    "Run time: ",
    Sys.time()
  ),
  paste0(
    "QUICK_RUN: ",
    QUICK_RUN
  ),
  paste0(
    "Data: Binance Spot ",
    cfg$symbol,
    " ",
    cfg$interval
  ),
  paste0(
    "Sample: ",
    cfg$start_date,
    " to ",
    cfg$end_date
  ),
  paste0(
    "OOS origins: ",
    length(oos_idx)
  ),
  paste0(
    "Train window: ",
    cfg$train_window
  ),
  paste0(
    "Horizons: ",
    paste(
      cfg$horizons,
      collapse = ","
    )
  ),
  paste0(
    "HAR range guard: ",
    cfg$har_range_guard
  ),
  paste0(
    "Bootstrap B: ",
    cfg$bootstrap_B
  ),
  "",
  "Realized measures:",
  "RV = sum 5m returns^2",
  "BV = (pi/2) sum |r_i||r_i-1|",
  "J = max(RV-BV,0)",
  "RQ = (M/3) sum r_i^4",
  "",
  "Primary comparisons:",
  "HARQ vs HAR_RV",
  "HARQ_F vs HAR_RV",
  "HAR_J vs HAR_RV",
  "REALGARCH vs GARCH_11",
  "REALGARCH vs HAR_RV",
  "HEAVY_RM vs GARCH_11",
  "HEAVY_RM vs HAR_RV",
  "",
  "Interpretation:",
  "mean_loss_diff_A_minus_B < 0 means model A is better.",
  "For QLIKE, lower is better."
)

writeLines(
  config_lines,
  file.path(
    cfg$output_dir,
    "run_config.txt"
  )
)


# ==============================================================================
# 17. CONSOLE REPORT
# ==============================================================================

cat(
  "\n\n======================= OOS METRICS =======================\n"
)

print(
  metrics,
  row.names = FALSE,
  digits = 5
)

cat(
  "\n===================== DIEBOLD-MARIANO =====================\n"
)

print(
  dm_tests,
  row.names = FALSE,
  digits = 5
)

cat(
  "\n================ MOVING-BLOCK BOOTSTRAP ===================\n"
)

print(
  bootstrap_tests,
  row.names = FALSE,
  digits = 5
)

cat(
  "\n=================== STABILITY DIAGNOSTICS =================\n"
)

print(
  stability,
  row.names = FALSE,
  digits = 5
)

cat(
  "\n===================== HEAVY PARAMETERS ====================\n"
)

print(
  tail(
    heavy_parameters,
    10L
  ),
  row.names = FALSE,
  digits = 5
)

cat(
  "\n============================================================\n"
)

cat(
  "Outputs written to: ",
  normalizePath(
    cfg$output_dir,
    winslash = "/",
    mustWork = FALSE
  ),
  "\n",
  sep = ""
)

cat(
  "============================================================\n"
)

cat(
  "\nREAD THESE FIRST:\n",
  "  1. HARQ vs HAR_RV on QLIKE\n",
  "  2. HARQ_F vs HAR_RV on QLIKE\n",
  "  3. REALGARCH vs GARCH_11 and HAR_RV\n",
  "  4. HEAVY_RM vs GARCH_11 and HAR_RV\n",
  "  5. HAR_J vs HAR_RV\n\n",
  sep = ""
)

cat(
  "A serious result requires lower average OOS QLIKE AND paired inference\n",
  "that points in the same direction. Do not select a winner from RMSE alone.\n\n",
  sep = ""
)
