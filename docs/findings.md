# Research findings

## 1. CEEMDAN did not survive proper controls

The first research path tested CEEMDAN as a volatility-forecasting feature extractor. Directly forecasting individual IMF components and recombining them was unstable because small extrapolation errors destroyed component cancellation. The design was then changed to causal endpoint features and ridge regression.

The strongest control experiment compared plain GARCH, trivially calibrated GARCH, GARCH + HAR residual correction, GARCH + CEEMDAN residual correction, and GARCH + HAR + CEEMDAN residual correction.

The clean incremental test was `GARCH_HAR_CEEMDAN_CORR` versus `GARCH_HAR_CORR`. At one day the gain was small and statistically inconclusive; at 5 and 10 days CEEMDAN worsened QLIKE. Ridge penalties frequently hit the maximum of the tuning grid at longer horizons, indicating that the data preferred to shrink the CEEMDAN contribution toward zero.

**Conclusion: CEEMDAN is retained as a negative result rather than the main model.**

## 2. Realized-volatility horse race

The project then moved to models designed for intraday realized-volatility data:

- HAR-RV
- HAR-J
- HARQ
- HARQ-F
- Realized-GARCH
- HEAVY-RM
- GARCH(1,1)

The full walk-forward experiment used 608 out-of-sample origins and 1-, 5-, and 10-day average-future-RV targets.

### Full-run QLIKE

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

Realized-GARCH has the lowest raw QLIKE at each horizon.

## 3. HARQ is the cleanest robust incremental result

HARQ is particularly useful because HAR-RV is its natural benchmark. The realized-quarticity term improves QLIKE at every horizon:

| Horizon | HARQ - HAR-RV mean QLIKE loss difference | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|
| 1d | -0.01768 | 4.0e-7 | <0.001 |
| 5d | -0.00703 | 0.0023 | 0.0065 |
| 10d | -0.00476 | 0.0097 | 0.0075 |

This supports the interpretation that accounting for measurement error through realized quarticity improves BTC realized-volatility forecasting out of sample.

## 4. HEAVY is horizon-dependent

HEAVY-RM performs well at the one-day horizon and beats both GARCH and HAR-RV on QLIKE. At 5 and 10 days it becomes materially worse than HAR-RV. It is therefore useful as a short-horizon model, not a universal winner.

## 5. Jumps and extra HARQ flexibility do not add much

HAR-J is nearly indistinguishable from HAR-RV in QLIKE. HARQ-F does not robustly beat plain HARQ and is worse at 10 days. The extra complexity is not justified by these out-of-sample results.

## 6. Standard volatility targeting controls risk, not alpha

A 20% target-volatility strategy using the one-day HARQ/Realized-GARCH ensemble reduced realized volatility to about 18.6% from roughly 43.6% for BTC buy-and-hold and improved max drawdown from about -56.7% to -30.9%.

However, daily rebalancing created high turnover and the strategy did not generate positive alpha in the tested period. This is best interpreted as risk management rather than a directional trading signal.

## 7. Final strategy horse race

A broader leakage-safe strategy lab was run on a common sample of **562 daily observations from 2025-02-16 to 2026-09-01**, charging **10 bp per unit of turnover**.

The strategy set included buy-and-hold, trend, EWMA volatility targeting, model volatility targeting, forecast-volatility z-scores, model-minus-EWMA z-scores, forecast-volatility changes, HARQ/Realized-GARCH disagreement, forecast-error adjustment, a compression/breakout rule, a volatility state machine, and trend rules with volatility overlays.

Selected results:

| Strategy | CAGR | Ann. vol | Sharpe | Sortino | Max drawdown | Annual turnover |
|---|---:|---:|---:|---:|---:|---:|
| Trend × model-vol z-score | **14.17%** | 19.15% | **0.787** | 1.265 | -15.06% | 35.65x |
| Trend | 13.07% | 17.97% | 0.773 | 1.228 | **-14.68%** | 21.43x |
| Trend + EWMA vol sizing | 7.98% | 10.81% | 0.764 | 1.226 | -8.87% | **13.38x** |
| Trend + model vol sizing | 5.96% | 9.00% | 0.688 | 1.075 | -8.03% | 16.96x |
| Model vol targeting | -4.58% | 18.80% | -0.156 | -0.221 | -28.86% | 23.76x |
| EWMA vol targeting | -3.26% | 20.50% | -0.059 | -0.085 | -32.41% | 3.67x |

The model-vol z-score raises the trend Sharpe only from 0.773 to 0.787, while annual turnover increases from 21.43x to 35.65x. That is too small to claim a robust trading edge from this sample.

More importantly, direct model volatility targeting is worse than simple EWMA targeting, and model-scaled trend is worse than EWMA-scaled trend.

## 8. Final conclusion

The project is complete at this scope.

The strongest positive result is statistical:

> **HARQ robustly improves realized-volatility forecasts relative to HAR-RV, and Realized-GARCH delivers the best raw QLIKE.**

The strongest economic result is negative but useful:

> **Superior realized-volatility forecasts do not automatically translate into superior spot-BTC trading strategies.**

The model forecast can be useful for risk measurement and sizing, but in the tested sample a simple backward-looking EWMA is difficult to beat economically. A volatility z-score only marginally improves a trend strategy and does so with materially higher turnover.

Further strategy tweaking on the same sample would create increasing data-mining risk, so the project is frozen rather than optimized further.
