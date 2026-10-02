# One-command audit of the published headline claims

near <- function(x, y, tol = 5e-5) isTRUE(abs(x - y) <= tol)

root <- function(...) file.path(...)
metrics <- read.csv(root("results", "horse_race", "metrics.csv"), check.names = FALSE)
dm <- read.csv(root("results", "horse_race", "dm_tests.csv"), check.names = FALSE)
strategy <- read.csv(root("results", "strategy_lab", "strategy_metrics_main.csv"), check.names = FALSE)
costs <- read.csv(root("results", "strategy_lab", "cost_sensitivity.csv"), check.names = FALSE)

get_metric <- function(h, model, col = "QLIKE") {
  z <- metrics[metrics$horizon == h & metrics$model == model, ]
  stopifnot(nrow(z) == 1L)
  z[[col]]
}

expected_qlike <- data.frame(
  horizon = rep(c(1, 5, 10), each = 4),
  model = rep(c("REALGARCH", "HARQ", "HAR_RV", "GARCH_11"), 3),
  value = c(
    .29078955, .29446241, .31214671, .36502203,
    .19535165, .20252605, .20955290, .23491618,
    .18145784, .19939664, .20415251, .23188012
  )
)

for (i in seq_len(nrow(expected_qlike))) {
  z <- expected_qlike[i, ]
  stopifnot(near(get_metric(z$horizon, z$model), z$value))
}

for (h in c(1, 5, 10)) {
  stopifnot(get_metric(h, "HARQ") < get_metric(h, "HAR_RV"))
  stopifnot(get_metric(h, "REALGARCH") == min(metrics$QLIKE[metrics$horizon == h]))
  z <- dm[dm$horizon == h & dm$model_A == "HARQ" & dm$model_B == "HAR_RV" & dm$loss == "QLIKE", ]
  stopifnot(nrow(z) == 1L, z$mean_loss_diff_A_minus_B < 0, z$p_value < .01)
}

expected_sharpe <- c(
  TREND_X_VOL_Z = .78704198,
  TREND = .77281161,
  TREND_EWMA = .74888959,
  TREND_MODEL_VOL = .68823793,
  EWMA_VOL_TARGET = -.03695630,
  MODEL_VOL_TARGET = -.15582947
)

for (name in names(expected_sharpe)) {
  z <- strategy[strategy$strategy == name, ]
  stopifnot(nrow(z) == 1L, near(z$Sharpe, expected_sharpe[[name]]))
}

at25 <- costs[costs$cost_bps == 25 & costs$strategy %in% c("TREND", "TREND_X_VOL_Z"), ]
stopifnot(nrow(at25) == 2L)
stopifnot(at25$Sharpe[at25$strategy == "TREND"] > at25$Sharpe[at25$strategy == "TREND_X_VOL_Z"])

cat("PASS\n")
cat("HARQ beats HAR-RV on QLIKE at 1/5/10 days in the saved walk-forward results.\n")
cat("Realized-GARCH has the lowest raw QLIKE at all three horizons.\n")
cat("Corrected strategy metrics match the publication tables.\n")
cat("At 25 bp costs, plain trend outranks the model-vol-z overlay.\n")
