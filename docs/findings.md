# Research findings

## 1. CEEMDAN did not survive proper controls

The first research path tested CEEMDAN as a volatility-forecasting feature extractor. After causal endpoint features, ridge regularization and simple HAR/GARCH controls were introduced, the incremental CEEMDAN contribution was small and inconclusive at one day and worse at 5 and 10 days. The data frequently pushed the ridge penalty to the top of the grid at longer horizons.

**Conclusion: CEEMDAN is retained as a negative result.**

## 2. Realized-volatility horse race

The main walk-forward comparison covers HAR-RV, HAR-J, HARQ, HARQ-F, Realized-GARCH, HEAVY-RM and GARCH(1,1), with 608 forecast origins and 1-, 5- and 10-day average-future-RV targets.

| Horizon | Realized-GARCH | HARQ | HARQ-F | HEAVY-RM | HAR-J | HAR-RV | GARCH(1,1) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1d | **0.29079** | 0.29446 | 0.29545 | 0.29794 | 0.31116 | 0.31215 | 0.36502 |
| 5d | **0.19535** | 0.20253 | 0.20458 | 0.22600 | 0.20942 | 0.20955 | 0.23492 |
| 10d | **0.18146** | 0.19940 | 0.21037 | 0.22729 | 0.20359 | 0.20415 | 0.23188 |

Realized-GARCH has the lowest **raw** QLIKE at each horizon. This is a ranking statement, not evidence that it statistically dominates HARQ.

## 3. HARQ is the cleanest incremental result

| Horizon | HARQ - HAR-RV mean QLIKE loss difference | DM p-value | Block-bootstrap p-value |
|---:|---:|---:|---:|
| 1d | -0.01768 | 4.0e-7 | <0.001 |
| 5d | -0.00703 | 0.0023 | 0.0065 |
| 10d | -0.00476 | 0.0097 | 0.0075 |

These are pairwise, loss-specific tests. The walk-forward study is not an untouched preregistered holdout after the complete research process, and no global multiple-testing-adjusted winner is claimed.

The HARQ direction also survives a post-hoc Bitcoin-calendar sensitivity using 7-/30-day HAR components instead of 5-/22-day components: the QLIKE improvement remains about 5.1%, 3.4% and 2.4% at 1, 5 and 10 days respectively.

## 4. Other model findings

- HEAVY-RM is competitive at one day but weakens at longer horizons.
- HAR-J is nearly indistinguishable from HAR-RV.
- HARQ-F does not robustly improve on standard HARQ.
- Simple last-RV and rolling-mean RV forecasts are materially weaker than the leading models in the saved sample.

## 5. Economic-value test

The strategy lab covers 562 daily returns from 2025-02-16 to 2026-09-01 and charges 10 bp per unit turnover. The one-day signal is a fixed 50/50 variance combination of HARQ and Realized-GARCH.

The EWMA benchmark was corrected so that the `t+1` forecast formed at origin `t` incorporates observed `RV_t`. No rule was retuned after this correction.

| Strategy | CAGR | Ann. vol | Sharpe | Max drawdown | Annual turnover |
|---|---:|---:|---:|---:|---:|
| Trend x model-vol z-score | 14.17% | 19.15% | **0.787** | -15.06% | 35.65x |
| Trend | 13.07% | 17.97% | 0.773 | -14.68% | 21.43x |
| Trend + corrected EWMA sizing | 7.67% | 10.61% | 0.749 | -8.84% | 13.41x |
| Trend + model sizing | 5.96% | 9.00% | 0.688 | -8.03% | 16.96x |
| Corrected EWMA targeting | -2.74% | 20.19% | -0.037 | -31.62% | 3.57x |
| Model targeting | -4.58% | 18.80% | -0.156 | -28.86% | 23.76x |

At 25 bp per unit turnover, plain trend beats the z-score overlay on Sharpe (~0.596 vs ~0.509), reinforcing that the small 10 bp advantage is not convincing alpha.

The trading period is the same repeatedly examined research episode, not an independent untouched holdout.

## 6. Final conclusion

The strongest positive result is statistical:

> **HARQ improves realized-volatility forecasts relative to HAR-RV in the saved pairwise walk-forward tests, while Realized-GARCH has the lowest raw QLIKE.**

The strongest economic result is negative but useful:

> **Superior realized-volatility forecasts do not automatically translate into superior spot-BTC trading strategies.**

The project is frozen at this scope rather than tuned further on the same sample.
