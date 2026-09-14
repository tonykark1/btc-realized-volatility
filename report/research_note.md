# Forecasting Bitcoin Realized Volatility

## What held up in a walk-forward test?

This note asks two separate questions:

1. Can high-frequency realized measures improve Bitcoin volatility forecasts?
2. Do better volatility forecasts create useful economic value in spot-BTC trading?

The answer to the first is **yes, in this experiment**. The answer to the second is **not convincingly**.

## Design

- Binance Spot `BTCUSDT` five-minute data.
- 1,460-day rolling training window.
- 608 rolling walk-forward forecast origins.
- Direct 1-, 5- and 10-day targets with purging for multi-day HAR-family models.
- Primary loss: QLIKE.
- Pairwise Diebold-Mariano tests plus 2,000-replication moving-block bootstrap of loss differences.
- Models: GARCH(1,1), HAR-RV, HAR-J, HARQ, HARQ-F, Realized-GARCH and HEAVY-RM.

The walk-forward sample is not an untouched preregistered holdout after the entire research-development process, so the inference should be read as evidence from a developed research pipeline rather than as a pristine confirmatory experiment.

## Forecasting horse race

Lower QLIKE is better.

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 day | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5 days | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10 days | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

**Realized-GARCH has the lowest raw QLIKE at all three horizons.** That is a ranking statement, not evidence that it statistically dominates HARQ.

## Cleanest incremental result: HARQ versus HAR-RV

| Horizon | HAR-RV QLIKE | HARQ QLIKE | Improvement | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|---:|---:|
| 1 day | 0.31215 | 0.29446 | **5.67%** | ~4.0e-7 | <0.001 |
| 5 days | 0.20955 | 0.20253 | **3.35%** | 0.0023 | 0.0065 |
| 10 days | 0.20415 | 0.19940 | **2.33%** | 0.0097 | 0.0075 |

HARQ is the strongest clean nested result in the project. Realized quarticity helps account for changing measurement error in realized variance, and the resulting specification improves QLIKE relative to standard HAR-RV at all three horizons in the saved pairwise tests.

These p-values are nominal, pairwise and loss-specific; they are not a global multiple-testing-adjusted model-selection procedure.

## What did not add much

- **HAR-J:** almost no improvement over HAR-RV.
- **HARQ-F:** more flexibility without robust incremental value over standard HARQ.
- **HEAVY-RM:** competitive at one day, materially weaker at longer horizons.
- **CEEMDAN:** the initial research direction did not establish robust incremental forecasting value once tested against leakage-safe controls and simpler benchmarks.

Keeping these negative results is part of the research record rather than something to optimize away.

## Economic-value test

The final strategy lab uses 562 daily returns from 2025-02-16 to 2026-09-01. The one-day model signal is an equal-weight, non-optimized 50/50 variance combination of HARQ and Realized-GARCH. The main table charges 10 bp per unit turnover.

A timing defect in the first EWMA benchmark was found during red-team review and corrected before publication. At origin `t`, the EWMA forecast for `t+1` now incorporates observed `RV_t`. No strategy parameter was retuned after this correction.

Selected corrected results:

| Strategy | CAGR | Ann. vol | Sharpe | Max DD | Annual turnover |
|---|---:|---:|---:|---:|---:|
| Trend × model-vol z-score | **14.17%** | 19.15% | **0.787** | -15.06% | 35.65x |
| Trend | 13.07% | 17.97% | 0.773 | -14.68% | 21.43x |
| Trend + EWMA sizing | 7.67% | 10.61% | 0.749 | -8.84% | 13.41x |
| Trend + model-vol sizing | 5.96% | 9.00% | 0.688 | -8.03% | 16.96x |
| EWMA vol targeting | -2.74% | 20.19% | -0.037 | -31.62% | 3.57x |
| Model vol targeting | -4.58% | 18.80% | -0.156 | -28.86% | 23.76x |

The model-volatility z-score only raises trend Sharpe from 0.773 to 0.787 while annual turnover rises from 21.43x to 35.65x. The apparent edge is cost-sensitive: at **25 bp** per unit turnover, plain trend Sharpe is about **0.596**, versus about **0.509** for the overlay.

Simple EWMA sizing also beats the model-based inverse-volatility rule on Sharpe. The volatility forecasts clearly contain statistical information about risk, but mechanically mapping that information into spot-BTC exposure does not create a convincing incremental trading edge here.

## Interpretation

The main distinction is:

> **Forecasting risk and monetizing that forecast are separate problems.**

The strategy exercise is an economic application on the same repeatedly examined market episode, not an independent untouched holdout and not a confirmatory alpha test. Unused cash earns zero and no financing charge is modeled for exposure above 1x, so the backtests should be interpreted as illustrative economic tests rather than deployable live strategies.

## Reproducibility and audit trail

The public repository keeps the compact evidence needed to check the published claims:

- `source_data/forecast_metrics.csv`
- `source_data/dm_tests.csv`
- `source_data/bootstrap_tests.csv`
- `source_data/strategy_metrics_main.csv`
- `source_data/strategy_metrics_common_vol.csv`
- `source_data/cost_sensitivity.csv`
- `research_code/` snapshots of the forecasting and corrected strategy scripts
- `tests/test_ewma_timing.R` guarding the EWMA timing correction
- `sessionInfo.txt` for the corrected strategy verification environment

The original forecasting run did not preserve a dependency lockfile, so the historical `rugarch` environment is not reconstructed after the fact. Heavy per-origin forecast panels, the full daily strategy path and raw five-minute Binance cache remain outside the public portfolio repository.

## Final takeaway

**Forecasting:** HARQ robustly improves HAR-RV in the saved pairwise QLIKE tests, while Realized-GARCH has the lowest raw QLIKE.

**Trading:** simple benchmarks remain hard to beat, and the apparent trend-overlay improvement is small and cost-sensitive.

**Conclusion:** statistical forecasting value does not imply trading alpha.

See [`references.md`](references.md) for the model and loss-function literature and [`../README.md`](../README.md) for the complete project overview.
