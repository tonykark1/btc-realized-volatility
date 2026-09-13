# Bitcoin Realized Volatility

Research-grade Bitcoin realized-volatility forecasting using Binance 5-minute data, HARQ, Realized-GARCH, HEAVY, leakage-safe walk-forward evaluation, and an explicit test of whether better volatility forecasts translate into better trading decisions.

## Project status

**Finished / frozen at v1.0 research scope.**

The project has a complete research arc:

1. CEEMDAN was tested and rejected as a robust incremental forecasting feature.
2. HAR-family realized-volatility models, Realized-GARCH, HEAVY-RM, and GARCH(1,1) were compared in a rolling walk-forward horse race.
3. HARQ delivered the cleanest nested improvement over HAR-RV.
4. Realized-GARCH achieved the lowest **raw** QLIKE at all three horizons.
5. The one-day forecasts were tested in spot-BTC risk-sizing and trading overlays.
6. Better volatility forecasts **did not translate cleanly into better spot-BTC trading performance**.

The negative results are retained rather than optimized away.

## Main forecasting result

The full run uses 608 walk-forward forecast origins, a 1,460-day rolling training window, 1-/5-/10-day horizons, and 2,000 moving-block bootstrap replications.

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

The strongest clean nested result is HARQ versus HAR-RV:

| Horizon | HAR-RV QLIKE | HARQ QLIKE | Improvement | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|---:|---:|
| 1 day | 0.31215 | 0.29446 | 5.7% | ~4e-7 | <0.001 |
| 5 days | 0.20955 | 0.20253 | 3.4% | 0.0023 | 0.0065 |
| 10 days | 0.20415 | 0.19940 | 2.3% | 0.0097 | 0.0075 |

These are **pairwise, loss-specific** tests. They are not a global multiple-testing-adjusted model-selection procedure, and the walk-forward sample is not an untouched preregistered holdout after the full research process.

Post-hoc direct inference does **not** establish that Realized-GARCH statistically dominates HARQ; its advantage is a raw QLIKE ranking. The strongest inferential statement remains HARQ versus its natural HAR-RV benchmark.

## Other model findings

- **Realized-GARCH:** lowest raw QLIKE at every horizon.
- **HARQ:** cleanest robust incremental result relative to HAR-RV.
- **HEAVY-RM:** useful at one day but weakens at 5 and 10 days.
- **HAR-J:** adds almost nothing relative to HAR-RV.
- **HARQ-F:** adds complexity without a robust improvement over standard HARQ.
- **CEEMDAN:** does not survive leakage-safe controls and remains a documented negative result.

## Trading / economic-value result

The final strategy lab uses 562 daily observations from 2025-02-16 to 2026-09-01, charging 10 bp per unit of turnover. The one-day model signal is a simple, non-optimized 50/50 variance combination of HARQ and Realized-GARCH.

A timing defect in the first EWMA benchmark implementation was corrected on 2026-09-13: at origin `t`, the EWMA forecast for `t+1` now incorporates the already observed `RV_t`, rather than stopping at `RV_{t-1}`. No strategy parameters were retuned after this correction.

Selected corrected results:

| Strategy | CAGR | Ann. vol | Sharpe | Max drawdown | Annual turnover |
|---|---:|---:|---:|---:|---:|
| Trend x model-vol z-score | **14.17%** | 19.15% | **0.787** | -15.06% | 35.65x |
| Trend | 13.07% | 17.97% | 0.773 | **-14.68%** | 21.43x |
| Trend + EWMA vol sizing | 7.67% | 10.61% | 0.749 | -8.84% | **13.41x** |
| Trend + model vol sizing | 5.96% | 9.00% | 0.688 | -8.03% | 16.96x |
| EWMA vol targeting | -2.74% | 20.19% | -0.037 | -31.62% | 3.57x |
| Model vol targeting | -4.58% | 18.80% | -0.156 | -28.86% | 23.76x |

The model-vol z-score raises trend Sharpe only from 0.773 to 0.787 while annual turnover rises from 21.43x to 35.65x. At 25 bp per unit turnover, the ranking reverses: plain trend Sharpe is about 0.596 versus about 0.509 for the z-score overlay.

The economic conclusion is therefore:

> **Better realized-volatility forecasts do not automatically produce better spot-BTC trading strategies.**

The trading episode is an economic application on the same repeatedly examined research period, not an independent untouched holdout and not a confirmatory alpha test.

## Repository structure

```text
R/
  btc_ceemdan_binance_5m_backtest.R
  btc_ceemdan_binance_controls_v2.R
  btc_binance_realized_vol_horserace.R
  btc_standard_vol_targeting.R
  btc_one_day_strategy_lab.R
  btc_rv_horserace_visuals.R

docs/
  findings.md
  volatility_targeting_results.md
  strategy_results.md

results/
  horse_race/
  strategy_lab/
    strategy_metrics_main.csv
    strategy_metrics_common_vol.csv
    cost_sensitivity.csv
    run_summary.txt

report/
  btc_realized_volatility_report.pdf
  btc_realized_volatility_report.html
  btc_realized_volatility_report.qmd
  linkedin_post.md
  linkedin_carousel.md
  source_data/
```

Raw Binance cache files are intentionally excluded from Git. The report bundle carries the saved outputs needed to audit the published tables without committing the raw market-data cache.

## Recommended execution order

```r
source("R/btc_binance_realized_vol_horserace.R")
source("R/btc_rv_horserace_visuals.R")
source("R/btc_standard_vol_targeting.R")
source("R/btc_one_day_strategy_lab.R")
```

The CEEMDAN scripts are retained for reproducibility of the research path and negative result.

## Data and units

The main sample uses Binance Spot `BTCUSDT` 5-minute candles. Intraday returns are expressed in percent, so daily realized variance is in percent-squared units:

```text
RV_t = sum_i r_{t,i}^2
RQ_t = (M_t / 3) sum_i r_{t,i}^4
BV_t = (pi / 2) sum_i |r_{t,i}| |r_{t,i-1}|
J_t  = max(RV_t - BV_t, 0)
```

## Reproducibility notes

- Forecasts are walk-forward and use only information available at each forecast origin.
- Direct multi-day HAR-family targets are purged so training targets end no later than the forecast origin.
- Strategy signals at day `t` use information available through `t` and are applied to the `t -> t+1` BTC return.
- EWMA at origin `t` incorporates `RV_t` when forming the `t+1` variance forecast.
- Strategy turnover is measured against the passively drifted risky weight rather than yesterday's target weight.
- Common-volatility results are ex-post diagnostics, not implementable live scaling rules.
- No financing charge is modeled for exposure above 1x and unused cash earns zero; trading results should therefore be interpreted as illustrative economic tests.
- Negative results are retained rather than tuned away.

## Methodological references

- Corsi (2009), *A Simple Approximate Long-Memory Model of Realized Volatility*, Journal of Financial Econometrics. DOI: `10.1093/jjfinec/nbp001`
- Bollerslev, Patton & Quaedvlieg (2016), *Exploiting the Errors: A Simple Approach for Improved Volatility Forecasting*, Journal of Econometrics. DOI: `10.1016/j.jeconom.2015.10.007`
- Hansen, Huang & Shek (2012), *Realized GARCH: A Joint Model for Returns and Realized Measures of Volatility*, Journal of Applied Econometrics. DOI: `10.1002/jae.1234`
- Shephard & Sheppard (2010), *Realising the Future: Forecasting with High-Frequency-Based Volatility (HEAVY) Models*, Journal of Applied Econometrics. DOI: `10.1002/jae.1158`
- Patton (2011), *Volatility Forecast Comparison Using Imperfect Volatility Proxies*, Journal of Econometrics. DOI: `10.1016/j.jeconom.2010.03.034`

## Final takeaway

```text
Forecasting:
HARQ robustly improves on HAR-RV in the saved pairwise QLIKE tests.
Realized-GARCH has the lowest raw QLIKE.

Trading:
The forecast reduces risk when used for sizing,
but simple EWMA remains hard to beat economically.
A model-vol z-score only marginally improves a trend rule
and does so with substantially more turnover.

Conclusion:
statistical forecasting value != trading alpha
```

## Disclaimer

This repository is for research and education. Forecast performance and backtests do not imply future profitability. Volatility targeting can reduce risk while still losing money, and repeated strategy tuning on the same walk-forward period can create false discoveries.
