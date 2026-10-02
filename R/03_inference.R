# QLIKE, Diebold-Mariano and moving-block bootstrap inference

qlike <- function(actual, forecast, floor = 1e-10) {
  y <- pmax(actual, floor)
  f <- pmax(forecast, floor)
  z <- y / f
  z - log(z) - 1
}

newey_west_lrv <- function(x, lag = 0L) {
  x <- x[is.finite(x)]
  n <- length(x)
  xc <- x - mean(x)
  out <- sum(xc^2) / n
  if (lag < 1L) return(out)
  for (k in seq_len(min(lag, n - 1L))) {
    gamma <- sum(xc[(k + 1L):n] * xc[1L:(n - k)]) / n
    out <- out + 2 * (1 - k / (lag + 1)) * gamma
  }
  out
}

dm_test <- function(loss_a, loss_b, lag = 0L) {
  d <- loss_a - loss_b
  d <- d[is.finite(d)]
  se <- sqrt(newey_west_lrv(d, lag) / length(d))
  stat <- mean(d) / se
  data.frame(
    n = length(d), mean_loss_diff_A_minus_B = mean(d),
    statistic = stat, p_value = 2 * pnorm(-abs(stat))
  )
}

mbb_mean_test <- function(d, block_length = 14L, B = 2000L, seed = 12345L) {
  d <- d[is.finite(d)]
  n <- length(d)
  L <- min(block_length, n)
  starts <- seq_len(n - L + 1L)
  blocks <- ceiling(n / L)
  centered <- d - mean(d)
  set.seed(seed)

  draw_mean <- function(x) {
    s <- sample(starts, blocks, replace = TRUE)
    idx <- unlist(lapply(s, function(j) j:(j + L - 1L)), use.names = FALSE)[seq_len(n)]
    mean(x[idx])
  }

  boot <- replicate(B, draw_mean(d))
  null <- replicate(B, draw_mean(centered))
  data.frame(
    mean_loss_diff_A_minus_B = mean(d),
    ci_low = unname(quantile(boot, .025)),
    ci_high = unname(quantile(boot, .975)),
    p_value = mean(abs(null) >= abs(mean(d)))
  )
}

compare_forecasts <- function(actual, forecast_a, forecast_b, horizon, B = 2000L, block_length = 14L) {
  la <- qlike(actual, forecast_a)
  lb <- qlike(actual, forecast_b)
  dm <- dm_test(la, lb, lag = max(horizon - 1L, 0L))
  boot <- mbb_mean_test(la - lb, max(block_length, 2L * horizon), B)
  list(dm = dm, bootstrap = boot)
}

forecast_metrics <- function(actual, forecast) {
  e <- forecast - actual
  data.frame(
    n = sum(is.finite(e)),
    RMSE = sqrt(mean(e^2, na.rm = TRUE)),
    MAE = mean(abs(e), na.rm = TRUE),
    QLIKE = mean(qlike(actual, forecast), na.rm = TRUE),
    bias = mean(e, na.rm = TRUE)
  )
}
