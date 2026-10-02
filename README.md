# Bitcoin Realized Volatility

Bitcoin realized-volatility forecasting using Binance 5-minute data, HARQ, Realized-GARCH and HEAVY, with rolling walk-forward evaluation and an explicit economic-value test.

**Status: finished / frozen at v1.0.**

[Research note](report/research_note.md) · [Audit trail](report/README.md) · [Full production code](../../tree/research-archive-v1)

## Main result

The full experiment uses 608 walk-forward origins, a 1,460-day rolling training window, 1-/5-/10-day horizons and 2,000 moving-block bootstrap replications.

| Horizon | Realized-GARCH | HARQ | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.20415 | 0.23188 |

Realized-GARCH has the lowest **raw** QLIKE at all three horizons. The cleanest inferential result is HARQ versus HAR-RV:

| Horizon | QLIKE improvement | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|
| 1d | **5.67%** | ~4e-7 | <0.001 |
| 5d | **3.35%** | 0.0023 | 0.0065 |
| 10d | **2.33%** | 0.0097 | 0.0075 |

These are pairwise, loss-specific tests, not a global multiple-testing-adjusted model-selection procedure. The walk-forward sample is not an untouched preregistered holdout after the full research-development process.

## Economic-value test

The strategy lab uses 562 daily returns and 10 bp per unit turnover. The corrected EWMA benchmark incorporates observed `RV_t` when forming the `t+1` forecast; no strategy parameters were retuned afterward.

| Strategy | Sharpe | Annual turnover |
|---|---:|---:|
| Trend × model-vol z-score | **0.787** | 35.65x |
| Trend | 0.773 | 21.43x |
| Trend + EWMA sizing | 0.749 | 13.41x |
| Trend + model-vol sizing | 0.688 | 16.96x |
| EWMA vol targeting | -0.037 | 3.57x |
| Model vol targeting | -0.156 | 23.76x |

At 25 bp costs, plain trend beats the model-vol-z overlay.

> **Better realized-volatility forecasts do not automatically produce better spot-BTC trading strategies.**

## Audit-first public code

`main` is deliberately small enough to inspect. It contains the mathematical core, not every downloader, cache helper, experiment and plotting routine used during development.

```text
R/
  01_realized_measures.R   RV / RQ / BV / jump construction
  02_forecast_core.R       HAR-RV, HARQ, HEAVY-RM, walk-forward logic
  03_inference.R           QLIKE, DM test, moving-block bootstrap
  04_strategy_core.R       corrected EWMA and core economic-value test
  05_audit_results.R       one-command check of published headline results
```

Run:

```r
source("R/05_audit_results.R")
```

to verify the committed headline tables. The full pre-refactor implementation, including Binance ingestion, Realized-GARCH/GARCH package plumbing, all exploratory models and the full visualization suite, is preserved on [`research-archive-v1`](../../tree/research-archive-v1).

## Repository structure

```text
R/          compact audit implementation
results/    saved result tables from the frozen full run
report/     public research note, references and validation evidence
docs/       supporting findings and strategy notes
```

Raw Binance caches and heavyweight per-origin panels are intentionally excluded from `main`.

## Final takeaway

```text
HARQ robustly improves HAR-RV in the saved pairwise QLIKE tests.
Realized-GARCH has the lowest raw QLIKE.
Better forecasting does not imply trading alpha.
```

This repository is for research and education. Backtests do not imply future profitability.