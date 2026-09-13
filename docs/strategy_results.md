# Strategy-lab results

## Purpose

The forecasting horse race established that HARQ and Realized-GARCH forecast Bitcoin realized variance well in the saved walk-forward experiment. The final question was whether those statistical gains have economic value in spot-BTC trading.

This is an **economic application on the same repeatedly examined research episode**, not an independent untouched holdout and not a confirmatory alpha test.

## Evaluation design

- Common sample: **2025-02-16 to 2026-09-01**
- Observations: **562 daily returns**
- Main transaction cost: **10 bp per unit of turnover**
- One-day model forecast: **50% HARQ variance + 50% Realized-GARCH variance**, fixed equal weights
- Long-only exposure with caps where relevant
- Signals formed at `t` and applied to BTC return `t -> t+1`
- Rolling z-scores use lagged moments only
- Turnover is measured against the passively drifted risky weight
- An ex-post common-volatility table is reported only as a diagnostic
- Unused cash earns zero and no financing cost is charged above 1x exposure

### EWMA timing correction

The original strategy-lab file described an EWMA forecast at origin `t` as using information through `t`, but the recursion actually stopped at `RV_{t-1}`. This was corrected on 2026-09-13 so the `t+1` EWMA variance forecast incorporates the already observed `RV_t`. No strategy rule or parameter was retuned after the correction.

## Corrected main results

| Strategy | CAGR | Ann. vol | Sharpe | Sortino | Max drawdown | Calmar | CVaR 95% | Annual turnover | Avg. weight |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TREND_X_VOL_Z | 14.17% | 19.15% | **0.787** | 1.265 | -15.06% | 0.941 | -2.405% | 35.65x | 0.314 |
| TREND | 13.07% | 17.97% | 0.773 | 1.228 | **-14.68%** | 0.890 | -2.186% | 21.43x | 0.278 |
| TREND_EWMA | 7.67% | 10.61% | 0.749 | 1.186 | -8.84% | 0.868 | -1.259% | **13.41x** | 0.155 |
| TREND_MODEL_VOL | 5.96% | 9.00% | 0.688 | 1.075 | -8.03% | 0.743 | -1.125% | 16.96x | 0.144 |
| TREND_X_VOL_Z_X_CHANGE | 9.66% | 18.81% | 0.583 | 0.906 | -15.90% | 0.608 | -2.441% | 51.61x | 0.308 |
| RAW_FORECAST_Z | -8.83% | 40.92% | -0.022 | -0.032 | -48.83% | -0.181 | -4.731% | 53.40x | 1.035 |
| EWMA_VOL_TARGET | -2.74% | 20.19% | -0.037 | -0.053 | -31.62% | -0.087 | -2.435% | 3.57x | 0.484 |
| BUY_HOLD | -13.15% | 43.92% | -0.101 | -0.144 | -52.97% | -0.248 | -5.185% | 0.65x | 1.000 |
| ERROR_ADJUSTED_VOL_TARGET | -4.02% | 20.19% | -0.102 | -0.146 | -29.73% | -0.135 | -2.406% | 29.49x | 0.515 |
| MODEL_VOL_TARGET | -4.58% | 18.80% | -0.156 | -0.221 | -28.86% | -0.159 | -2.243% | 23.76x | 0.479 |
| COMPRESSION_BREAKOUT | -2.03% | 9.73% | -0.163 | -0.239 | -12.31% | -0.165 | -1.253% | 6.49x | 0.101 |
| MODEL_MINUS_EWMA_Z | -14.80% | 40.40% | -0.195 | -0.275 | -49.90% | -0.297 | -4.795% | 59.01x | 0.990 |
| VOL_CHANGE_Z | -17.31% | 43.23% | -0.224 | -0.319 | -54.67% | -0.317 | -5.072% | 98.09x | 0.995 |
| MODEL_DISAGREEMENT | -14.60% | 37.50% | -0.234 | -0.334 | -47.23% | -0.309 | -4.513% | 56.07x | 0.844 |
| VOL_STATE_MACHINE | -15.23% | 35.66% | -0.286 | -0.403 | -44.80% | -0.340 | -4.388% | 106.62x | 0.885 |

## Interpretation

Three comparisons matter most.

### 1. Model volatility targeting vs corrected EWMA volatility targeting

`MODEL_VOL_TARGET` has lower realized volatility, but worse Sharpe and much higher turnover. Its Sharpe is **-0.156** versus **-0.037** for corrected `EWMA_VOL_TARGET`.

**Better QLIKE does not imply better portfolio sizing.**

### 2. Model-scaled trend vs corrected EWMA-scaled trend

`TREND_MODEL_VOL` has a Sharpe of **0.688** versus **0.749** for corrected `TREND_EWMA`.

Again, the sophisticated forecast does not beat the simpler backward-looking volatility estimate economically.

### 3. Trend x forecast-volatility z-score vs plain trend

`TREND_X_VOL_Z` has the best raw Sharpe at **0.787** versus **0.773** for `TREND`, but turnover rises from **21.43x** to **35.65x** per year and drawdown is slightly worse.

The apparent edge is fragile to costs: at **25 bp per unit turnover**, plain trend Sharpe is approximately **0.596**, versus **0.509** for the z-score overlay. That is not convincing evidence of incremental alpha.

## Common-volatility diagnostic

Scaling all strategies ex post to 20% annualized volatility leaves the broad ranking unchanged. Selected corrected results:

| Strategy | Scale | CAGR | Ann. vol | Sharpe | Max drawdown |
|---|---:|---:|---:|---:|---:|
| TREND_X_VOL_Z | 1.044 | 14.75% | 20.0% | **0.787** | -15.71% |
| TREND | 1.113 | 14.42% | 20.0% | 0.773 | -16.29% |
| TREND_EWMA | 1.885 | 13.87% | 20.0% | 0.749 | -16.48% |
| TREND_MODEL_VOL | 2.222 | 12.50% | 20.0% | 0.688 | -17.49% |
| EWMA_VOL_TARGET | 0.991 | -2.70% | 20.0% | -0.037 | -31.38% |

The ex-post scaling is a comparison device only; it is not a live strategy.

## Decision

The strategy search stops here.

> **The project found forecasting value and risk-management value, but no convincing incremental spot-BTC trading alpha from the volatility model.**

Further tuning on this same sample would mostly increase data-mining risk.
