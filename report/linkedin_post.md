Better Bitcoin volatility forecasts did not give me a convincing trading edge.
That negative result became the most useful part of the project.

I tested whether high-frequency realized measures could improve Bitcoin risk forecasts, then asked whether those improvements had economic value in spot-BTC trading.

The forecasting experiment used Binance BTCUSDT five-minute data, seven models, a 1,460-day rolling window and 608 walk-forward out-of-sample forecast origins across 1-, 5- and 10-day horizons.

Two findings stood out:

• Realized-GARCH had the lowest raw QLIKE at every horizon.
• HARQ reduced QLIKE versus HAR-RV by 5.67%, 3.35% and 2.33%, with support from nominal pairwise DM and loss-differential bootstrap tests.

Those are different claims: the raw ranking does not establish that Realized-GARCH statistically dominates HARQ.

The research also involved abandoning an initial CEEMDAN approach when leakage-safe controls failed to establish robust incremental value.

I then applied the forecasts to 562 daily returns from the same research episode, charging 10 basis points per unit turnover. This was not an independent holdout.

Model-based volatility sizing trailed the corrected simple EWMA benchmark on Sharpe. A model-volatility z-score overlay nudged trend Sharpe from 0.773 to 0.787, but annual turnover jumped from 21.43x to 35.65x.

That is a small descriptive improvement on a short, repeatedly examined sample. At 25 bp per unit turnover, the ranking reverses. I do not interpret it as evidence of alpha.

The lesson: forecasting risk and monetizing that forecast are separate problems.

The report includes the negative results, methodology and source trail. Code and saved results on GitHub:
https://github.com/tonykark1/btc-realized-volatility/tree/main/report

#QuantitativeResearch #ModelValidation #FinancialEconometrics
