# Volatility-targeting application

A standard next-day volatility-targeting rule was applied to the HARQ / Realized-GARCH forecast ensemble:

```text
weight_t = target_vol_annual / forecast_vol_annual
```

The first implementation used:

- 20% annualized volatility target;
- long-only exposure;
- 1.5x maximum weight;
- daily rebalancing;
- 10 bp one-way transaction cost per unit change in BTC weight; and
- zero cash return for simplicity.

## First full result

| Metric | Vol-target ensemble, net | Vol-target ensemble, gross | BTC buy & hold |
|---|---:|---:|---:|
| Observations | 617 | 617 | 617 |
| Total return | -13.06% | -9.54% | -31.14% |
| CAGR | -7.95% | -5.76% | -19.80% |
| Annualized volatility | **18.56%** | 18.57% | 43.65% |
| Sharpe, rf=0 | -0.353 | -0.227 | -0.286 |
| Max drawdown | **-30.91%** | -29.66% | -56.71% |

The strategy achieved the risk target reasonably well: 18.6% realized volatility against a 20% target.

Average BTC weight was about 0.47, with a median of 0.47 and a 10th/90th percentile range of roughly 0.32 to 0.62. The leverage cap was never binding.

## Turnover problem

Annualized turnover was about 23.5x NAV. Total turnover over the sample was about 39.7x, producing approximately 3.97% cumulative transaction-cost drag at 10 bp.

The economic conclusion is therefore:

> The forecasts are useful for risk control, but naive daily full rebalancing is too expensive at the assumed trading cost.

## Forecast quality in this strategy run

| Model | QLIKE |
|---|---:|
| Ensemble | **0.27968** |
| Realized-GARCH | 0.28867 |
| HARQ | 0.29398 |

The next implementation test should keep the forecasting models fixed and reduce turnover through weight smoothing, no-trade bands, or lower rebalancing frequency.
