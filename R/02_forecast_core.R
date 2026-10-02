# Core HAR/HARQ/HEAVY logic used by the public audit implementation

roll_mean_at <- function(x, i, k) mean(x[(i - k + 1L):i], na.rm = TRUE)

har_frame <- function(m, h, week = 5L, month = 22L) {
  stopifnot(all(c("RV", "RQ") %in% names(m)), h >= 1L)
  n <- nrow(m)
  idx <- seq.int(month, n - h)
  rows <- lapply(idx, function(i) {
    data.frame(
      y = mean(m$RV[(i + 1L):(i + h)], na.rm = TRUE),
      rv_d = m$RV[i],
      rv_w = roll_mean_at(m$RV, i, week),
      rv_m = roll_mean_at(m$RV, i, month),
      rq_rv = sqrt(max(m$RQ[i], 0)) * m$RV[i]
    )
  })
  do.call(rbind, rows)
}

ols_fit <- function(y, X) {
  fit <- lm.fit(cbind(1, as.matrix(X)), y)
  if (anyNA(fit$coefficients)) stop("Singular linear model")
  fit
}

ols_predict <- function(fit, x) {
  as.numeric(c(1, as.numeric(x)) %*% fit$coefficients)
}

guard_forecast <- function(value, target, enabled = TRUE) {
  if (!enabled || (is.finite(value) && value >= min(target) && value <= max(target))) return(value)
  mean(target)
}

fit_har_pair <- function(train, h, week = 5L, month = 22L, range_guard = TRUE) {
  d <- har_frame(train, h, week, month)
  har <- ols_fit(d$y, d[c("rv_d", "rv_w", "rv_m")])
  harq <- ols_fit(d$y, d[c("rv_d", "rq_rv", "rv_w", "rv_m")])
  i <- nrow(train)
  x <- c(
    rv_d = train$RV[i],
    rv_w = roll_mean_at(train$RV, i, week),
    rv_m = roll_mean_at(train$RV, i, month),
    rq_rv = sqrt(max(train$RQ[i], 0)) * train$RV[i]
  )
  data.frame(
    model = c("HAR_RV", "HARQ"),
    forecast_rv = c(
      guard_forecast(ols_predict(har, x[c("rv_d", "rv_w", "rv_m")]), d$y, range_guard),
      guard_forecast(ols_predict(harq, x[c("rv_d", "rq_rv", "rv_w", "rv_m")]), d$y, range_guard)
    )
  )
}

heavy_path <- function(rv, omega, alpha, beta) {
  m <- rep(NA_real_, length(rv))
  m[1] <- mean(rv, na.rm = TRUE)
  for (i in 2:length(rv)) m[i] <- omega + alpha * rv[i - 1L] + beta * m[i - 1L]
  m
}

fit_heavy_rm <- function(rv, rho_max = .999, floor = 1e-10) {
  rv <- pmax(as.numeric(rv), floor)
  objective <- function(par) {
    rho <- rho_max * plogis(par[1])
    alpha <- rho * plogis(par[2])
    beta <- rho - alpha
    omega <- (1 - rho) * mean(rv)
    m <- pmax(heavy_path(rv, omega, alpha, beta), floor)
    z <- rv[-1L] / m[-1L]
    mean(z - log(z) - 1)
  }
  opt <- optim(c(0, 0), objective, method = "BFGS")
  rho <- rho_max * plogis(opt$par[1])
  alpha <- rho * plogis(opt$par[2])
  beta <- rho - alpha
  omega <- (1 - rho) * mean(rv)
  m <- heavy_path(rv, omega, alpha, beta)
  structure(
    list(omega = omega, alpha = alpha, beta = beta, state = tail(m, 1), value = opt$value),
    class = "heavy_rm"
  )
}

predict.heavy_rm <- function(object, rv_last, ...) {
  object$omega + object$alpha * rv_last + object$beta * object$state
}

walk_forward_har <- function(m, test_start, horizons = c(1L, 5L, 10L), train_window = 1460L) {
  stopifnot("date" %in% names(m))
  m <- m[order(m$date), ]
  origins <- which(m$date >= as.Date(test_start))
  origins <- origins[origins <= nrow(m) - max(horizons)]
  out <- list()
  k <- 1L

  for (i in origins) {
    first <- max(1L, i - train_window + 1L)
    train <- m[first:i, ]
    for (h in horizons) {
      pred <- fit_har_pair(train, h)
      actual <- mean(m$RV[(i + 1L):(i + h)], na.rm = TRUE)
      pred$origin_date <- m$date[i]
      pred$horizon <- h
      pred$actual_rv <- actual
      out[[k]] <- pred
      k <- k + 1L
    }
  }

  ans <- do.call(rbind, out)
  ans[, c("origin_date", "horizon", "model", "actual_rv", "forecast_rv")]
}
