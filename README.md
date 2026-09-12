# Bitcoin Realized Volatility

Research-grade Bitcoin realized-volatility forecasting using Binance 5-minute data, HARQ, Realized-GARCH, HEAVY, leakage-safe out-of-sample evaluation, and an explicit test of whether better volatility forecasts translate into better trading decisions.

## Project status

**Finished / frozen at v1.0 research scope.**

The project now has a complete research arc:

1. CEEMDAN was tested and rejected as a robust incremental forecasting feature.
2. HAR-family realized-volatility models, Realized-GARCH, HEAVY-RM, and GARCH(1,1) were compared in a walk-forward horse race.
3. HARQ delivered the cleanest robust nested improvement over HAR-RV.
4. Realized-GARCH achieved the lowest raw QLIKE at all three horizons.
5. The one-day forecasts were then tested in spot-BTC risk-sizing and trading overlays.
6. Better volatility forecasts **did not translate cleanly into better spot-BTC trading performance**.

That last negative result is part of the project, not something hidden from the repository.

## Main forecasting result

The full walk-forward run uses 608 out-of-sample origins, a 1,460-day rolling training window, 1-/5-/10-day horizons, and 2,000 moving-block bootstrap replications.

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

The strongest clean nested result is **HARQ vs HAR-RV**:

| Horizon | HAR-RV QLIKE | HARQ QLIKE | Improvement | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|---:|---:|
| 1 day | 0.31215 | 0.29446 | 5.7% | ~4e-7 | <0.001 |
| 5 days | 0.20955 | 0.20253 | 3.4% | 0.0023 | 0.0065 |
| 10 days | 0.20415 | 0.19940 | 2.3% | 0.0097 | 0.0075 |

This supports the interpretation that realized quarticity contains useful information about measurement error in realized variance.

## Other model findings

- **Realized-GARCH** has the lowest raw QLIKE at every horizon.
- **HARQ** is the cleanest statistically robust incremental result because HAR-RV is its natural nested benchmark.
- **HEAVY-RM** is useful at one day but weakens materially at 5 and 10 days.
- **HAR-J** adds almost nothing relative to HAR-RV.
- **HARQ-F** adds complexity without a robust improvement over standard HARQ.
- **CEEMDAN** does not survive leakage-safe controls and is retained as a documented negative result.

## Trading / economic-value result

The project first tested standard long-only volatility targeting using the one-day HARQ + Realized-GARCH forecast. It successfully reduced realized risk and drawdown, but high turnover and weak BTC returns meant that forecasting gains did not become alpha.

A broader strategy lab then tested the forecast as:

- direct inverse-volatility sizing;
- rolling forecast-volatility z-scores;
- model-minus-EWMA z-scores;
- forecast-volatility changes;
- model disagreement;
- forecast-error adjustment;
- compression/breakout regimes;
- a four-state volatility regime rule; and
- volatility overlays on a simple BTC trend strategy.

The final common evaluation sample is **562 daily observations from 2025-02-16 to 2026-09-01**, with **10 bp transaction cost per unit of turnover**.

Selected results:

| Strategy | CAGR | Ann. vol | Sharpe | Max drawdown | Annual turnover |
|---|---:|---:|---:|---:|---:|
| Trend × model-vol z-score | **14.17%** | 19.15% | **0.787** | -15.06% | 35.65x |
| Trend | 13.07% | 17.97% | 0.773 | **-14.68%** | 21.43x |
| Trend + EWMA vol sizing | 7.98% | 10.81% | 0.764 | -8.87% | **13.38x** |
| Trend + model vol sizing | 5.96% | 9.00% | 0.688 | -8.03% | 16.96x |
| Model vol targeting | -4.58% | 18.80% | -0.156 | -28.86% | 23.76x |
| EWMA vol targeting | -3.26% | 20.50% | -0.059 | -32.41% | 3.67x |

The important conclusion is not that `TREND_X_VOL_Z` is a discovered trading edge. Its Sharpe improvement over plain trend is small and comes with materially higher turnover. More importantly, **model-based volatility sizing loses to simple EWMA sizing**, both standalone and inside the trend strategy.

The economic-value conclusion is therefore:

> **Better realized-volatility forecasts do not automatically produce better spot-BTC trading strategies.**

The volatility forecast remains useful as a forecasting and risk-measurement object; its incremental trading value in this sample is limited.

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
    run_summary.txt
```

Raw Binance cache files and large generated datasets are intentionally excluded from Git. The scripts rebuild the market-data cache and generated outputs locally.

## Recommended execution order

For the main forecasting analysis:

```r
source("R/btc_binance_realized_vol_horserace.R")
source("R/btc_rv_horserace_visuals.R")
```

For the original volatility-targeting application:

```r
source("R/btc_standard_vol_targeting.R")
```

For the final economic-value / strategy horse race:

```r
source("R/btc_one_day_strategy_lab.R")
```

The strategy lab expects the local horse-race outputs (including `forecasts.csv` and `daily_realized_measures.csv`) generated by the forecasting script.

The CEEMDAN scripts are retained for reproducibility of the research path and negative result:

```r
source("R/btc_ceemdan_binance_5m_backtest.R")
source("R/btc_ceemdan_binance_controls_v2.R")
```

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
- Strategy turnover is measured against the passively drifted risky weight rather than yesterday's target weight.
- Common-volatility results are explicitly treated as ex-post diagnostics, not implementable live scaling rules.
- The raw Binance cache lives under `cache/` and is ignored by Git.
- Negative results are retained rather than optimized away.

## Final research takeaway

```text
Forecasting:
HARQ robustly improves on HAR-RV.
Realized-GARCH has the best raw QLIKE.

Trading:
The forecast reduces risk when used for sizing,
but simple EWMA is hard to beat economically.
A model-vol z-score only marginally improves a trend rule
and does so with substantially more turnover.

Conclusion:
statistical forecasting value != trading alpha
```

## Disclaimer

This repository is for research and education. Forecast performance and backtests do not imply future profitability. Volatility targeting can reduce risk while still lose money, and repeated strategy tuning on the same out-of-sample period can create false discoveries.
