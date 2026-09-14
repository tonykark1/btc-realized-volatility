# Bitcoin Realized Volatility

Research-grade Bitcoin realized-volatility forecasting using Binance 5-minute data, HARQ, Realized-GARCH, HEAVY, leakage-safe walk-forward evaluation, and an explicit test of whether better volatility forecasts translate into better trading decisions.

**Project status: finished / frozen at v1.0 research scope.**

[Read the public research note](report/research_note.md) · [Report audit trail](report/README.md)

## Research arc

1. CEEMDAN was tested and rejected as a robust incremental forecasting feature.
2. HAR-family models, Realized-GARCH, HEAVY-RM and GARCH(1,1) were compared in a rolling walk-forward horse race.
3. HARQ delivered the cleanest nested improvement over HAR-RV.
4. Realized-GARCH achieved the lowest **raw** QLIKE at all three horizons.
5. One-day forecasts were tested in spot-BTC risk-sizing and trading overlays.
6. Better volatility forecasts **did not translate cleanly into better spot-BTC trading performance**.

The negative results are retained rather than optimized away.

## Main forecasting result

The full run uses 608 walk-forward origins, a 1,460-day rolling training window, 1-/5-/10-day horizons and 2,000 moving-block bootstrap replications.

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

The strongest clean nested result is HARQ versus HAR-RV:

| Horizon | HAR-RV QLIKE | HARQ QLIKE | Improvement | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|---:|---:|
| 1 day | 0.31215 | 0.29446 | **5.67%** | ~4e-7 | <0.001 |
| 5 days | 0.20955 | 0.20253 | **3.35%** | 0.0023 | 0.0065 |
| 10 days | 0.20415 | 0.19940 | **2.33%** | 0.0097 | 0.0075 |

These are pairwise, loss-specific tests, not a global multiple-testing-adjusted model-selection procedure. The walk-forward sample is also not an untouched preregistered holdout after the full research-development process.

**Realized-GARCH has the lowest raw QLIKE; the project does not claim that it statistically dominates HARQ.**

## Other model findings

- **HARQ:** cleanest robust incremental result relative to HAR-RV.
- **Realized-GARCH:** lowest raw QLIKE at every horizon.
- **HEAVY-RM:** useful at one day but weakens at 5 and 10 days.
- **HAR-J:** adds almost nothing relative to HAR-RV.
- **HARQ-F:** adds complexity without robust incremental value over standard HARQ.
- **CEEMDAN:** does not survive leakage-safe controls and remains a documented negative result.

## Trading / economic-value result

The final strategy lab uses 562 daily returns from 2025-02-16 to 2026-09-01 and charges 10 bp per unit turnover. The one-day model signal is a simple, non-optimized 50/50 variance combination of HARQ and Realized-GARCH.

A timing defect in the original EWMA benchmark was found during red-team review and corrected before publication: at origin `t`, the EWMA forecast for `t+1` now incorporates observed `RV_t`. **No strategy parameter was retuned after the correction.**

| Strategy | CAGR | Ann. vol | Sharpe | Max DD | Annual turnover |
|---|---:|---:|---:|---:|---:|
| Trend × model-vol z-score | **14.17%** | 19.15% | **0.787** | -15.06% | 35.65x |
| Trend | 13.07% | 17.97% | 0.773 | -14.68% | 21.43x |
| Trend + EWMA sizing | 7.67% | 10.61% | 0.749 | -8.84% | 13.41x |
| Trend + model-vol sizing | 5.96% | 9.00% | 0.688 | -8.03% | 16.96x |
| EWMA vol targeting | -2.74% | 20.19% | -0.037 | -31.62% | 3.57x |
| Model vol targeting | -4.58% | 18.80% | -0.156 | -28.86% | 23.76x |

The model-vol z-score only raises trend Sharpe from 0.773 to 0.787 while annual turnover rises from 21.43x to 35.65x. At **25 bp** per unit turnover, the ranking reverses: plain trend Sharpe is about **0.596** versus about **0.509** for the overlay.

> **Better realized-volatility forecasts do not automatically produce better spot-BTC trading strategies.**

The trading exercise reuses the same repeatedly examined research period, so it is an economic application rather than an independent confirmatory alpha test.

## Repository structure

```text
R/
  btc_binance_realized_vol_horserace.R
  btc_one_day_strategy_lab.R
  btc_rv_horserace_visuals.R
  ...

docs/
  findings.md
  strategy_results.md
  volatility_targeting_results.md

results/
  horse_race/
  strategy_lab/
    strategy_metrics_main.csv
    strategy_metrics_common_vol.csv
    cost_sensitivity.csv
    run_summary.txt

report/
  research_note.md
  README.md
  linkedin_post.md
  linkedin_carousel.md
  references.md
  sessionInfo.txt
  source_data/
  research_code/
  tests/
```

Raw Binance cache files, heavyweight per-origin forecast panels, the full daily strategy path and rendered publication files are intentionally excluded from the public portfolio repository. The compact report bundle retains the evidence needed to audit the headline claims.

## Data and units

The main sample uses Binance Spot `BTCUSDT` five-minute candles. Intraday returns are in percent, so daily realized variance is in percent-squared units:

```text
RV_t = sum_i r_{t,i}^2
RQ_t = (M_t / 3) sum_i r_{t,i}^4
BV_t = (pi / 2) sum_i |r_{t,i}| |r_{t,i-1}|
J_t  = max(RV_t - BV_t, 0)
```

## Reproducibility notes

- Forecasts are rolling walk-forward and use only information available at each origin.
- Direct multi-day HAR-family targets are purged so training targets end no later than the forecast origin.
- Strategy signals at day `t` are applied to the `t -> t+1` return.
- Corrected EWMA at origin `t` incorporates `RV_t` when forming the `t+1` forecast.
- Strategy turnover is measured against the passively drifted risky weight.
- Common-volatility results are ex-post diagnostics, not implementable live scaling rules.
- Unused cash earns zero and no financing charge is modeled for exposure above 1x.
- The original forecasting run did not preserve a dependency lockfile; `report/sessionInfo.txt` records only the corrected strategy verification environment.

## Methodological references

See [`report/references.md`](report/references.md) for Corsi (HAR-RV), Bollerslev-Patton-Quaedvlieg (HARQ), Hansen-Huang-Shek (Realized-GARCH), Shephard-Sheppard (HEAVY), and Patton (QLIKE / volatility forecast comparison).

## Final takeaway

```text
Forecasting:
HARQ robustly improves HAR-RV in the saved pairwise QLIKE tests.
Realized-GARCH has the lowest raw QLIKE.

Trading:
Simple benchmarks remain hard to beat.
The model-vol z-score only marginally improves trend in the 10 bp case
and the ranking reverses at higher costs.

Conclusion:
statistical forecasting value != trading alpha
```

## Disclaimer

This repository is for research and education. Forecast performance and backtests do not imply future profitability. Repeated strategy tuning on the same walk-forward period can create false discoveries.
