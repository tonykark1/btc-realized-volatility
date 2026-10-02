# Realized measures from intraday BTC bars

build_realized_measures <- function(bars, min_bars = 285L) {
  stopifnot(all(c("datetime", "close") %in% names(bars)))
  x <- bars[is.finite(bars$close) & bars$close > 0 & !is.na(bars$datetime), c("datetime", "close")]
  x$datetime <- as.POSIXct(x$datetime, tz = "UTC")
  x <- x[order(x$datetime), ]
  x$date <- as.Date(x$datetime, tz = "UTC")
  x$r <- c(NA_real_, 100 * diff(log(x$close)))

  one_day <- function(z) {
    r <- z$r[is.finite(z$r)]
    m <- length(r)
    if (m < min_bars) return(NULL)
    rv <- sum(r^2)
    rq <- (m / 3) * sum(r^4)
    bv <- if (m > 1L) (pi / 2) * sum(abs(r[-1L]) * abs(r[-m])) else NA_real_
    data.frame(
      date = z$date[1], bars = m, ret_pct = sum(r), RV = rv, RQ = rq,
      BV = bv, J = max(rv - bv, 0), close = tail(z$close, 1)
    )
  }

  out <- do.call(rbind, lapply(split(x, x$date), one_day))
  rownames(out) <- NULL
  out
}
