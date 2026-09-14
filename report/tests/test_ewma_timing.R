# Exercise the EWMA block from the bundled production script on synthetic data.
args <- commandArgs(trailingOnly=FALSE)
self <- sub('^--file=', '', args[grepl('^--file=', args)][1])
report_dir <- normalizePath(file.path(dirname(self),'..'), mustWork=TRUE)
code <- readLines(file.path(report_dir,'research_code/btc_one_day_strategy_lab.R'),warn=FALSE)
start <- grep('^# EWMA RV benchmark:',code)
end <- grep('^px\\$ewma_rv <- ew$',code)
stopifnot(length(start)==1L,length(end)==1L,end>start)
block <- parse(text=code[start:end])
run_ewma <- function(rv) {
  e <- new.env(parent=baseenv())
  e$px <- data.frame(rv_actual=rv)
  e$cfg <- list(ewma_lambda=.94)
  eval(block,envir=e)
  e$px$ewma_rv
}
x <- c(rep(100,60),200,100,100,100)
y <- run_ewma(x)
stopifnot(abs(y[60]-100)<1e-12,abs(y[61]-106)<1e-12,abs(y[62]-105.64)<1e-12)
# The former one-day-stale recursion gives 100 at day 61 and fails this test.
future <- x; future[63:64] <- 10000
stopifnot(identical(run_ewma(future)[1:62],y[1:62]))
missing <- x; missing[62] <- NA_real_
stopifnot(run_ewma(missing)[62]==y[61])
cat('PASS: current-origin RV is incorporated, future RV is excluded, missing RV carries the state.\n')
