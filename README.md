# Bitcoin Realized Volatility

Research-grade Bitcoin realized-volatility forecasting using Binance 5-minute data, HARQ, Realized-GARCH, HEAVY, out-of-sample evaluation, volatility targeting, and publication-quality visualizations.

## What this repository does

This project started as a test of whether CEEMDAN decomposition adds useful information to Bitcoin volatility forecasts. After leakage-safe controls showed that the CEEMDAN signal was not robust, the project moved to models designed specifically for high-frequency realized volatility.

The workflow:

1. downloads/caches Binance Spot `BTCUSDT` 5-minute candles;
2. constructs daily realized variance, bipower variation, jumps, realized quarticity, and semivariances;
3. runs leakage-safe walk-forward forecasts at 1-, 5-, and 10-day horizons;
4. compares GARCH(1,1), HAR-RV, HAR-J, HARQ, HARQ-F, Realized-GARCH, and HEAVY-RM;
5. evaluates RMSE, MAE, QLIKE, log-RMSE, Diebold-Mariano tests, and moving-block bootstrap intervals;
6. converts next-day volatility forecasts into a standard volatility-targeting strategy; and
7. generates publication-quality visualizations.

## Main empirical result

The strongest clean result is **HARQ vs HAR-RV**. In the full 608-origin walk-forward run, HARQ improves QLIKE at every forecast horizon:

| Horizon | HAR-RV QLIKE | HARQ QLIKE | Improvement |
|---:|---:|---:|---:|
| 1 day | 0.31215 | 0.29446 | 5.7% |
| 5 days | 0.20955 | 0.20253 | 3.4% |
| 10 days | 0.20415 | 0.19940 | 2.3% |

The paired evidence is also supportive: DM p-values are approximately `4e-7`, `0.0023`, and `0.0097`, while the moving-block bootstrap p-values are `<0.0005`, `0.0065`, and `0.0075` for 1-, 5-, and 10-day QLIKE respectively.

**Realized-GARCH has the lowest raw QLIKE** in the full horse race at all three horizons (`0.29079`, `0.19535`, `0.18146`), but its advantage over HAR-RV is less uniformly significant than HARQ's nested improvement over HAR-RV.

HEAVY-RM is useful at one day but does not hold up at longer horizons. HAR-J contributes little relative to plain HAR-RV. HARQ-F adds complexity without a robust improvement over standard HARQ.

## CEEMDAN result

The CEEMDAN experiments are retained as a documented negative result. Once compared against trivial GARCH calibration and HAR-based residual controls, CEEMDAN does not show robust incremental predictive value. At 5- and 10-day horizons the ridge penalties frequently move to the top of the grid, effectively shrinking the CEEMDAN coefficients toward zero.

That negative result motivated the realized-volatility horse race.

## Volatility targeting

The next-day HARQ/Realized-GARCH forecasts are also used in a standard volatility-targeting application:

```text
weight_t = target annualized volatility / forecast annualized volatility
```

with long-only bounds, a leverage cap, and transaction costs.

In the first 20% target-vol ensemble run, realized strategy volatility was about **18.6%**, versus **43.6%** for BTC buy-and-hold, and max drawdown fell from about **-56.7% to -30.9%**. The strategy did not generate alpha in that sample; daily full rebalancing produced high turnover, and a 10 bp cost assumption materially reduced returns. This is best interpreted as a risk-management application rather than a directional trading signal.

## Repository structure

```text
R/
  btc_ceemdan_binance_5m_backtest.R
  btc_ceemdan_binance_controls_v2.R
  btc_binance_realized_vol_horserace.R
  btc_standard_vol_targeting.R
  btc_rv_horserace_visuals.R

docs/
  findings.md
  volatility_targeting_results.md

results/
  horse_race/                  # key browseable full-run outputs
```

Raw Binance cache files and large generated datasets are intentionally excluded from Git. The research scripts rebuild the required market-data cache and generated outputs locally.

## Recommended execution order

For the main realized-volatility analysis:

```r
source("R/btc_binance_realized_vol_horserace.R")
source("R/btc_rv_horserace_visuals.R")
source("R/btc_standard_vol_targeting.R")
```

The two CEEMDAN scripts are included for reproducibility of the research path and negative result:

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

The full horse-race run uses a 1,460-day rolling training window, 608 out-of-sample origins, horizons of 1/5/10 days, and 2,000 moving-block bootstrap replications.

## Reproducibility notes

- Forecasts are walk-forward and use only information available at each forecast origin.
- Direct multi-day HAR-family targets are purged so training targets end no later than the forecast origin.
- The raw Binance data cache lives under `cache/` and is ignored by Git.
- The visualization script uses a color-blind-safer palette and visually separates model identity from statistical direction.
- The five active R source files in `R/` were restored from the verified project archive and committed directly to the repository.

## Disclaimer

This repository is for research and education. Forecast performance and backtests do not imply future profitability. Volatility targeting can reduce risk while still losing money, and leverage/short-volatility implementations can materially increase tail risk.
