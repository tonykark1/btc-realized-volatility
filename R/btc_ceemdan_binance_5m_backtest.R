# ==============================================================================
# BTC VOLATILITY FORECASTING WITH CAUSAL CEEMDAN FEATURES — BINANCE 5m
# Incremental-information experiment: HAR / GARCH / CEEMDAN-Ridge
# ==============================================================================
#
# WHY THIS FILE EXISTS
# --------------------
# The earlier CEEMDAN-AR experiment was numerically unstable because it:
#
#   1) decomposed log(RV) into fast / medium / slow components,
#   2) forecast each component independently with an AR model,
#   3) summed those forecasts,
#   4) exponentiated the result.
#
# Small errors in component forecasts could destroy the in-sample cancellation
# between IMFs and produce enormous variance forecasts after exp().
#
# THIS FILE DOES NOT FORECAST THE IMFs.
#
# Instead, at each historical date s it computes a CEEMDAN decomposition using
# ONLY information available through s, extracts endpoint/multiscale features,
# and stores that causal snapshot. Those snapshots are then used in direct,
# regularized forecasts of future realized variance.
#
# Main research question:
#
#   Does causal multiscale information from CEEMDAN improve genuinely
#   out-of-sample BTC volatility forecasts beyond strong conventional models?
#
# Models:
#   - EWMA
#   - GARCH(1,1)-t
#   - HAR-RV level, direct horizon
#   - log HAR-RV + Duan-style smearing correction, direct horizon
#   - HAR-RV-J (when intraday RV/BV/jumps are available)
#   - HAR-Ridge (regularized HAR-only feature benchmark)
#   - CEEMDAN-Ridge (HAR features + causal CEEMDAN features)
#   - GARCH + CEEMDAN residual correction
#
# Horizons:
#   direct forecasts of average future variance:
#
#       RVbar_{t,h} = mean(RV_{t+1}, ..., RV_{t+h})
#
# Anti-leakage rules:
#   - CEEMDAN at date s uses data only through s.
#   - Historical CEEMDAN features are NOT reconstructed retrospectively from a
#     decomposition performed at a later date.
#   - Ridge training at forecast origin t only uses historical origins s whose
#     h-day outcomes were fully known by t: s + h <= t.
#   - Lambda is selected by anchored forward validation within the training set.
#   - Prediction clipping, if enabled, uses bounds estimated from training
#     outcomes only.
#
# Data source:
#   Binance Spot BTCUSDT 5-minute klines downloaded automatically from
#   Binance's public market-data infrastructure. No API key is required.
#   The script then computes:
#
#       RV_t = sum_i r_{t,i}^2
#       BV_t = (pi/2) sum_i |r_{t,i}| |r_{t,i-1}|
#       J_t  = max(RV_t - BV_t, 0)
#
# The default downloader uses Binance's public market-data REST endpoint and
# caches all 5-minute candles locally. A bulk-archive fallback is also built in.
#
# ==============================================================================


# ==============================================================================
# 0. CONFIG
# ==============================================================================

QUICK_RUN <- TRUE

cfg <- list(
  seed = 12345L,
  
  # ------------------------------- Data ---------------------------------------
  # Binance Spot 5-minute BTCUSDT data. No API key is required.
  binance_symbol = "BTCUSDT",
  binance_interval = "5m",
  
  # 2019 is enough history for the default 2025 OOS experiment while keeping
  # the first download manageable. Change to 2017-08-17 for the earliest
  # BTCUSDT history available on Binance.
  binance_start_date = as.Date("2019-01-01"),
  
  # Use the last fully completed UTC day by default.
  binance_end_date = Sys.Date() - 1L,
  
  # "rest_api" = paginate Binance market-data-only /api/v3/klines.
  # "archive"  = Binance public monthly/daily ZIP archives.
  # REST is the default because it uses the public kline endpoint directly.
  binance_download_mode = "rest_api",
  
  # Public market-data-only endpoint: no authentication / API key.
  binance_rest_base = "https://data-api.binance.vision",
  binance_archive_base = "https://data.binance.vision",
  
  # REST pagination / robustness.
  binance_api_limit = 1000L,
  binance_request_pause = 0.06,
  binance_max_retries = 6L,
  binance_retry_base_seconds = 1.0,
  
  # If REST fails (for example because of a transient regional/network issue),
  # automatically try Binance's downloadable public archives.
  binance_fallback_to_archive = TRUE,
  
  # Persistent raw-candle cache. Subsequent runs only fetch missing candles.
  binance_raw_cache = "cache/binance_raw/BTCUSDT_5m.rds",
  binance_refresh_cache = FALSE,
  
  # Research-quality data checks.
  intraday_tz = "UTC",
  expected_bars_per_day = 288L,        # 24h * 12 five-minute bars
  min_bars_per_day = 285L,
  drop_incomplete_days = TRUE,
  
  # -------------------------- Forecast experiment -----------------------------
  horizons = c(1L, 5L, 10L),
  
  # First date eligible for OOS forecasting. QUICK_RUN keeps only most recent
  # max_oos_origins after this date.
  test_start = as.Date("2025-01-01"),
  max_oos_origins = if (QUICK_RUN) 180L else NA_integer_,
  forecast_every = 1L,
  
  # Raw history used for conventional baseline fitting.
  baseline_train_window = if (QUICK_RUN) 730L else 1460L,
  
  # Number of observations supplied to each causal CEEMDAN decomposition.
  ceemdan_window = if (QUICK_RUN) 730L else 1095L,
  
  # Number of historical causal feature snapshots used for each ridge fit.
  ridge_train_rows = if (QUICK_RUN) 365L else 730L,
  ridge_min_rows = if (QUICK_RUN) 180L else 300L,
  
  # ------------------------------- CEEMDAN ------------------------------------
  ceemdan_ensemble_size = if (QUICK_RUN) 30L else 100L,
  ceemdan_noise_strength = 0.20,
  ceemdan_S_number = 4L,
  ceemdan_num_siftings = 50L,
  ceemdan_threads = 0L,
  ceemdan_num_imfs = 0L,
  
  # Frequency buckets: dominant cycle length in days.
  fast_max_period = 4,
  medium_max_period = 30,
  
  # ------------------------------ HAR -----------------------------------------
  har_week = 5L,
  har_month = 22L,
  
  # ------------------------------ EWMA ----------------------------------------
  ewma_lambda = 0.94,
  
  # ------------------------------ Ridge ---------------------------------------
  ridge_lambda_grid = 10^seq(-5, 3, length.out = 35L),
  ridge_validation_folds = 3L,
  ridge_validation_size = if (QUICK_RUN) 30L else 60L,
  
  # Largest lambda within one standard error of minimum validation QLIKE.
  ridge_one_se_rule = TRUE,
  
  # Robust operational guardrail. This is NOT based on future data.
  # It clips predicted log variance to train-only outcome quantiles plus margin.
  prediction_guardrail = TRUE,
  guardrail_probs = c(0.005, 0.995),
  guardrail_log_margin = 1.0,
  
  # ------------------------- Numerical settings -------------------------------
  rv_floor = 1e-8,
  forecast_floor = 1e-8,
  
  # ----------------------------- Inference ------------------------------------
  bootstrap_B = if (QUICK_RUN) 500L else 2000L,
  bootstrap_block_length = 14L,
  
  # ------------------------- Cache and outputs --------------------------------
  use_ceemdan_cache = TRUE,
  use_garch_cache = TRUE,
  cache_dir = "cache/btc_ceemdan_binance_5m",
  output_dir = "results/btc_ceemdan_binance_5m"
)

set.seed(cfg$seed)


# ==============================================================================
# 1. PACKAGE SETUP
# ==============================================================================

required_pkgs <- c(
  "curl",
  "jsonlite",
  "data.table",
  "Rlibeemd",
  "rugarch",
  "glmnet",
  "ggplot2"
)

install_if_missing <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  
  if (length(missing) > 0L) {
    message("Installing missing packages: ", paste(missing, collapse = ", "))
    install.packages(missing, repos = "https://cloud.r-project.org")
  }
  
  still_missing <- pkgs[
    !vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)
  ]
  
  if (length(still_missing) > 0L) {
    stop(
      "Could not install/load: ",
      paste(still_missing, collapse = ", "),
      "\nInstall them manually, then rerun."
    )
  }
}

install_if_missing(required_pkgs)

dir.create(cfg$output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cfg$cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(
  file.path(cfg$cache_dir, "ceemdan"),
  recursive = TRUE,
  showWarnings = FALSE
)
dir.create(
  file.path(cfg$cache_dir, "garch"),
  recursive = TRUE,
  showWarnings = FALSE
)


# ==============================================================================
# 2. BINANCE 5-MINUTE DATA
# ==============================================================================

# Binance public kline columns:
#   open_time, open, high, low, close, volume, close_time, quote_volume,
#   number_of_trades, taker_buy_base_volume, taker_buy_quote_volume, ignore
#
# IMPORTANT:
# Binance's public SPOT archive changed timestamps from milliseconds to
# microseconds from 2025-01-01 onward. normalize_binance_timestamp() accepts both.

interval_to_ms <- function(interval) {
  lookup <- c(
    "1m" = 60 * 1000,
    "3m" = 3 * 60 * 1000,
    "5m" = 5 * 60 * 1000,
    "15m" = 15 * 60 * 1000,
    "30m" = 30 * 60 * 1000,
    "1h" = 60 * 60 * 1000,
    "2h" = 2 * 60 * 60 * 1000,
    "4h" = 4 * 60 * 60 * 1000,
    "6h" = 6 * 60 * 60 * 1000,
    "8h" = 8 * 60 * 60 * 1000,
    "12h" = 12 * 60 * 60 * 1000,
    "1d" = 24 * 60 * 60 * 1000
  )
  
  if (!interval %in% names(lookup)) {
    stop(
      "Unsupported interval in this script: ", interval,
      ". Add it to interval_to_ms() if needed."
    )
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


normalize_binance_timestamp_seconds <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  
  # Milliseconds are ~1e12; microseconds are ~1e15.
  ifelse(
    abs(x) >= 1e14,
    x / 1e6,
    x / 1e3
  )
}


empty_kline_table <- function() {
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


standardize_kline_matrix <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(empty_kline_table())
  }
  
  x <- as.data.frame(
    x,
    stringsAsFactors = FALSE
  )
  
  if (ncol(x) < 11L) {
    stop(
      "Unexpected Binance kline response: expected at least 11 columns, got ",
      ncol(x)
    )
  }
  
  open_raw <- suppressWarnings(as.numeric(x[[1L]]))
  close_raw <- suppressWarnings(as.numeric(x[[7L]]))
  
  # Normalize archive microseconds (2025+) and REST milliseconds to one common
  # internal representation: MILLISECONDS since Unix epoch. This matters if
  # REST and archive data are ever merged in the same persistent cache.
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


fetch_binance_klines_rest <- function(
    symbol,
    interval,
    start_ms,
    end_ms,
    cfg
) {
  if (start_ms > end_ms) {
    return(empty_kline_table())
  }
  
  step_ms <- interval_to_ms(interval)
  cursor <- start_ms
  chunks <- list()
  chunk_counter <- 1L
  
  message(
    "Downloading Binance REST klines: ",
    symbol, " ", interval
  )
  
  while (cursor <= end_ms) {
    url <- paste0(
      cfg$binance_rest_base,
      "/api/v3/klines",
      "?symbol=", utils::URLencode(symbol, reserved = TRUE),
      "&interval=", utils::URLencode(interval, reserved = TRUE),
      "&startTime=", sprintf("%.0f", cursor),
      "&endTime=", sprintf("%.0f", end_ms),
      "&limit=", cfg$binance_api_limit
    )
    
    response <- NULL
    
    for (attempt in seq_len(cfg$binance_max_retries)) {
      response <- tryCatch(
        curl::curl_fetch_memory(url),
        error = function(e) e
      )
      
      if (!inherits(response, "error")) {
        if (response$status_code == 200L) {
          break
        }
        
        # Binance may return 429 for rate limiting or 418 after repeated limits.
        if (response$status_code %in% c(418L, 429L, 500L, 502L, 503L, 504L)) {
          wait <- cfg$binance_retry_base_seconds * 2^(attempt - 1L)
          
          message(
            "HTTP ", response$status_code,
            " from Binance; retry ", attempt, "/",
            cfg$binance_max_retries,
            " after ", round(wait, 1), "s"
          )
          
          Sys.sleep(wait)
          next
        }
        
        body <- tryCatch(
          rawToChar(response$content),
          error = function(e) ""
        )
        
        stop(
          "Binance REST HTTP ", response$status_code,
          ". Response: ", substr(body, 1L, 500L)
        )
      }
      
      wait <- cfg$binance_retry_base_seconds * 2^(attempt - 1L)
      
      message(
        "Binance request error; retry ", attempt, "/",
        cfg$binance_max_retries,
        " after ", round(wait, 1), "s"
      )
      
      Sys.sleep(wait)
    }
    
    if (
      inherits(response, "error") ||
      is.null(response) ||
      response$status_code != 200L
    ) {
      stop(
        "Binance REST download failed after ",
        cfg$binance_max_retries,
        " retries."
      )
    }
    
    parsed <- jsonlite::fromJSON(
      rawToChar(response$content),
      simplifyVector = TRUE
    )
    
    if (length(parsed) == 0L) {
      break
    }
    
    chunk <- standardize_kline_matrix(parsed)
    
    if (nrow(chunk) == 0L) {
      break
    }
    
    chunks[[chunk_counter]] <- chunk
    chunk_counter <- chunk_counter + 1L
    
    last_open <- max(chunk$open_time_ms)
    
    if (!is.finite(last_open) || last_open < cursor) {
      stop("Binance pagination failed to advance.")
    }
    
    cursor <- last_open + step_ms
    
    if ((chunk_counter %% 25L) == 0L) {
      message(
        "  downloaded through ",
        as.POSIXct(last_open / 1000, origin = "1970-01-01", tz = "UTC")
      )
    }
    
    if (nrow(chunk) < cfg$binance_api_limit) {
      break
    }
    
    Sys.sleep(cfg$binance_request_pause)
  }
  
  if (length(chunks) == 0L) {
    return(empty_kline_table())
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


safe_curl_download <- function(url, dest, retries, retry_base_seconds) {
  for (attempt in seq_len(retries)) {
    ok <- tryCatch(
      {
        curl::curl_download(
          url = url,
          destfile = dest,
          quiet = TRUE,
          mode = "wb"
        )
        TRUE
      },
      error = function(e) FALSE
    )
    
    if (ok && file.exists(dest) && file.info(dest)$size > 0) {
      return(TRUE)
    }
    
    if (file.exists(dest)) {
      unlink(dest)
    }
    
    Sys.sleep(
      retry_base_seconds * 2^(attempt - 1L)
    )
  }
  
  FALSE
}


read_binance_archive_zip <- function(zip_path) {
  listing <- utils::unzip(
    zip_path,
    list = TRUE
  )
  
  csv_names <- listing$Name[
    grepl("\\.csv$", listing$Name, ignore.case = TRUE)
  ]
  
  if (length(csv_names) == 0L) {
    stop("No CSV found inside Binance archive: ", zip_path)
  }
  
  exdir <- tempfile("binance_unzip_")
  dir.create(exdir, recursive = TRUE)
  
  on.exit(
    unlink(exdir, recursive = TRUE, force = TRUE),
    add = TRUE
  )
  
  utils::unzip(
    zip_path,
    files = csv_names[1L],
    exdir = exdir
  )
  
  csv_path <- file.path(
    exdir,
    csv_names[1L]
  )
  
  x <- data.table::fread(
    csv_path,
    header = FALSE,
    showProgress = FALSE,
    data.table = FALSE
  )
  
  standardize_kline_matrix(x)
}


fetch_binance_archive_month_or_days <- function(
    symbol,
    interval,
    month_start,
    requested_start,
    requested_end,
    cfg,
    archive_cache_dir
) {
  next_month <- seq(
    month_start,
    by = "month",
    length.out = 2L
  )[2L]
  
  month_end <- next_month - 1L
  
  use_start <- max(
    month_start,
    requested_start
  )
  
  use_end <- min(
    month_end,
    requested_end
  )
  
  if (use_start > use_end) {
    return(empty_kline_table())
  }
  
  ym <- format(
    month_start,
    "%Y-%m"
  )
  
  monthly_name <- paste0(
    symbol, "-", interval, "-", ym, ".zip"
  )
  
  monthly_url <- paste0(
    cfg$binance_archive_base,
    "/data/spot/monthly/klines/",
    symbol, "/",
    interval, "/",
    monthly_name
  )
  
  monthly_path <- file.path(
    archive_cache_dir,
    monthly_name
  )
  
  # For completed months, try the compact monthly archive first.
  if (month_end < Sys.Date()) {
    if (!file.exists(monthly_path)) {
      ok <- safe_curl_download(
        monthly_url,
        monthly_path,
        cfg$binance_max_retries,
        cfg$binance_retry_base_seconds
      )
      
      if (!ok && file.exists(monthly_path)) {
        unlink(monthly_path)
      }
    }
    
    if (file.exists(monthly_path)) {
      x <- read_binance_archive_zip(
        monthly_path
      )
      
      sec <- normalize_binance_timestamp_seconds(
        x$open_time_ms
      )
      
      dates <- as.Date(
        as.POSIXct(
          sec,
          origin = "1970-01-01",
          tz = "UTC"
        )
      )
      
      keep <- dates >= use_start &
        dates <= use_end
      
      return(
        x[keep, , drop = FALSE]
      )
    }
  }
  
  # Monthly file unavailable or current/partial month: use daily archives.
  daily_chunks <- list()
  cc <- 1L
  
  for (d in seq(use_start, use_end, by = "day")) {
    ymd <- format(d, "%Y-%m-%d")
    
    daily_name <- paste0(
      symbol, "-", interval, "-", ymd, ".zip"
    )
    
    daily_url <- paste0(
      cfg$binance_archive_base,
      "/data/spot/daily/klines/",
      symbol, "/",
      interval, "/",
      daily_name
    )
    
    daily_path <- file.path(
      archive_cache_dir,
      daily_name
    )
    
    if (!file.exists(daily_path)) {
      ok <- safe_curl_download(
        daily_url,
        daily_path,
        cfg$binance_max_retries,
        cfg$binance_retry_base_seconds
      )
      
      if (!ok) {
        if (file.exists(daily_path)) {
          unlink(daily_path)
        }
        
        warning(
          "Could not download Binance daily archive: ",
          ymd
        )
        
        next
      }
    }
    
    daily_chunks[[cc]] <- read_binance_archive_zip(
      daily_path
    )
    
    cc <- cc + 1L
  }
  
  if (length(daily_chunks) == 0L) {
    return(empty_kline_table())
  }
  
  out <- do.call(rbind, daily_chunks)
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


fetch_binance_klines_archive <- function(
    symbol,
    interval,
    start_date,
    end_date,
    cfg
) {
  archive_cache_dir <- file.path(
    dirname(cfg$binance_raw_cache),
    "archives",
    symbol,
    interval
  )
  
  dir.create(
    archive_cache_dir,
    recursive = TRUE,
    showWarnings = FALSE
  )
  
  first_month <- as.Date(
    format(start_date, "%Y-%m-01")
  )
  
  last_month <- as.Date(
    format(end_date, "%Y-%m-01")
  )
  
  months <- seq(
    first_month,
    last_month,
    by = "month"
  )
  
  chunks <- vector(
    "list",
    length(months)
  )
  
  message(
    "Downloading Binance public archives: ",
    symbol, " ", interval
  )
  
  for (j in seq_along(months)) {
    message(
      "  archive month ",
      format(months[j], "%Y-%m"),
      " [", j, "/", length(months), "]"
    )
    
    chunks[[j]] <- fetch_binance_archive_month_or_days(
      symbol = symbol,
      interval = interval,
      month_start = months[j],
      requested_start = start_date,
      requested_end = end_date,
      cfg = cfg,
      archive_cache_dir = archive_cache_dir
    )
  }
  
  chunks <- chunks[
    vapply(
      chunks,
      nrow,
      integer(1)
    ) > 0L
  ]
  
  if (length(chunks) == 0L) {
    stop("Binance archive downloader returned no klines.")
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


load_binance_raw_klines <- function(cfg) {
  cache_path <- cfg$binance_raw_cache
  
  dir.create(
    dirname(cache_path),
    recursive = TRUE,
    showWarnings = FALSE
  )
  
  # Request one extra UTC day before the intended sample so the first day's
  # first 5-minute return has a preceding close.
  requested_start <- cfg$binance_start_date - 1L
  requested_end <- cfg$binance_end_date
  
  if (requested_end < requested_start) {
    stop("binance_end_date must be after binance_start_date.")
  }
  
  cached <- NULL
  
  if (
    file.exists(cache_path) &&
    !cfg$binance_refresh_cache
  ) {
    cached <- tryCatch(
      readRDS(cache_path),
      error = function(e) NULL
    )
    
    if (!is.null(cached) && nrow(cached) > 0L) {
      message(
        "Loaded cached Binance candles: ",
        nrow(cached)
      )
    }
  }
  
  step_ms <- interval_to_ms(
    cfg$binance_interval
  )
  
  requested_start_ms <- date_to_ms(
    requested_start
  )
  
  # End of final requested UTC day.
  requested_end_ms <- date_to_ms(
    requested_end + 1L
  ) - 1
  
  if (
    !is.null(cached) &&
    nrow(cached) > 0L
  ) {
    cached <- cached[
      is.finite(cached$open_time_ms),
      ,
      drop = FALSE
    ]
    
    cached <- cached[
      !duplicated(cached$open_time_ms),
      ,
      drop = FALSE
    ]
    
    cached <- cached[
      order(cached$open_time_ms),
      ,
      drop = FALSE
    ]
    
    cache_min <- min(cached$open_time_ms)
    cache_max <- max(cached$open_time_ms)
    
    pieces <- list(cached)
    pp <- 2L
    
    if (cache_min > requested_start_ms) {
      missing_end <- cache_min - step_ms
      
      if (identical(cfg$binance_download_mode, "rest_api")) {
        left <- tryCatch(
          fetch_binance_klines_rest(
            cfg$binance_symbol,
            cfg$binance_interval,
            requested_start_ms,
            missing_end,
            cfg
          ),
          error = function(e) {
            warning(conditionMessage(e))
            NULL
          }
        )
      } else {
        left <- NULL
      }
      
      if (
        (is.null(left) || nrow(left) == 0L) &&
        cfg$binance_fallback_to_archive
      ) {
        left <- fetch_binance_klines_archive(
          cfg$binance_symbol,
          cfg$binance_interval,
          requested_start,
          as.Date(
            as.POSIXct(
              missing_end / 1000,
              origin = "1970-01-01",
              tz = "UTC"
            )
          ),
          cfg
        )
      }
      
      if (!is.null(left) && nrow(left) > 0L) {
        pieces[[pp]] <- left
        pp <- pp + 1L
      }
    }
    
    if (cache_max < requested_end_ms - step_ms) {
      missing_start <- cache_max + step_ms
      
      if (identical(cfg$binance_download_mode, "rest_api")) {
        right <- tryCatch(
          fetch_binance_klines_rest(
            cfg$binance_symbol,
            cfg$binance_interval,
            missing_start,
            requested_end_ms,
            cfg
          ),
          error = function(e) {
            warning(conditionMessage(e))
            NULL
          }
        )
      } else {
        right <- NULL
      }
      
      if (
        (is.null(right) || nrow(right) == 0L) &&
        cfg$binance_fallback_to_archive
      ) {
        right_start_date <- as.Date(
          as.POSIXct(
            missing_start / 1000,
            origin = "1970-01-01",
            tz = "UTC"
          )
        )
        
        right <- fetch_binance_klines_archive(
          cfg$binance_symbol,
          cfg$binance_interval,
          right_start_date,
          requested_end,
          cfg
        )
      }
      
      if (!is.null(right) && nrow(right) > 0L) {
        pieces[[pp]] <- right
      }
    }
    
    raw <- do.call(rbind, pieces)
  } else {
    raw <- NULL
    
    if (identical(cfg$binance_download_mode, "rest_api")) {
      raw <- tryCatch(
        fetch_binance_klines_rest(
          cfg$binance_symbol,
          cfg$binance_interval,
          requested_start_ms,
          requested_end_ms,
          cfg
        ),
        error = function(e) {
          warning(
            "REST downloader failed: ",
            conditionMessage(e)
          )
          NULL
        }
      )
    }
    
    if (
      (is.null(raw) || nrow(raw) == 0L) &&
      (
        identical(cfg$binance_download_mode, "archive") ||
        cfg$binance_fallback_to_archive
      )
    ) {
      message("Trying Binance public archive downloader...")
      
      raw <- fetch_binance_klines_archive(
        cfg$binance_symbol,
        cfg$binance_interval,
        requested_start,
        requested_end,
        cfg
      )
    }
  }
  
  if (is.null(raw) || nrow(raw) == 0L) {
    stop("No Binance klines available after download/cache step.")
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
  
  # Restrict cache to sensible rows but preserve older cached history.
  raw <- raw[
    is.finite(raw$open_time_ms) &
      is.finite(raw$close) &
      raw$close > 0,
    ,
    drop = FALSE
  ]
  
  saveRDS(
    raw,
    cache_path
  )
  
  raw
}


binance_klines_to_daily_rv <- function(raw, cfg) {
  if (nrow(raw) < 1000L) {
    stop("Too few Binance 5-minute candles.")
  }
  
  seconds <- normalize_binance_timestamp_seconds(
    raw$open_time_ms
  )
  
  raw$datetime <- as.POSIXct(
    seconds,
    origin = "1970-01-01",
    tz = cfg$intraday_tz
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
  
  # Drop duplicate timestamps after timestamp normalization.
  raw <- raw[
    !duplicated(raw$datetime),
    ,
    drop = FALSE
  ]
  
  # Close-to-close 5-minute returns in percent.
  raw$ret_5m_pct <- c(
    NA_real_,
    100 * diff(
      log(raw$close)
    )
  )
  
  raw$date <- as.Date(
    raw$datetime,
    tz = cfg$intraday_tz
  )
  
  split_idx <- split(
    seq_len(nrow(raw)),
    raw$date
  )
  
  daily_list <- lapply(
    split_idx,
    function(ii) {
      rr <- raw$ret_5m_pct[ii]
      rr <- rr[is.finite(rr)]
      
      n_bars <- length(ii)
      
      if (
        n_bars < cfg$min_bars_per_day ||
        length(rr) < cfg$min_bars_per_day - 1L
      ) {
        return(
          data.frame(
            date = raw$date[ii[length(ii)]],
            close = raw$close[ii[length(ii)]],
            rv_pct2 = NA_real_,
            bv_pct2 = NA_real_,
            jump_pct2 = NA_real_,
            n_intraday_bars = n_bars,
            complete_day = FALSE,
            stringsAsFactors = FALSE
          )
        )
      }
      
      rv <- sum(
        rr^2
      )
      
      bv <- (pi / 2) * sum(
        abs(rr[-1L]) *
          abs(rr[-length(rr)])
      )
      
      jump <- max(
        rv - bv,
        0
      )
      
      data.frame(
        date = raw$date[ii[length(ii)]],
        close = raw$close[ii[length(ii)]],
        rv_pct2 = rv,
        bv_pct2 = bv,
        jump_pct2 = jump,
        n_intraday_bars = n_bars,
        complete_day = n_bars >= cfg$expected_bars_per_day,
        stringsAsFactors = FALSE
      )
    }
  )
  
  daily <- do.call(
    rbind,
    daily_list
  )
  
  daily <- daily[
    order(daily$date),
    ,
    drop = FALSE
  ]
  
  # Keep only the research sample requested by the user/config.
  daily <- daily[
    daily$date >= cfg$binance_start_date &
      daily$date <= cfg$binance_end_date,
    ,
    drop = FALSE
  ]
  
  incomplete <- daily[
    !daily$complete_day |
      !is.finite(daily$rv_pct2),
    ,
    drop = FALSE
  ]
  
  if (nrow(incomplete) > 0L) {
    warning(
      nrow(incomplete),
      " UTC day(s) had fewer than ",
      cfg$expected_bars_per_day,
      " Binance 5-minute candles. See binance_daily_quality.csv."
    )
  }
  
  quality <- daily[
    ,
    c(
      "date",
      "n_intraday_bars",
      "complete_day"
    )
  ]
  
  utils::write.csv(
    quality,
    file.path(
      cfg$output_dir,
      "binance_daily_quality.csv"
    ),
    row.names = FALSE
  )
  
  if (cfg$drop_incomplete_days) {
    daily <- daily[
      daily$complete_day &
        is.finite(daily$rv_pct2),
      ,
      drop = FALSE
    ]
  } else {
    daily <- daily[
      is.finite(daily$rv_pct2),
      ,
      drop = FALSE
    ]
  }
  
  # Daily close-to-close return, used by GARCH/EWMA.
  daily$ret_pct <- c(
    NA_real_,
    100 * diff(
      log(daily$close)
    )
  )
  
  daily <- daily[
    is.finite(daily$ret_pct) &
      is.finite(daily$rv_pct2) &
      is.finite(daily$bv_pct2) &
      is.finite(daily$jump_pct2),
    ,
    drop = FALSE
  ]
  
  daily$rv_pct2 <- pmax(
    daily$rv_pct2,
    cfg$rv_floor
  )
  
  daily$bv_pct2 <- pmax(
    daily$bv_pct2,
    0
  )
  
  daily$jump_pct2 <- pmax(
    daily$jump_pct2,
    0
  )
  
  rownames(daily) <- NULL
  
  attr(daily, "rv_note") <- paste0(
    "Binance Spot ", cfg$binance_symbol, " ", cfg$binance_interval,
    " UTC realized measures. RV=sum of squared intraday log returns; ",
    "BV=(pi/2) sum |r_i||r_{i-1}|; J=max(RV-BV,0). Units percent^2."
  )
  
  daily
}


raw_binance <- load_binance_raw_klines(
  cfg
)

message(
  "Raw Binance candles available: ",
  nrow(raw_binance)
)

dat <- binance_klines_to_daily_rv(
  raw_binance,
  cfg
)

rv_note <- attr(dat, "rv_note")

dat$log_rv <- log(
  pmax(
    dat$rv_pct2,
    cfg$rv_floor
  )
)

dat$index <- seq_len(
  nrow(dat)
)

has_jump_data <- all(
  is.finite(dat$jump_pct2)
)

message(
  "Valid complete daily observations: ",
  nrow(dat)
)
message(rv_note)
message(
  "HAR-RV-J available: ",
  has_jump_data
)


# ==============================================================================
# 3. GENERAL HELPERS
# ==============================================================================

safe_mean <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) == 0L) NA_real_ else mean(x)
}


safe_sd <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) < 2L) 0 else stats::sd(x)
}


safe_slope <- function(x) {
  x <- as.numeric(x)
  ok <- is.finite(x)
  
  if (sum(ok) < 3L) {
    return(0)
  }
  
  xx <- seq_along(x)[ok]
  yy <- x[ok]
  
  fit <- tryCatch(
    stats::lm(yy ~ xx),
    error = function(e) NULL
  )
  
  if (is.null(fit)) {
    return(0)
  }
  
  b <- stats::coef(fit)
  
  if (length(b) < 2L || !is.finite(b[2L])) {
    0
  } else {
    unname(b[2L])
  }
}


qlike_loss <- function(actual, forecast, eps = 1e-12) {
  actual <- pmax(actual, eps)
  forecast <- pmax(forecast, eps)
  
  ratio <- actual / forecast
  ratio - log(ratio) - 1
}


series_signature <- function(x) {
  x <- as.numeric(x)
  x <- x[is.finite(x)]
  
  if (length(x) == 0L) {
    return("empty")
  }
  
  z <- sum(
    round(x, 6) *
      ((seq_along(x) %% 997L) + 1L)
  )
  
  sprintf("%010.0f", abs(z * 1e4) %% 1e10)
}


future_average <- function(x, origin_index, h) {
  if (origin_index + h > length(x)) {
    return(NA_real_)
  }
  
  mean(x[(origin_index + 1L):(origin_index + h)])
}


current_multiscale_features <- function(rv, week, month, floor_value) {
  n <- length(rv)
  
  if (n < month) {
    return(c(
      har_log_d = NA_real_,
      har_log_w = NA_real_,
      har_log_m = NA_real_,
      rv_d = NA_real_,
      rv_w = NA_real_,
      rv_m = NA_real_
    ))
  }
  
  d <- pmax(rv[n], floor_value)
  w <- pmax(mean(tail(rv, week)), floor_value)
  m <- pmax(mean(tail(rv, month)), floor_value)
  
  c(
    har_log_d = log(d),
    har_log_w = log(w),
    har_log_m = log(m),
    rv_d = d,
    rv_w = w,
    rv_m = m
  )
}


# ==============================================================================
# 4. CAUSAL CEEMDAN
# ==============================================================================

dominant_period <- function(x) {
  x <- as.numeric(x)
  n <- length(x)
  
  if (n < 8L || safe_sd(x) < 1e-12) {
    return(Inf)
  }
  
  x <- x - mean(x)
  sp <- Mod(fft(x))^2
  
  kmax <- floor(n / 2L)
  
  if (kmax < 2L) {
    return(Inf)
  }
  
  idx <- 2L:(kmax + 1L)
  power <- sp[idx]
  
  if (
    !any(is.finite(power)) ||
    max(power, na.rm = TRUE) <= 0
  ) {
    return(Inf)
  }
  
  j <- idx[which.max(power)]
  cycles <- j - 1L
  
  if (cycles <= 0L) {
    return(Inf)
  }
  
  n / cycles
}


classify_period <- function(period, cfg) {
  if (!is.finite(period)) {
    return("slow")
  }
  
  if (period <= cfg$fast_max_period) {
    return("fast")
  }
  
  if (period <= cfg$medium_max_period) {
    return("medium")
  }
  
  "slow"
}


ceemdan_cache_path <- function(
    log_rv,
    origin_date,
    cfg
) {
  sig <- series_signature(log_rv)
  
  file.path(
    cfg$cache_dir,
    "ceemdan",
    sprintf(
      paste0(
        "cee_%s_n%d_e%d_noise%.3f_",
        "fast%.0f_med%.0f_seed%d_sig%s.rds"
      ),
      format(origin_date, "%Y%m%d"),
      length(log_rv),
      cfg$ceemdan_ensemble_size,
      cfg$ceemdan_noise_strength,
      cfg$fast_max_period,
      cfg$medium_max_period,
      cfg$seed,
      sig
    )
  )
}


run_ceemdan_grouped <- function(log_rv, origin_date, cfg) {
  cache_path <- ceemdan_cache_path(
    log_rv,
    origin_date,
    cfg
  )
  
  if (
    cfg$use_ceemdan_cache &&
    file.exists(cache_path)
  ) {
    return(readRDS(cache_path))
  }
  
  origin_seed <- as.integer(
    (cfg$seed + as.integer(origin_date)) %% 2147483646L
  )
  
  if (origin_seed <= 0L) {
    origin_seed <- cfg$seed
  }
  
  decomp <- Rlibeemd::ceemdan(
    input = as.numeric(log_rv),
    num_imfs = cfg$ceemdan_num_imfs,
    ensemble_size = cfg$ceemdan_ensemble_size,
    noise_strength = cfg$ceemdan_noise_strength,
    S_number = cfg$ceemdan_S_number,
    num_siftings = cfg$ceemdan_num_siftings,
    rng_seed = origin_seed,
    threads = cfg$ceemdan_threads
  )
  
  mat <- as.matrix(decomp)
  
  if (ncol(mat) < 2L) {
    stop("CEEMDAN returned fewer than two components.")
  }
  
  n_comp <- ncol(mat)
  periods <- rep(Inf, n_comp)
  
  if (n_comp > 1L) {
    periods[seq_len(n_comp - 1L)] <- vapply(
      seq_len(n_comp - 1L),
      function(j) dominant_period(mat[, j]),
      numeric(1)
    )
  }
  
  buckets <- vapply(
    periods,
    classify_period,
    character(1),
    cfg = cfg
  )
  
  # Final CEEMDAN component is residual/trend.
  buckets[n_comp] <- "slow"
  
  grouped <- matrix(
    0,
    nrow = nrow(mat),
    ncol = 3L,
    dimnames = list(
      NULL,
      c("fast", "medium", "slow")
    )
  )
  
  for (b in colnames(grouped)) {
    jj <- which(buckets == b)
    
    if (length(jj) > 0L) {
      grouped[, b] <- rowSums(
        mat[, jj, drop = FALSE]
      )
    }
  }
  
  reconstruction_error <- max(
    abs(
      rowSums(grouped) -
        as.numeric(log_rv)
    ),
    na.rm = TRUE
  )
  
  out <- list(
    grouped = grouped,
    periods = periods,
    buckets = buckets,
    reconstruction_max_abs_error = reconstruction_error
  )
  
  if (cfg$use_ceemdan_cache) {
    saveRDS(out, cache_path)
  }
  
  out
}


bucket_feature_vector <- function(x, prefix) {
  n <- length(x)
  
  get_tail <- function(k) {
    tail(x, min(k, n))
  }
  
  d1 <- if (n >= 2L) x[n] - x[n - 1L] else 0
  d5 <- if (n >= 6L) x[n] - x[n - 5L] else d1
  
  x5 <- get_tail(5L)
  x22 <- get_tail(22L)
  
  out <- c(
    level = x[n],
    d1 = d1,
    d5 = d5,
    mean5 = safe_mean(x5),
    mean22 = safe_mean(x22),
    sd22 = safe_sd(x22),
    energy5 = safe_mean(x5^2),
    energy22 = safe_mean(x22^2),
    slope5 = safe_slope(x5),
    slope22 = safe_slope(x22)
  )
  
  names(out) <- paste0(
    "ce_",
    prefix,
    "_",
    names(out)
  )
  
  out
}


extract_ceemdan_features <- function(dec) {
  g <- dec$grouped
  
  fast <- bucket_feature_vector(
    g[, "fast"],
    "fast"
  )
  
  medium <- bucket_feature_vector(
    g[, "medium"],
    "medium"
  )
  
  slow <- bucket_feature_vector(
    g[, "slow"],
    "slow"
  )
  
  e22 <- c(
    fast = unname(fast["ce_fast_energy22"]),
    medium = unname(medium["ce_medium_energy22"]),
    slow = unname(slow["ce_slow_energy22"])
  )
  
  denom <- sum(e22)
  
  if (!is.finite(denom) || denom <= 0) {
    shares <- c(
      ce_fast_energy_share22 = 0,
      ce_medium_energy_share22 = 0,
      ce_slow_energy_share22 = 0
    )
  } else {
    shares <- c(
      ce_fast_energy_share22 = e22["fast"] / denom,
      ce_medium_energy_share22 = e22["medium"] / denom,
      ce_slow_energy_share22 = e22["slow"] / denom
    )
  }
  
  c(fast, medium, slow, shares)
}


# ==============================================================================
# 5. GARCH AND EWMA
# ==============================================================================

forecast_garch <- function(train_ret_pct, max_h, cfg) {
  r <- as.numeric(train_ret_pct)
  r <- r[is.finite(r)]
  
  if (length(r) < 250L) {
    return(rep(NA_real_, max_h))
  }
  
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
        data = r,
        solver = "hybrid",
        solver.control = list(trace = 0)
      )
    ),
    error = function(e) NULL
  )
  
  if (is.null(fit)) {
    return(rep(NA_real_, max_h))
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
    return(rep(NA_real_, max_h))
  }
  
  sig <- as.numeric(rugarch::sigma(fc))
  
  if (
    length(sig) < max_h ||
    any(!is.finite(sig))
  ) {
    return(rep(NA_real_, max_h))
  }
  
  pmax(
    sig[seq_len(max_h)]^2,
    cfg$forecast_floor
  )
}


garch_cache_path <- function(
    train_ret,
    origin_date,
    max_h,
    cfg
) {
  sig <- series_signature(train_ret)
  
  file.path(
    cfg$cache_dir,
    "garch",
    sprintf(
      "garch_%s_n%d_h%d_sig%s.rds",
      format(origin_date, "%Y%m%d"),
      length(train_ret),
      max_h,
      sig
    )
  )
}


forecast_garch_cached <- function(
    train_ret,
    origin_date,
    max_h,
    cfg
) {
  path <- garch_cache_path(
    train_ret,
    origin_date,
    max_h,
    cfg
  )
  
  if (
    cfg$use_garch_cache &&
    file.exists(path)
  ) {
    return(readRDS(path))
  }
  
  out <- forecast_garch(
    train_ret,
    max_h,
    cfg
  )
  
  if (cfg$use_garch_cache) {
    saveRDS(out, path)
  }
  
  out
}


forecast_ewma <- function(train_ret_pct, max_h, cfg) {
  r <- as.numeric(train_ret_pct)
  r <- r[is.finite(r)]
  
  if (length(r) < 30L) {
    return(rep(NA_real_, max_h))
  }
  
  lambda <- cfg$ewma_lambda
  
  v <- stats::var(
    head(r, min(30L, length(r))),
    na.rm = TRUE
  )
  
  if (!is.finite(v) || v <= 0) {
    v <- mean(r^2, na.rm = TRUE)
  }
  
  for (i in seq_along(r)) {
    v <- lambda * v +
      (1 - lambda) * r[i]^2
  }
  
  rep(
    pmax(v, cfg$forecast_floor),
    max_h
  )
}


# ==============================================================================
# 6. DIRECT HAR MODELS
# ==============================================================================

build_har_direct_frame <- function(
    rv,
    h,
    week,
    month,
    jump = NULL
) {
  n <- length(rv)
  
  if (n < month + h + 50L) {
    return(NULL)
  }
  
  origins <- month:(n - h)
  
  rows <- lapply(origins, function(s) {
    y <- mean(
      rv[(s + 1L):(s + h)]
    )
    
    ans <- data.frame(
      y = y,
      d = rv[s],
      w = mean(
        rv[(s - week + 1L):s]
      ),
      m = mean(
        rv[(s - month + 1L):s]
      )
    )
    
    if (!is.null(jump)) {
      ans$jd <- jump[s]
      ans$jw <- mean(
        jump[(s - week + 1L):s]
      )
      ans$jm <- mean(
        jump[(s - month + 1L):s]
      )
    }
    
    ans
  })
  
  do.call(rbind, rows)
}


forecast_har_level_direct <- function(
    train_rv,
    h,
    cfg
) {
  df <- build_har_direct_frame(
    train_rv,
    h,
    cfg$har_week,
    cfg$har_month
  )
  
  if (is.null(df) || nrow(df) < 80L) {
    return(NA_real_)
  }
  
  fit <- tryCatch(
    stats::lm(
      y ~ d + w + m,
      data = df
    ),
    error = function(e) NULL
  )
  
  if (is.null(fit)) {
    return(NA_real_)
  }
  
  n <- length(train_rv)
  
  nd <- data.frame(
    d = train_rv[n],
    w = mean(
      tail(train_rv, cfg$har_week)
    ),
    m = mean(
      tail(train_rv, cfg$har_month)
    )
  )
  
  pred <- tryCatch(
    as.numeric(
      stats::predict(
        fit,
        newdata = nd
      )
    ),
    error = function(e) NA_real_
  )
  
  if (!is.finite(pred)) {
    NA_real_
  } else {
    pmax(pred, cfg$forecast_floor)
  }
}


forecast_har_log_smear_direct <- function(
    train_rv,
    h,
    cfg
) {
  df <- build_har_direct_frame(
    train_rv,
    h,
    cfg$har_week,
    cfg$har_month
  )
  
  if (is.null(df) || nrow(df) < 80L) {
    return(NA_real_)
  }
  
  df$ly <- log(
    pmax(df$y, cfg$rv_floor)
  )
  df$ld <- log(
    pmax(df$d, cfg$rv_floor)
  )
  df$lw <- log(
    pmax(df$w, cfg$rv_floor)
  )
  df$lm <- log(
    pmax(df$m, cfg$rv_floor)
  )
  
  fit <- tryCatch(
    stats::lm(
      ly ~ ld + lw + lm,
      data = df
    ),
    error = function(e) NULL
  )
  
  if (is.null(fit)) {
    return(NA_real_)
  }
  
  smear <- mean(
    exp(stats::residuals(fit)),
    na.rm = TRUE
  )
  
  if (!is.finite(smear) || smear <= 0) {
    smear <- 1
  }
  
  n <- length(train_rv)
  
  nd <- data.frame(
    ld = log(
      pmax(train_rv[n], cfg$rv_floor)
    ),
    lw = log(
      pmax(
        mean(tail(train_rv, cfg$har_week)),
        cfg$rv_floor
      )
    ),
    lm = log(
      pmax(
        mean(tail(train_rv, cfg$har_month)),
        cfg$rv_floor
      )
    )
  )
  
  pred_log <- tryCatch(
    as.numeric(
      stats::predict(
        fit,
        newdata = nd
      )
    ),
    error = function(e) NA_real_
  )
  
  if (!is.finite(pred_log)) {
    return(NA_real_)
  }
  
  pmax(
    exp(pred_log) * smear,
    cfg$forecast_floor
  )
}


forecast_har_rvj_direct <- function(
    train_rv,
    train_jump,
    h,
    cfg
) {
  if (
    is.null(train_jump) ||
    !all(is.finite(train_jump))
  ) {
    return(NA_real_)
  }
  
  df <- build_har_direct_frame(
    train_rv,
    h,
    cfg$har_week,
    cfg$har_month,
    jump = train_jump
  )
  
  if (is.null(df) || nrow(df) < 80L) {
    return(NA_real_)
  }
  
  fit <- tryCatch(
    stats::lm(
      y ~ d + w + m + jd + jw + jm,
      data = df
    ),
    error = function(e) NULL
  )
  
  if (is.null(fit)) {
    return(NA_real_)
  }
  
  n <- length(train_rv)
  
  nd <- data.frame(
    d = train_rv[n],
    w = mean(
      tail(train_rv, cfg$har_week)
    ),
    m = mean(
      tail(train_rv, cfg$har_month)
    ),
    jd = train_jump[n],
    jw = mean(
      tail(train_jump, cfg$har_week)
    ),
    jm = mean(
      tail(train_jump, cfg$har_month)
    )
  )
  
  pred <- tryCatch(
    as.numeric(
      stats::predict(
        fit,
        newdata = nd
      )
    ),
    error = function(e) NA_real_
  )
  
  if (!is.finite(pred)) {
    NA_real_
  } else {
    pmax(pred, cfg$forecast_floor)
  }
}


# ==============================================================================
# 7. BUILD CAUSAL FEATURE STORE
# ==============================================================================

max_h <- max(cfg$horizons)

candidate_oos_idx <- which(
  dat$date >= cfg$test_start &
    dat$index >= cfg$ceemdan_window &
    dat$index <= nrow(dat) - max_h
)

if (length(candidate_oos_idx) == 0L) {
  stop(
    "No OOS forecast origins. ",
    "Check test_start, ceemdan_window and data length."
  )
}

candidate_oos_idx <- candidate_oos_idx[
  seq(
    1L,
    length(candidate_oos_idx),
    by = cfg$forecast_every
  )
]

if (
  !is.na(cfg$max_oos_origins) &&
  length(candidate_oos_idx) > cfg$max_oos_origins
) {
  candidate_oos_idx <- tail(
    candidate_oos_idx,
    cfg$max_oos_origins
  )
}

first_oos_idx <- min(candidate_oos_idx)
last_oos_idx <- max(candidate_oos_idx)

# Need enough earlier causal snapshots to train ridge models.
feature_start_idx <- max(
  cfg$ceemdan_window,
  first_oos_idx -
    cfg$ridge_train_rows -
    max_h -
    30L
)

feature_idx <- seq.int(
  feature_start_idx,
  last_oos_idx
)

message("")
message("============================================================")
message("CAUSAL FEATURE STORE")
message("============================================================")
message("First OOS origin: ", dat$date[first_oos_idx])
message("Last OOS origin:  ", dat$date[last_oos_idx])
message("OOS origins:      ", length(candidate_oos_idx))
message("Feature dates:     ", length(feature_idx))
message("")
message(
  "Each feature date requires its own right-edge CEEMDAN decomposition. ",
  "This is intentional: using a later decomposition to reconstruct old ",
  "features would leak future information."
)

feature_rows <- vector(
  "list",
  length(feature_idx)
)

imf_rows <- vector(
  "list",
  length(feature_idx)
)

pb <- utils::txtProgressBar(
  min = 0,
  max = length(feature_idx),
  style = 3
)

for (kk in seq_along(feature_idx)) {
  i <- feature_idx[kk]
  origin_date <- dat$date[i]
  
  ce_start <- max(
    1L,
    i - cfg$ceemdan_window + 1L
  )
  
  baseline_start <- max(
    1L,
    i - cfg$baseline_train_window + 1L
  )
  
  ce_log_rv <- dat$log_rv[ce_start:i]
  
  dec <- tryCatch(
    run_ceemdan_grouped(
      ce_log_rv,
      origin_date,
      cfg
    ),
    error = function(e) {
      warning(
        "CEEMDAN failed at ",
        origin_date,
        ": ",
        conditionMessage(e)
      )
      NULL
    }
  )
  
  if (is.null(dec)) {
    utils::setTxtProgressBar(pb, kk)
    next
  }
  
  ce_feat <- extract_ceemdan_features(dec)
  
  simple_feat <- current_multiscale_features(
    dat$rv_pct2[1L:i],
    cfg$har_week,
    cfg$har_month,
    cfg$rv_floor
  )
  
  train_ret <- dat$ret_pct[
    baseline_start:i
  ]
  
  garch_daily <- forecast_garch_cached(
    train_ret,
    origin_date,
    max_h,
    cfg
  )
  
  ewma_daily <- forecast_ewma(
    train_ret,
    max_h,
    cfg
  )
  
  labels <- unlist(
    lapply(
      cfg$horizons,
      function(h) {
        future_average(
          dat$rv_pct2,
          i,
          h
        )
      }
    )
  )
  
  names(labels) <- paste0(
    "actual_h",
    cfg$horizons
  )
  
  garch_avg <- unlist(
    lapply(
      cfg$horizons,
      function(h) {
        safe_mean(
          garch_daily[seq_len(h)]
        )
      }
    )
  )
  
  names(garch_avg) <- paste0(
    "garch_h",
    cfg$horizons
  )
  
  ewma_avg <- unlist(
    lapply(
      cfg$horizons,
      function(h) {
        safe_mean(
          ewma_daily[seq_len(h)]
        )
      }
    )
  )
  
  names(ewma_avg) <- paste0(
    "ewma_h",
    cfg$horizons
  )
  
  row_vec <- c(
    origin_index = i,
    simple_feat,
    ce_feat,
    labels,
    garch_avg,
    ewma_avg,
    ce_reconstruction_error =
      dec$reconstruction_max_abs_error,
    ce_n_fast = sum(dec$buckets == "fast"),
    ce_n_medium = sum(dec$buckets == "medium"),
    ce_n_slow = sum(dec$buckets == "slow")
  )
  
  feature_rows[[kk]] <- data.frame(
    origin_date = origin_date,
    as.list(row_vec),
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
  
  imf_rows[[kk]] <- data.frame(
    origin_date = origin_date,
    origin_index = i,
    component = seq_along(dec$periods),
    dominant_period_days = dec$periods,
    bucket = dec$buckets,
    reconstruction_max_abs_error =
      dec$reconstruction_max_abs_error,
    stringsAsFactors = FALSE
  )
  
  utils::setTxtProgressBar(pb, kk)
}

close(pb)

feature_rows <- feature_rows[
  !vapply(feature_rows, is.null, logical(1))
]

if (length(feature_rows) == 0L) {
  stop("No causal CEEMDAN feature rows were successfully created.")
}

feature_store <- do.call(
  rbind,
  feature_rows
)

feature_store$origin_date <- as.Date(
  feature_store$origin_date
)

numeric_cols <- setdiff(
  names(feature_store),
  "origin_date"
)

for (nm in numeric_cols) {
  feature_store[[nm]] <- as.numeric(
    feature_store[[nm]]
  )
}

feature_store$origin_index <- as.integer(
  feature_store$origin_index
)

imf_rows <- imf_rows[
  !vapply(imf_rows, is.null, logical(1))
]

imf_periods <- if (length(imf_rows) > 0L) {
  do.call(rbind, imf_rows)
} else {
  NULL
}

message("")
message(
  "Causal feature rows built: ",
  nrow(feature_store)
)


# ==============================================================================
# 8. RIDGE WITH FORWARD VALIDATION
# ==============================================================================

har_ridge_features <- c(
  "har_log_d",
  "har_log_w",
  "har_log_m"
)

ceemdan_feature_names <- grep(
  "^ce_",
  names(feature_store),
  value = TRUE
)

ceemdan_feature_names <- setdiff(
  ceemdan_feature_names,
  c(
    "ce_reconstruction_error",
    "ce_n_fast",
    "ce_n_medium",
    "ce_n_slow"
  )
)

ceemdan_ridge_features <- c(
  har_ridge_features,
  ceemdan_feature_names
)


forward_validation_folds <- function(
    n,
    n_folds,
    val_size,
    min_train
) {
  if (n < min_train + val_size) {
    return(list())
  }
  
  max_folds <- floor(
    (n - min_train) / val_size
  )
  
  k <- min(
    n_folds,
    max_folds
  )
  
  if (k < 1L) {
    return(list())
  }
  
  first_val_start <- n -
    k * val_size +
    1L
  
  folds <- vector(
    "list",
    k
  )
  
  for (j in seq_len(k)) {
    v_start <- first_val_start +
      (j - 1L) * val_size
    
    v_end <- min(
      n,
      v_start + val_size - 1L
    )
    
    train_end <- v_start - 1L
    
    folds[[j]] <- list(
      train = seq_len(train_end),
      validation = v_start:v_end
    )
  }
  
  folds
}


training_log_bounds <- function(
    y_log,
    cfg
) {
  q <- stats::quantile(
    y_log,
    probs = cfg$guardrail_probs,
    na.rm = TRUE,
    names = FALSE,
    type = 8
  )
  
  c(
    lower = q[1L] - cfg$guardrail_log_margin,
    upper = q[2L] + cfg$guardrail_log_margin
  )
}


clip_log_prediction <- function(
    pred_log,
    y_train_log,
    cfg
) {
  if (!cfg$prediction_guardrail) {
    return(list(
      value = pred_log,
      clipped = FALSE,
      lower = NA_real_,
      upper = NA_real_
    ))
  }
  
  bounds <- training_log_bounds(
    y_train_log,
    cfg
  )
  
  clipped_value <- min(
    max(pred_log, bounds["lower"]),
    bounds["upper"]
  )
  
  list(
    value = clipped_value,
    clipped = !isTRUE(
      all.equal(
        pred_log,
        clipped_value
      )
    ),
    lower = unname(bounds["lower"]),
    upper = unname(bounds["upper"])
  )
}


ridge_fit_predict <- function(
    train_df,
    current_row,
    feature_names,
    target_name,
    cfg,
    offset_name = NULL,
    current_offset = NULL
) {
  needed <- c(
    feature_names,
    target_name
  )
  
  if (!is.null(offset_name)) {
    needed <- c(
      needed,
      offset_name
    )
  }
  
  ok <- stats::complete.cases(
    train_df[, needed, drop = FALSE]
  )
  
  d <- train_df[
    ok,
    ,
    drop = FALSE
  ]
  
  if (nrow(d) < cfg$ridge_min_rows) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = NA_real_,
      clipped = NA,
      n_train = nrow(d),
      n_features = NA_integer_,
      cv_qlike = NA_real_
    ))
  }
  
  d <- tail(
    d,
    cfg$ridge_train_rows
  )
  
  x <- as.matrix(
    d[, feature_names, drop = FALSE]
  )
  
  current_x <- as.matrix(
    current_row[, feature_names, drop = FALSE]
  )
  
  if (
    any(!is.finite(current_x))
  ) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = NA_real_,
      clipped = NA,
      n_train = nrow(d),
      n_features = NA_integer_,
      cv_qlike = NA_real_
    ))
  }
  
  # Remove columns that are effectively constant in the available training set.
  sds <- apply(
    x,
    2L,
    safe_sd
  )
  
  keep <- is.finite(sds) &
    sds > 1e-10
  
  if (!any(keep)) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = NA_real_,
      clipped = NA,
      n_train = nrow(d),
      n_features = 0L,
      cv_qlike = NA_real_
    ))
  }
  
  x <- x[, keep, drop = FALSE]
  current_x <- current_x[, keep, drop = FALSE]
  
  y_actual <- pmax(
    d[[target_name]],
    cfg$rv_floor
  )
  
  y_log <- log(y_actual)
  
  if (is.null(offset_name)) {
    offset <- rep(
      0,
      nrow(d)
    )
  } else {
    offset_raw <- pmax(
      d[[offset_name]],
      cfg$forecast_floor
    )
    
    offset <- log(offset_raw)
  }
  
  y_model <- y_log - offset
  
  folds <- forward_validation_folds(
    n = nrow(d),
    n_folds = cfg$ridge_validation_folds,
    val_size = cfg$ridge_validation_size,
    min_train = max(
      100L,
      floor(cfg$ridge_min_rows * 0.60)
    )
  )
  
  if (length(folds) == 0L) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = NA_real_,
      clipped = NA,
      n_train = nrow(d),
      n_features = ncol(x),
      cv_qlike = NA_real_
    ))
  }
  
  lambda_grid <- sort(
    unique(cfg$ridge_lambda_grid),
    decreasing = TRUE
  )
  
  loss_mat <- matrix(
    NA_real_,
    nrow = length(folds),
    ncol = length(lambda_grid)
  )
  
  for (ff in seq_along(folds)) {
    tr <- folds[[ff]]$train
    va <- folds[[ff]]$validation
    
    fit <- tryCatch(
      glmnet::glmnet(
        x = x[tr, , drop = FALSE],
        y = y_model[tr],
        alpha = 0,
        lambda = lambda_grid,
        standardize = TRUE,
        intercept = TRUE
      ),
      error = function(e) NULL
    )
    
    if (is.null(fit)) {
      next
    }
    
    pred_tr <- tryCatch(
      as.matrix(
        stats::predict(
          fit,
          newx = x[tr, , drop = FALSE],
          s = lambda_grid
        )
      ),
      error = function(e) NULL
    )
    
    pred_va <- tryCatch(
      as.matrix(
        stats::predict(
          fit,
          newx = x[va, , drop = FALSE],
          s = lambda_grid
        )
      ),
      error = function(e) NULL
    )
    
    if (
      is.null(pred_tr) ||
      is.null(pred_va)
    ) {
      next
    }
    
    if (ncol(pred_tr) != length(lambda_grid)) {
      next
    }
    
    # Smearing factor is estimated separately for every lambda using only the
    # fold's training observations.
    smear <- vapply(
      seq_along(lambda_grid),
      function(j) {
        s <- mean(
          exp(
            y_model[tr] -
              pred_tr[, j]
          ),
          na.rm = TRUE
        )
        
        if (!is.finite(s) || s <= 0) {
          1
        } else {
          s
        }
      },
      numeric(1)
    )
    
    for (j in seq_along(lambda_grid)) {
      final_log <- offset[va] +
        pred_va[, j] +
        log(smear[j])
      
      if (cfg$prediction_guardrail) {
        bounds <- training_log_bounds(
          y_log[tr],
          cfg
        )
        
        final_log <- pmin(
          pmax(
            final_log,
            bounds["lower"]
          ),
          bounds["upper"]
        )
      }
      
      f <- pmax(
        exp(final_log),
        cfg$forecast_floor
      )
      
      loss_mat[ff, j] <- mean(
        qlike_loss(
          y_actual[va],
          f
        ),
        na.rm = TRUE
      )
    }
  }
  
  mean_loss <- colMeans(
    loss_mat,
    na.rm = TRUE
  )
  
  valid_lambda <- is.finite(
    mean_loss
  )
  
  if (!any(valid_lambda)) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = NA_real_,
      clipped = NA,
      n_train = nrow(d),
      n_features = ncol(x),
      cv_qlike = NA_real_
    ))
  }
  
  best_index <- which.min(
    ifelse(
      valid_lambda,
      mean_loss,
      Inf
    )
  )
  
  if (cfg$ridge_one_se_rule) {
    se_loss <- apply(
      loss_mat,
      2L,
      function(z) {
        z <- z[is.finite(z)]
        
        if (length(z) <= 1L) {
          0
        } else {
          stats::sd(z) /
            sqrt(length(z))
        }
      }
    )
    
    threshold <- mean_loss[best_index] +
      se_loss[best_index]
    
    eligible <- which(
      valid_lambda &
        mean_loss <= threshold
    )
    
    if (length(eligible) > 0L) {
      # lambda_grid is decreasing, so the first eligible lambda is the most
      # strongly regularized model inside the one-standard-error region.
      best_index <- eligible[1L]
    }
  }
  
  lambda_star <- lambda_grid[best_index]
  
  final_fit <- tryCatch(
    glmnet::glmnet(
      x = x,
      y = y_model,
      alpha = 0,
      lambda = lambda_grid,
      standardize = TRUE,
      intercept = TRUE
    ),
    error = function(e) NULL
  )
  
  if (is.null(final_fit)) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = lambda_star,
      clipped = NA,
      n_train = nrow(d),
      n_features = ncol(x),
      cv_qlike = mean_loss[best_index]
    ))
  }
  
  fitted_model <- as.numeric(
    stats::predict(
      final_fit,
      newx = x,
      s = lambda_star
    )
  )
  
  smear_full <- mean(
    exp(
      y_model -
        fitted_model
    ),
    na.rm = TRUE
  )
  
  if (
    !is.finite(smear_full) ||
    smear_full <= 0
  ) {
    smear_full <- 1
  }
  
  pred_component <- tryCatch(
    as.numeric(
      stats::predict(
        final_fit,
        newx = current_x,
        s = lambda_star
      )
    ),
    error = function(e) NA_real_
  )
  
  if (!is.finite(pred_component)) {
    return(list(
      forecast = NA_real_,
      raw_forecast = NA_real_,
      lambda = lambda_star,
      clipped = NA,
      n_train = nrow(d),
      n_features = ncol(x),
      cv_qlike = mean_loss[best_index]
    ))
  }
  
  if (is.null(offset_name)) {
    offset_current_log <- 0
  } else {
    if (
      is.null(current_offset) ||
      !is.finite(current_offset) ||
      current_offset <= 0
    ) {
      return(list(
        forecast = NA_real_,
        raw_forecast = NA_real_,
        lambda = lambda_star,
        clipped = NA,
        n_train = nrow(d),
        n_features = ncol(x),
        cv_qlike = mean_loss[best_index]
      ))
    }
    
    offset_current_log <- log(
      pmax(
        current_offset,
        cfg$forecast_floor
      )
    )
  }
  
  raw_log <- offset_current_log +
    pred_component +
    log(smear_full)
  
  raw_forecast <- pmax(
    exp(raw_log),
    cfg$forecast_floor
  )
  
  guarded <- clip_log_prediction(
    raw_log,
    y_log,
    cfg
  )
  
  forecast <- pmax(
    exp(guarded$value),
    cfg$forecast_floor
  )
  
  list(
    forecast = forecast,
    raw_forecast = raw_forecast,
    lambda = lambda_star,
    clipped = guarded$clipped,
    n_train = nrow(d),
    n_features = ncol(x),
    cv_qlike = mean_loss[best_index]
  )
}


# ==============================================================================
# 9. OOS WALK-FORWARD FORECASTS
# ==============================================================================

message("")
message("============================================================")
message("OOS FORECASTING")
message("============================================================")

forecast_rows <- list()
counter <- 1L

pb <- utils::txtProgressBar(
  min = 0,
  max = length(candidate_oos_idx),
  style = 3
)

for (oo in seq_along(candidate_oos_idx)) {
  i <- candidate_oos_idx[oo]
  origin_date <- dat$date[i]
  
  current_store <- feature_store[
    feature_store$origin_index == i,
    ,
    drop = FALSE
  ]
  
  if (nrow(current_store) != 1L) {
    warning(
      "Missing/duplicate feature row at ",
      origin_date
    )
    
    utils::setTxtProgressBar(pb, oo)
    next
  }
  
  baseline_start <- max(
    1L,
    i - cfg$baseline_train_window + 1L
  )
  
  train_rv <- dat$rv_pct2[
    baseline_start:i
  ]
  
  train_jump <- if (has_jump_data) {
    dat$jump_pct2[
      baseline_start:i
    ]
  } else {
    NULL
  }
  
  for (h in cfg$horizons) {
    actual <- future_average(
      dat$rv_pct2,
      i,
      h
    )
    
    if (!is.finite(actual)) {
      next
    }
    
    target_name <- paste0(
      "actual_h",
      h
    )
    
    garch_name <- paste0(
      "garch_h",
      h
    )
    
    ewma_name <- paste0(
      "ewma_h",
      h
    )
    
    # Labels must have been fully observed by current forecast origin.
    # This is the key purge that prevents h-day target leakage.
    hist_store <- feature_store[
      feature_store$origin_index + h <= i,
      ,
      drop = FALSE
    ]
    
    hist_store <- hist_store[
      hist_store$origin_index < i,
      ,
      drop = FALSE
    ]
    
    hist_store <- tail(
      hist_store,
      cfg$ridge_train_rows
    )
    
    # -------------------------- Conventional baselines ------------------------
    
    garch_fc <- current_store[[garch_name]]
    ewma_fc <- current_store[[ewma_name]]
    
    har_level_fc <- forecast_har_level_direct(
      train_rv,
      h,
      cfg
    )
    
    har_log_fc <- forecast_har_log_smear_direct(
      train_rv,
      h,
      cfg
    )
    
    har_rvj_fc <- if (has_jump_data) {
      forecast_har_rvj_direct(
        train_rv,
        train_jump,
        h,
        cfg
      )
    } else {
      NA_real_
    }
    
    # -------------------------- Ridge HAR benchmark ---------------------------
    
    har_ridge <- ridge_fit_predict(
      train_df = hist_store,
      current_row = current_store,
      feature_names = har_ridge_features,
      target_name = target_name,
      cfg = cfg
    )
    
    # -------------------------- CEEMDAN Ridge ----------------------------------
    
    ce_ridge <- ridge_fit_predict(
      train_df = hist_store,
      current_row = current_store,
      feature_names = ceemdan_ridge_features,
      target_name = target_name,
      cfg = cfg
    )
    
    # --------------------- GARCH + CEEMDAN correction -------------------------
    #
    # Historical target:
    #
    #   log(actual_h) - log(GARCH_h)
    #
    # CEEMDAN features are asked to predict ONLY the component GARCH missed.
    
    garch_ce <- ridge_fit_predict(
      train_df = hist_store,
      current_row = current_store,
      feature_names = ceemdan_feature_names,
      target_name = target_name,
      cfg = cfg,
      offset_name = garch_name,
      current_offset = garch_fc
    )
    
    model_values <- list(
      EWMA = list(
        forecast = ewma_fc,
        raw = ewma_fc,
        lambda = NA_real_,
        clipped = FALSE,
        ridge_n = NA_integer_,
        n_features = NA_integer_,
        cv_qlike = NA_real_
      ),
      GARCH_11 = list(
        forecast = garch_fc,
        raw = garch_fc,
        lambda = NA_real_,
        clipped = FALSE,
        ridge_n = NA_integer_,
        n_features = NA_integer_,
        cv_qlike = NA_real_
      ),
      HAR_LEVEL = list(
        forecast = har_level_fc,
        raw = har_level_fc,
        lambda = NA_real_,
        clipped = FALSE,
        ridge_n = NA_integer_,
        n_features = NA_integer_,
        cv_qlike = NA_real_
      ),
      HAR_LOG_SMEAR = list(
        forecast = har_log_fc,
        raw = har_log_fc,
        lambda = NA_real_,
        clipped = FALSE,
        ridge_n = NA_integer_,
        n_features = NA_integer_,
        cv_qlike = NA_real_
      ),
      HAR_RIDGE = list(
        forecast = har_ridge$forecast,
        raw = har_ridge$raw_forecast,
        lambda = har_ridge$lambda,
        clipped = har_ridge$clipped,
        ridge_n = har_ridge$n_train,
        n_features = har_ridge$n_features,
        cv_qlike = har_ridge$cv_qlike
      ),
      CEEMDAN_RIDGE = list(
        forecast = ce_ridge$forecast,
        raw = ce_ridge$raw_forecast,
        lambda = ce_ridge$lambda,
        clipped = ce_ridge$clipped,
        ridge_n = ce_ridge$n_train,
        n_features = ce_ridge$n_features,
        cv_qlike = ce_ridge$cv_qlike
      ),
      GARCH_CEEMDAN_CORR = list(
        forecast = garch_ce$forecast,
        raw = garch_ce$raw_forecast,
        lambda = garch_ce$lambda,
        clipped = garch_ce$clipped,
        ridge_n = garch_ce$n_train,
        n_features = garch_ce$n_features,
        cv_qlike = garch_ce$cv_qlike
      )
    )
    
    if (has_jump_data) {
      model_values$HAR_RVJ <- list(
        forecast = har_rvj_fc,
        raw = har_rvj_fc,
        lambda = NA_real_,
        clipped = FALSE,
        ridge_n = NA_integer_,
        n_features = NA_integer_,
        cv_qlike = NA_real_
      )
    }
    
    for (model_name in names(model_values)) {
      z <- model_values[[model_name]]
      
      forecast_rows[[counter]] <- data.frame(
        origin_date = origin_date,
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
        raw_forecast_rv = if (
          is.finite(z$raw)
        ) {
          pmax(
            z$raw,
            cfg$forecast_floor
          )
        } else {
          NA_real_
        },
        lambda = z$lambda,
        was_clipped = z$clipped,
        ridge_n_train = z$ridge_n,
        ridge_n_features = z$n_features,
        ridge_cv_qlike = z$cv_qlike,
        train_start = dat$date[baseline_start],
        train_end = origin_date,
        stringsAsFactors = FALSE
      )
      
      counter <- counter + 1L
    }
  }
  
  utils::setTxtProgressBar(pb, oo)
}

close(pb)

forecasts <- do.call(
  rbind,
  forecast_rows
)

forecasts$origin_date <- as.Date(
  forecasts$origin_date
)


# ==============================================================================
# 10. METRICS
# ==============================================================================

metric_one <- function(df) {
  ok <- is.finite(df$actual_rv) &
    is.finite(df$forecast_rv)
  
  a <- df$actual_rv[ok]
  f <- df$forecast_rv[ok]
  
  if (length(a) == 0L) {
    return(data.frame(
      n = 0L,
      RMSE = NA_real_,
      MAE = NA_real_,
      QLIKE = NA_real_,
      log_RMSE = NA_real_,
      bias = NA_real_
    ))
  }
  
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
      qlike_loss(a, f)
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
    )
  )
}


metric_split <- split(
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
    metric_split,
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

metrics$QLIKE_vs_GARCH <- NA_real_
metrics$RMSE_vs_GARCH <- NA_real_

for (h in unique(metrics$horizon)) {
  j <- metrics$horizon == h
  
  gq <- metrics$QLIKE[
    j &
      metrics$model == "GARCH_11"
  ]
  
  gr <- metrics$RMSE[
    j &
      metrics$model == "GARCH_11"
  ]
  
  if (
    length(gq) == 1L &&
    is.finite(gq) &&
    gq > 0
  ) {
    metrics$QLIKE_vs_GARCH[j] <-
      metrics$QLIKE[j] / gq
  }
  
  if (
    length(gr) == 1L &&
    is.finite(gr) &&
    gr > 0
  ) {
    metrics$RMSE_vs_GARCH[j] <-
      metrics$RMSE[j] / gr
  }
}


# ==============================================================================
# 11. STABILITY / EXPLOSION DIAGNOSTICS
# ==============================================================================

diagnostic_split <- split(
  forecasts,
  interaction(
    forecasts$horizon,
    forecasts$model,
    drop = TRUE
  )
)

stability_diagnostics <- do.call(
  rbind,
  lapply(
    diagnostic_split,
    function(df) {
      ok <- is.finite(df$actual_rv) &
        is.finite(df$forecast_rv)
      
      z <- df[ok, , drop = FALSE]
      
      if (nrow(z) == 0L) {
        return(data.frame(
          horizon = unique(df$horizon),
          model = unique(df$model),
          n = 0L,
          max_forecast_rv = NA_real_,
          max_forecast_vol_pct = NA_real_,
          p99_forecast_actual_ratio = NA_real_,
          pct_ratio_gt_10 = NA_real_,
          pct_ratio_lt_0_1 = NA_real_,
          pct_clipped = NA_real_
        ))
      }
      
      ratio <- z$forecast_rv /
        pmax(
          z$actual_rv,
          cfg$rv_floor
        )
      
      clipped <- z$was_clipped
      clipped <- clipped[
        !is.na(clipped)
      ]
      
      data.frame(
        horizon = unique(z$horizon),
        model = unique(z$model),
        n = nrow(z),
        max_forecast_rv = max(
          z$forecast_rv
        ),
        max_forecast_vol_pct = sqrt(
          max(z$forecast_rv)
        ),
        p99_forecast_actual_ratio = as.numeric(
          stats::quantile(
            ratio,
            0.99,
            na.rm = TRUE,
            names = FALSE
          )
        ),
        pct_ratio_gt_10 = mean(
          ratio > 10
        ),
        pct_ratio_lt_0_1 = mean(
          ratio < 0.1
        ),
        pct_clipped = if (
          length(clipped) == 0L
        ) {
          NA_real_
        } else {
          mean(clipped)
        },
        stringsAsFactors = FALSE
      )
    }
  )
)

rownames(stability_diagnostics) <- NULL


# ==============================================================================
# 12. DIEBOLD-MARIANO + MOVING-BLOCK BOOTSTRAP
# ==============================================================================

nw_long_run_variance <- function(x, lag) {
  x <- as.numeric(x)
  x <- x[is.finite(x)]
  
  n <- length(x)
  
  if (n < 5L) {
    return(NA_real_)
  }
  
  xc <- x - mean(x)
  
  gamma0 <- sum(
    xc * xc
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
      
      weight <- 1 -
        k / (lag + 1)
      
      lrv <- lrv +
        2 * weight * gamma_k
    }
  }
  
  lrv
}


paired_loss_difference <- function(
    df_a,
    df_b,
    loss = c("QLIKE", "SE")
) {
  loss <- match.arg(loss)
  
  a <- df_a[
    ,
    c(
      "origin_date",
      "actual_rv",
      "forecast_rv"
    )
  ]
  
  b <- df_b[
    ,
    c(
      "origin_date",
      "forecast_rv"
    )
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
      z$fa
    )
    
    lb <- qlike_loss(
      z$actual_rv,
      z$fb
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


dm_from_diff <- function(
    d,
    horizon
) {
  d <- d[is.finite(d)]
  
  if (length(d) < 30L) {
    return(c(
      n = length(d),
      statistic = NA_real_,
      p_value = NA_real_,
      mean_loss_diff = NA_real_
    ))
  }
  
  lag <- max(
    horizon - 1L,
    0L
  )
  
  lrv <- nw_long_run_variance(
    d,
    lag
  )
  
  if (
    !is.finite(lrv) ||
    lrv <= 0
  ) {
    return(c(
      n = length(d),
      statistic = NA_real_,
      p_value = NA_real_,
      mean_loss_diff = mean(d)
    ))
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


moving_block_bootstrap_mean <- function(
    d,
    B,
    block_length,
    seed
) {
  d <- as.numeric(d)
  d <- d[is.finite(d)]
  
  n <- length(d)
  
  if (n < 30L) {
    return(c(
      boot_mean = NA_real_,
      ci_low = NA_real_,
      ci_high = NA_real_,
      p_boot_two_sided = NA_real_
    ))
  }
  
  block_length <- min(
    max(1L, block_length),
    n
  )
  
  starts <- seq_len(
    n - block_length + 1L
  )
  
  n_blocks <- ceiling(
    n / block_length
  )
  
  set.seed(seed)
  
  boot <- numeric(B)
  
  for (b in seq_len(B)) {
    chosen <- sample(
      starts,
      size = n_blocks,
      replace = TRUE
    )
    
    idx <- unlist(
      lapply(
        chosen,
        function(s) {
          s:(s + block_length - 1L)
        }
      )
    )
    
    idx <- idx[
      seq_len(n)
    ]
    
    boot[b] <- mean(
      d[idx]
    )
  }
  
  # Percentile CI for the mean loss difference.
  ci <- stats::quantile(
    boot,
    probs = c(0.025, 0.975),
    na.rm = TRUE,
    names = FALSE
  )
  
  # Null-centered moving-block bootstrap p-value for H0: E[d] = 0.
  # The percentile CI above uses the original d; the test below resamples
  # centered loss differences so the bootstrap distribution obeys the null.
  d0 <- d - mean(d)
  boot_null <- numeric(B)
  
  set.seed(seed + 7919L)
  
  for (b in seq_len(B)) {
    chosen <- sample(
      starts,
      size = n_blocks,
      replace = TRUE
    )
    
    idx <- unlist(
      lapply(
        chosen,
        function(s) {
          s:(s + block_length - 1L)
        }
      )
    )
    
    idx <- idx[
      seq_len(n)
    ]
    
    boot_null[b] <- mean(
      d0[idx]
    )
  }
  
  p_boot <- mean(
    abs(boot_null) >= abs(mean(d))
  )
  
  c(
    boot_mean = mean(boot),
    ci_low = ci[1L],
    ci_high = ci[2L],
    p_boot_two_sided = p_boot
  )
}


comparison_pairs <- list(
  c(
    "CEEMDAN_RIDGE",
    "HAR_RIDGE"
  ),
  c(
    "CEEMDAN_RIDGE",
    "HAR_LOG_SMEAR"
  ),
  c(
    "CEEMDAN_RIDGE",
    "GARCH_11"
  ),
  c(
    "GARCH_CEEMDAN_CORR",
    "GARCH_11"
  )
)

dm_rows <- list()
bootstrap_rows <- list()

dm_counter <- 1L
boot_counter <- 1L

for (h in cfg$horizons) {
  hdat <- forecasts[
    forecasts$horizon == h,
    ,
    drop = FALSE
  ]
  
  available_models <- unique(
    hdat$model
  )
  
  for (pair in comparison_pairs) {
    model_a <- pair[1L]
    model_b <- pair[2L]
    
    if (
      !all(
        c(
          model_a,
          model_b
        ) %in% available_models
      )
    ) {
      next
    }
    
    a <- hdat[
      hdat$model == model_a,
      ,
      drop = FALSE
    ]
    
    b <- hdat[
      hdat$model == model_b,
      ,
      drop = FALSE
    ]
    
    for (loss_name in c("QLIKE", "SE")) {
      ld <- paired_loss_difference(
        a,
        b,
        loss_name
      )
      
      dm <- dm_from_diff(
        ld$diff,
        h
      )
      
      dm_rows[[dm_counter]] <- data.frame(
        horizon = h,
        model_A = model_a,
        model_B = model_b,
        loss = loss_name,
        n = unname(dm["n"]),
        statistic = unname(dm["statistic"]),
        p_value = unname(dm["p_value"]),
        mean_loss_diff_A_minus_B =
          unname(dm["mean_loss_diff"]),
        stringsAsFactors = FALSE
      )
      
      dm_counter <- dm_counter + 1L
      
      boot <- moving_block_bootstrap_mean(
        ld$diff,
        B = cfg$bootstrap_B,
        block_length = max(
          cfg$bootstrap_block_length,
          2L * h
        ),
        seed = cfg$seed +
          1000L * h +
          boot_counter
      )
      
      bootstrap_rows[[boot_counter]] <- data.frame(
        horizon = h,
        model_A = model_a,
        model_B = model_b,
        loss = loss_name,
        n = length(ld$diff),
        mean_loss_diff_A_minus_B = mean(
          ld$diff,
          na.rm = TRUE
        ),
        bootstrap_mean =
          unname(boot["boot_mean"]),
        ci_low =
          unname(boot["ci_low"]),
        ci_high =
          unname(boot["ci_high"]),
        p_boot_two_sided =
          unname(boot["p_boot_two_sided"]),
        block_length = max(
          cfg$bootstrap_block_length,
          2L * h
        ),
        B = cfg$bootstrap_B,
        stringsAsFactors = FALSE
      )
      
      boot_counter <- boot_counter + 1L
    }
  }
}

dm_tests <- if (length(dm_rows) > 0L) {
  do.call(
    rbind,
    dm_rows
  )
} else {
  data.frame()
}

bootstrap_tests <- if (
  length(bootstrap_rows) > 0L
) {
  do.call(
    rbind,
    bootstrap_rows
  )
} else {
  data.frame()
}


# ==============================================================================
# 13. PLOTS
# ==============================================================================

main_plot_models <- c(
  "GARCH_11",
  "HAR_LOG_SMEAR",
  "HAR_RIDGE",
  "CEEMDAN_RIDGE",
  "GARCH_CEEMDAN_CORR"
)

for (h in cfg$horizons) {
  pdat <- forecasts[
    forecasts$horizon == h &
      forecasts$model %in% main_plot_models,
    ,
    drop = FALSE
  ]
  
  if (nrow(pdat) == 0L) {
    next
  }
  
  actual_line <- pdat[
    !duplicated(pdat$origin_date),
    c(
      "origin_date",
      "actual_rv"
    ),
    drop = FALSE
  ]
  
  actual_line$actual_vol_pct <- sqrt(
    actual_line$actual_rv
  )
  
  pdat$forecast_vol_pct <- sqrt(
    pdat$forecast_rv
  )
  
  p <- ggplot2::ggplot() +
    ggplot2::geom_line(
      data = actual_line,
      ggplot2::aes(
        x = origin_date,
        y = actual_vol_pct
      ),
      linewidth = 0.65
    ) +
    ggplot2::geom_line(
      data = pdat,
      ggplot2::aes(
        x = origin_date,
        y = forecast_vol_pct,
        linetype = model
      ),
      linewidth = 0.45,
      na.rm = TRUE
    ) +
    ggplot2::labs(
      title = paste0(
        "BTC volatility forecasts — h = ",
        h
      ),
      subtitle = paste0(
        "Actual and predicted sqrt(",
        h,
        "-day average variance), daily percent units"
      ),
      x = NULL,
      y = "Volatility (%)",
      linetype = "Model"
    ) +
    ggplot2::theme_minimal(
      base_size = 11
    )
  
  ggplot2::ggsave(
    file.path(
      cfg$output_dir,
      paste0(
        "forecast_plot_h",
        h,
        ".png"
      )
    ),
    p,
    width = 11,
    height = 6,
    dpi = 150
  )
  
  cumulative_pairs <- list(
    c(
      "CEEMDAN_RIDGE",
      "HAR_RIDGE"
    ),
    c(
      "CEEMDAN_RIDGE",
      "GARCH_11"
    ),
    c(
      "GARCH_CEEMDAN_CORR",
      "GARCH_11"
    )
  )
  
  for (pair in cumulative_pairs) {
    model_a <- pair[1L]
    model_b <- pair[2L]
    
    a <- forecasts[
      forecasts$horizon == h &
        forecasts$model == model_a,
      ,
      drop = FALSE
    ]
    
    b <- forecasts[
      forecasts$horizon == h &
        forecasts$model == model_b,
      ,
      drop = FALSE
    ]
    
    if (
      nrow(a) == 0L ||
      nrow(b) == 0L
    ) {
      next
    }
    
    ld <- paired_loss_difference(
      a,
      b,
      "QLIKE"
    )
    
    if (length(ld$diff) == 0L) {
      next
    }
    
    cd <- data.frame(
      origin_date = ld$dates,
      loss_diff = ld$diff
    )
    
    cd$cumulative_loss_diff <- cumsum(
      cd$loss_diff
    )
    
    p2 <- ggplot2::ggplot(
      cd,
      ggplot2::aes(
        x = origin_date,
        y = cumulative_loss_diff
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
          "Cumulative QLIKE: ",
          model_a,
          " minus ",
          model_b,
          " — h = ",
          h
        ),
        subtitle = paste0(
          "Downward = ",
          model_a,
          " accumulates less QLIKE loss"
        ),
        x = NULL,
        y = "Cumulative loss difference"
      ) +
      ggplot2::theme_minimal(
        base_size = 11
      )
    
    safe_a <- gsub(
      "[^A-Za-z0-9]+",
      "_",
      tolower(model_a)
    )
    
    safe_b <- gsub(
      "[^A-Za-z0-9]+",
      "_",
      tolower(model_b)
    )
    
    ggplot2::ggsave(
      file.path(
        cfg$output_dir,
        paste0(
          "cumulative_qlike_",
          safe_a,
          "_vs_",
          safe_b,
          "_h",
          h,
          ".png"
        )
      ),
      p2,
      width = 11,
      height = 6,
      dpi = 150
    )
  }
}


# ==============================================================================
# 14. SAVE OUTPUTS
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
  stability_diagnostics,
  file.path(
    cfg$output_dir,
    "stability_diagnostics.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  feature_store,
  file.path(
    cfg$output_dir,
    "causal_feature_store.csv"
  ),
  row.names = FALSE
)

if (
  !is.null(imf_periods) &&
  nrow(imf_periods) > 0L
) {
  utils::write.csv(
    imf_periods,
    file.path(
      cfg$output_dir,
      "imf_periods.csv"
    ),
    row.names = FALSE
  )
}

if (nrow(dm_tests) > 0L) {
  utils::write.csv(
    dm_tests,
    file.path(
      cfg$output_dir,
      "dm_tests.csv"
    ),
    row.names = FALSE
  )
}

if (nrow(bootstrap_tests) > 0L) {
  utils::write.csv(
    bootstrap_tests,
    file.path(
      cfg$output_dir,
      "bootstrap_tests.csv"
    ),
    row.names = FALSE
  )
}

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
    "Data source: Binance Spot"
  ),
  paste0(
    "Binance symbol: ",
    cfg$binance_symbol
  ),
  paste0(
    "Binance interval: ",
    cfg$binance_interval
  ),
  paste0(
    "Binance download mode: ",
    cfg$binance_download_mode
  ),
  paste0(
    "Binance sample: ",
    cfg$binance_start_date,
    " to ",
    cfg$binance_end_date
  ),
  paste0(
    "RV note: ",
    rv_note
  ),
  paste0(
    "Expected 5m bars per UTC day: ",
    cfg$expected_bars_per_day
  ),
  paste0(
    "Drop incomplete UTC days: ",
    cfg$drop_incomplete_days
  ),
  paste0(
    "HAR-RV-J available: ",
    has_jump_data
  ),
  paste0(
    "Horizons: ",
    paste(
      cfg$horizons,
      collapse = ","
    )
  ),
  paste0(
    "OOS origins: ",
    length(candidate_oos_idx)
  ),
  paste0(
    "Baseline train window: ",
    cfg$baseline_train_window
  ),
  paste0(
    "CEEMDAN window: ",
    cfg$ceemdan_window
  ),
  paste0(
    "Causal CEEMDAN feature dates: ",
    nrow(feature_store)
  ),
  paste0(
    "Ridge train rows: ",
    cfg$ridge_train_rows
  ),
  paste0(
    "Ridge minimum rows: ",
    cfg$ridge_min_rows
  ),
  paste0(
    "CEEMDAN ensemble size: ",
    cfg$ceemdan_ensemble_size
  ),
  paste0(
    "CEEMDAN noise strength: ",
    cfg$ceemdan_noise_strength
  ),
  paste0(
    "Fast max period: ",
    cfg$fast_max_period
  ),
  paste0(
    "Medium max period: ",
    cfg$medium_max_period
  ),
  paste0(
    "Prediction guardrail: ",
    cfg$prediction_guardrail
  ),
  paste0(
    "Bootstrap B: ",
    cfg$bootstrap_B
  ),
  paste0(
    "Seed: ",
    cfg$seed
  ),
  "",
  "Interpretation:",
  "  QLIKE difference A-B < 0 => model A has lower QLIKE loss.",
  "  QLIKE_vs_GARCH < 1 => model beats GARCH on average QLIKE.",
  "  A downward cumulative loss-difference plot favors the first model.",
  "",
  "Critical leakage rule:",
  "  ridge training at t only uses historical origins s with s+h <= t.",
  "",
  "CEEMDAN_RIDGE:",
  "  direct log future-RV model using HAR log features + causal CEEMDAN features.",
  "",
  "GARCH_CEEMDAN_CORR:",
  "  ridge predicts log(actual future RV) - log(GARCH forecast) from causal",
  "  CEEMDAN features. It tests incremental information beyond GARCH."
)

writeLines(
  config_lines,
  file.path(
    cfg$output_dir,
    "run_config.txt"
  )
)


# ==============================================================================
# 15. CONSOLE REPORT
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
  "\n=================== STABILITY DIAGNOSTICS =================\n"
)

print(
  stability_diagnostics,
  row.names = FALSE,
  digits = 5
)

if (nrow(dm_tests) > 0L) {
  cat(
    "\n===================== DIEBOLD-MARIANO =====================\n"
  )
  
  print(
    dm_tests,
    row.names = FALSE,
    digits = 5
  )
}

if (nrow(bootstrap_tests) > 0L) {
  cat(
    "\n================ MOVING-BLOCK BOOTSTRAP ===================\n"
  )
  
  print(
    bootstrap_tests,
    row.names = FALSE,
    digits = 5
  )
}

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
  "\nPRIMARY TESTS TO READ FIRST:\n",
  "  1. CEEMDAN_RIDGE vs HAR_RIDGE\n",
  "  2. CEEMDAN_RIDGE vs GARCH_11\n",
  "  3. GARCH_CEEMDAN_CORR vs GARCH_11\n",
  "\n",
  sep = ""
)

cat(
  "If CEEMDAN adds genuine information, you want:\n",
  "  - lower OOS QLIKE,\n",
  "  - negative paired mean QLIKE loss differences,\n",
  "  - bootstrap confidence intervals mostly below zero,\n",
  "  - and no dependence on a handful of clipped/extreme forecasts.\n\n",
  sep = ""
)
