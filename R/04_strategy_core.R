# Core economic-value test with corrected EWMA timing

clip <- function(x, lo, hi) pmin(pmax(x, lo), hi)

lagged_z <- function(x, window = 90L, min_obs = 45L) {
  out <- rep(NA_real_, length(x))
  for (i in seq_along(x)) {
    j <- i - 1L
    if (j < 1L || !is.finite(x[i])) next
    h <- x[max(1L, j - window + 1L):j]
    h <- h[is.finite(h)]
    if (length(h) < min_obs) next
    s <- sd(h)
    if (is.finite(s) && s > 0) out[i] <- (x[i] - mean(h)) / s
  }
  out
}

ewma_rv <- function(rv, lambda = .94, init = 60L) {
  rv <- as.numeric(rv)
  out <- rep(NA_real_, length(rv))
  first <- which(is.finite(rv))
  if (length(first) < init) stop("Too little RV history")
  j0 <- first[init]
  out[j0] <- mean(rv[first[seq_len(init)]])
  if (j0 < length(rv)) {
    for (i in (j0 + 1L):length(rv)) {
      out[i] <- if (is.finite(rv[i]) && is.finite(out[i - 1L])) {
        lambda * out[i - 1L] + (1 - lambda) * rv[i]
      } else out[i - 1L]
    }
  }
  out
}

rolling_mean <- function(x, k) {
  out <- rep(NA_real_, length(x))
  if (length(x) < k) return(out)
  for (i in k:length(x)) out[i] <- mean(x[(i - k + 1L):i], na.rm = TRUE)
  out
}

trend_signal <- function(close, slow = 100L, momentum = 20L) {
  sma <- rolling_mean(close, slow)
  mom <- close / c(rep(NA_real_, momentum), head(close, -momentum)) - 1
  as.numeric(close > sma & mom > 0)
}

combine_variance_forecasts <- function(harq, realgarch, w = .5) {
  w * realgarch + (1 - w) * harq
}

run_strategy <- function(weight, risky_return, cost_bps = 10) {
  n <- length(weight)
  stopifnot(length(risky_return) == n)
  gross <- net <- turnover <- pretrade <- rep(NA_real_, n)
  prev_w <- 0
  prev_r <- 0

  for (i in seq_len(n)) {
    pre <- if (i == 1L) 0 else {
      den <- 1 + prev_w * prev_r
      if (is.finite(den) && abs(den) > 1e-12) prev_w * (1 + prev_r) / den else prev_w
    }
    w <- if (is.finite(weight[i])) weight[i] else 0
    r <- if (is.finite(risky_return[i])) risky_return[i] else 0
    tr <- abs(w - pre)
    gross[i] <- w * r
    net[i] <- gross[i] - cost_bps / 10000 * tr
    turnover[i] <- tr
    pretrade[i] <- pre
    prev_w <- w
    prev_r <- r
  }

  data.frame(weight, pretrade, turnover, gross_return = gross, net_return = net)
}

max_drawdown <- function(r) {
  wealth <- cumprod(1 + ifelse(is.finite(r), r, 0))
  min(wealth / cummax(wealth) - 1, na.rm = TRUE)
}

strategy_metrics <- function(r, turnover, weight, ann = 365) {
  ok <- is.finite(r)
  r <- r[ok]
  turnover <- turnover[ok]
  weight <- weight[ok]
  wealth <- prod(1 + r)
  cagr <- wealth^(ann / length(r)) - 1
  ann_mean <- mean(r) * ann
  ann_vol <- sd(r) * sqrt(ann)
  data.frame(
    n = length(r), total_return = wealth - 1, CAGR = cagr,
    ann_mean = ann_mean, ann_vol = ann_vol,
    Sharpe = ann_mean / ann_vol,
    max_drawdown = max_drawdown(r),
    annual_turnover = sum(turnover) * ann / length(r),
    avg_weight = mean(weight)
  )
}

strategy_frame <- function(daily, model_rv, ann = 365, target_vol = .20, max_weight = 1.5) {
  stopifnot(all(c("date", "close", "RV") %in% names(daily)))
  stopifnot(all(c("origin_date", "forecast_rv") %in% names(model_rv)))
  daily <- daily[order(daily$date), ]
  daily$return <- c(NA_real_, daily$close[-1L] / daily$close[-nrow(daily)] - 1)
  daily$ewma_rv <- ewma_rv(daily$RV)
  daily$trend <- trend_signal(daily$close)

  origin <- match(as.Date(model_rv$origin_date), daily$date)
  target <- origin + 1L
  ok <- is.finite(origin) & target <= nrow(daily)
  origin <- origin[ok]
  target <- target[ok]
  fc <- model_rv$forecast_rv[ok]
  model_vol <- sqrt(pmax(fc, 0)) / 100 * sqrt(ann)
  ewma_vol <- sqrt(pmax(daily$ewma_rv[origin], 0)) / 100 * sqrt(ann)
  z <- lagged_z(model_vol)

  data.frame(
    origin_date = daily$date[origin], target_date = daily$date[target],
    btc_return = daily$return[target], trend = daily$trend[origin],
    model_vol = model_vol, ewma_vol = ewma_vol, model_vol_z = z,
    w_trend = daily$trend[origin],
    w_ewma = clip(target_vol / ewma_vol, 0, max_weight),
    w_model = clip(target_vol / model_vol, 0, max_weight),
    w_trend_z = daily$trend[origin] * clip(1 - .25 * z, 0, max_weight)
  )
}

core_strategy_table <- function(x, cost_bps = 10) {
  weights <- list(
    TREND = x$w_trend,
    EWMA_VOL_TARGET = x$w_ewma,
    MODEL_VOL_TARGET = x$w_model,
    TREND_EWMA = x$trend * x$w_ewma,
    TREND_MODEL_VOL = x$trend * x$w_model,
    TREND_X_VOL_Z = x$w_trend_z
  )

  out <- lapply(names(weights), function(name) {
    bt <- run_strategy(weights[[name]], x$btc_return, cost_bps)
    cbind(strategy = name, strategy_metrics(bt$net_return, bt$turnover, bt$weight))
  })
  do.call(rbind, out)
}

cost_grid <- function(x, costs = c(0, 2, 5, 10, 25, 50)) {
  do.call(rbind, lapply(costs, function(cost) {
    z <- core_strategy_table(x, cost)
    z$cost_bps <- cost
    z
  }))
}
