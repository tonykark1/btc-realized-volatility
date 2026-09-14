# LinkedIn carousel — 8 slides

## Slide 1 — Better forecasts. No convincing trading edge.

Forecasting Bitcoin realized volatility:
what held up in a walk-forward test?

A research result worth sharing — including what failed.

## Slide 2 — Two questions, two tests

Can five-minute data improve Bitcoin risk forecasts?

Does that improvement help a spot-BTC strategy after costs?

Predicting volatility is not predicting direction.

## Slide 3 — Keep the future out of training

Binance Spot BTCUSDT · five-minute data
1,460-day rolling training window
608 walk-forward OOS origins · 1 / 5 / 10 days
Purged targets · DM tests · 2,000 block-bootstrap replications

Primary loss: QLIKE. Lower is better.

## Slide 4 — The forecasting horse race

GARCH(1,1) · HAR-RV · HAR-J · HARQ · HARQ-F · Realized-GARCH · HEAVY-RM

Realized-GARCH: lowest raw QLIKE at all three horizons.
HARQ: second at all three horizons.

Raw ranking does not establish statistical dominance.

## Slide 5 — HARQ earns its place

QLIKE improvement versus HAR-RV:

1 day: 5.67%
5 days: 3.35%
10 days: 2.33%

Nominal pairwise DM and bootstrap tests support the QLIKE gains.
Quarticity helps account for noise in realized variance.

## Slide 6 — Now test the trading case

562 daily returns · same research episode
10 bp per unit turnover · not an independent holdout
Forecast ensemble: 50% HARQ variance + 50% Realized-GARCH variance

Standalone sizing Sharpe:
Model −0.156 | corrected EWMA −0.037

Trend sizing Sharpe:
Model 0.688 | corrected EWMA 0.749

## Slide 7 — A tiny gain with much more trading

Trend → trend × model-volatility z-score

Sharpe: 0.773 → 0.787
Annual turnover: 21.43x → 35.65x

No convincing incremental alpha on this short sample. At 25 bp costs, plain trend ranks higher.
CEEMDAN also failed to establish robust incremental forecasting value.

## Slide 8 — Keep both findings

HARQ and Realized-GARCH forecast risk well in this experiment.
Simple trading benchmarks remained hard to beat.

“Forecasting risk and monetizing that forecast are separate problems.”

Full report, code and saved results:
github.com/tonykark1/btc-realized-volatility/tree/main/report
