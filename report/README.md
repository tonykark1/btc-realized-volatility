# Public research-note bundle

This folder contains the nine-page public note for the finished BTC realized-volatility project. The forecasting experiment is frozen; the strategy section incorporates the corrected EWMA timing audit.

## Read or share

- [PDF report](btc_realized_volatility_report.pdf)
- [Self-contained HTML](btc_realized_volatility_report.html)
- [Editable Quarto source](btc_realized_volatility_report.qmd)
- [LinkedIn post](linkedin_post.md) and [eight-slide carousel text](linkedin_carousel.md)
- [Methodological references](references.md)

## Audit trail in GitHub

`source_data/` contains the compact evidence used in the public note: forecast metrics, original pairwise DM/bootstrap output, corrected strategy metrics, the full cost grid, EWMA timing diagnostics, daily-close inputs and cumulative-loss evidence. `research_code/` snapshots the forecasting and corrected strategy scripts, and `tests/test_ewma_timing.R` guards the timing fix.

The heavier per-origin forecast panel and full daily strategy path are retained in the archived local audit bundle rather than duplicated in this portfolio repository. Raw five-minute Binance cache files are also intentionally excluded.

## Correction and scope

The EWMA benchmark now uses observed `RV_t` when forming the forecast for `t+1`. No strategy parameter was retuned after the correction. At 10 bp per unit turnover, corrected Sharpe ratios include `-0.03696` for EWMA vol targeting and `0.74889` for trend + EWMA; the model-vol-z overlay's small apparent edge over plain trend reverses by 25 bp costs.

Forecast results are rolling walk-forward OOS errors, not an untouched preregistered holdout. Pairwise DM/bootstrap tests are nominal, pairwise and loss-specific. Realized-GARCH has the lowest raw QLIKE; the note does not claim statistical dominance over HARQ. The economic application reuses the same repeatedly examined market episode and is not a confirmatory alpha test.

The original forecasting run did not capture a dependency lockfile. `sessionInfo.txt` records the corrected strategy verification environment only; no retrospective forecasting environment is fabricated.
