# Bitcoin Realized Volatility

Research-grade Bitcoin realized-volatility forecasting using Binance 5-minute data, HARQ, Realized-GARCH and HEAVY, with leakage-safe walk-forward evaluation and an explicit economic-value test.

**Status: finished / frozen at v1.0.**

[Read the research note](report/research_note.md) · [Report audit trail](report/README.md)

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

The final strategy lab uses 562 daily returns and charges 10 bp per unit turnover. The EWMA timing bug found during red-team review was corrected before publication; no strategy parameters were retuned afterward.

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

## Public code

`main` intentionally keeps only the core implementation:

```text
R/
  btc_binance_realized_vol_horserace.R
  btc_one_day_strategy_lab.R
  btc_rv_horserace_visuals.R
```

The exploratory CEEMDAN scripts and older standalone targeting script are preserved on the `research-archive-v1` branch rather than cluttering the portfolio-facing branch.

## Repository structure

```text
R/          core research code
docs/       findings and strategy notes
results/    compact saved result tables
report/     public research note, references and audit evidence
```

Raw Binance cache files and heavyweight generated panels are intentionally excluded.

## Reproducibility notes

- Forecasts are rolling walk-forward and use only information available at each origin.
- Direct multi-day HAR-family targets are purged.
- Strategy signals at day `t` are applied to the `t -> t+1` return.
- Corrected EWMA at origin `t` incorporates observed `RV_t` when forming the `t+1` forecast.
- Turnover is measured against the passively drifted risky weight.
- Common-volatility results are ex-post diagnostics, not implementable live scaling rules.
- Unused cash earns zero and no financing charge is modeled for exposure above 1x.

## References

See [`report/references.md`](report/references.md) for the HAR-RV, HARQ, Realized-GARCH, HEAVY and QLIKE references.

## Final takeaway

```text
HARQ robustly improves HAR-RV in the saved pairwise QLIKE tests.
Realized-GARCH has the lowest raw QLIKE.
Better forecasting does not imply trading alpha.
```

This repository is for research and education. Backtests do not imply future profitability.