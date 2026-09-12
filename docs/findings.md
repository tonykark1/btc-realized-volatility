# Research findings

## 1. CEEMDAN did not survive proper controls

The first research path tested CEEMDAN as a volatility-forecasting feature extractor. Directly forecasting individual IMF components and recombining them was unstable because small extrapolation errors destroyed component cancellation. The design was then changed to causal endpoint features and ridge regression.

The strongest control experiment compared:

- plain GARCH;
- trivially calibrated GARCH;
- GARCH + HAR residual correction;
- GARCH + CEEMDAN residual correction; and
- GARCH + HAR + CEEMDAN residual correction.

The clean incremental test was `GARCH_HAR_CEEMDAN_CORR` versus `GARCH_HAR_CORR`. At one day the gain was small and statistically inconclusive; at 5 and 10 days CEEMDAN worsened QLIKE. Ridge penalties frequently hit the maximum of the tuning grid at longer horizons, indicating that the data preferred to shrink the CEEMDAN contribution toward zero.

Conclusion: **CEEMDAN is retained as a negative result rather than the main model.**

## 2. High-frequency realized-volatility models are more promising

The project then moved to realized-volatility models built for intraday data:

- HAR-RV;
- HAR-J;
- HARQ;
- HARQ-F;
- Realized-GARCH;
- HEAVY-RM; and
- GARCH(1,1) benchmark.

The full walk-forward experiment used 608 OOS origins and 1-, 5-, and 10-day average-future-RV targets.

### Full-run QLIKE

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

Realized-GARCH has the lowest raw QLIKE at each horizon.

## 3. HARQ is the cleanest robust incremental result

HARQ is particularly useful because HAR-RV is its natural benchmark. The incremental realized-quarticity term improves QLIKE at every horizon:

| Horizon | HARQ - HAR-RV mean QLIKE loss difference | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|
| 1d | -0.01768 | 4.0e-7 | <0.0005 |
| 5d | -0.00703 | 0.0023 | 0.0065 |
| 10d | -0.00476 | 0.0097 | 0.0075 |

This supports the interpretation that accounting for measurement error through realized quarticity improves BTC realized-volatility forecasting out of sample.

## 4. HEAVY is horizon-dependent

HEAVY-RM performs well at the one-day horizon and beats both GARCH and HAR-RV on QLIKE. However, at 5 and 10 days it becomes significantly worse than HAR-RV. It is therefore useful as a short-horizon model, not as a universal winner.

## 5. Jumps and extra HARQ flexibility do not add much

HAR-J is nearly indistinguishable from HAR-RV in QLIKE. HARQ-F does not robustly beat plain HARQ and is worse at 10 days. The extra complexity is not justified by these OOS results.

## 6. What to test next

The highest-value next tests are:

1. direct Realized-GARCH vs HARQ inference;
2. forecast combinations of Realized-GARCH and HARQ;
3. turnover-aware volatility targeting rather than daily full rebalancing;
4. comparison of forecast RV with BTC option-implied variance for a variance-risk-premium strategy.
