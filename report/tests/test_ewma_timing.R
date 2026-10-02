args <- commandArgs(trailingOnly = FALSE)
self <- sub("^--file=", "", args[grepl("^--file=", args)][1])
repo_root <- normalizePath(file.path(dirname(self), "..", ".."), mustWork = TRUE)
source(file.path(repo_root, "R", "04_strategy_core.R"))

x <- c(rep(100, 60), 200, 100, 100, 100)
y <- ewma_rv(x, lambda = .94)
stopifnot(abs(y[60] - 100) < 1e-12)
stopifnot(abs(y[61] - 106) < 1e-12)
stopifnot(abs(y[62] - 105.64) < 1e-12)

future <- x
future[63:64] <- 10000
stopifnot(identical(ewma_rv(future, .94)[1:62], y[1:62]))

missing <- x
missing[62] <- NA_real_
stopifnot(ewma_rv(missing, .94)[62] == y[61])

cat("PASS: EWMA uses current-origin RV, excludes future RV, and carries state across missing RV.\n")
