# Public research-note bundle

This folder contains the public note and the compact evidence needed to audit its headline claims.

## Read or share

- [Research note](research_note.md)
- [LinkedIn post](linkedin_post.md)
- [Eight-slide carousel text](linkedin_carousel.md)
- [Methodological references](references.md)

## Audit trail

`source_data/` contains the forecast metrics, pairwise DM/bootstrap output, corrected strategy metrics and transaction-cost sensitivity used by the note. The root `R/` directory contains a compact audit implementation: realized-measure construction, HAR/HARQ/HEAVY core logic, inference, the corrected strategy mechanics and a one-command result check. `tests/test_ewma_timing.R` guards the EWMA correction.

The full production implementation is preserved on the `research-archive-v1` branch. It includes the Binance downloader/cache plumbing, Realized-GARCH/GARCH package integration, exploratory models and the full visualization suite. Those are intentionally not duplicated on portfolio-facing `main`.

## Correction and scope

The EWMA benchmark uses observed `RV_t` when forming the forecast for `t+1`. No strategy parameter was retuned after the correction. At 10 bp per unit turnover, corrected Sharpe ratios include `-0.03696` for EWMA vol targeting and `0.74889` for trend + EWMA; the model-vol-z overlay's small apparent edge over plain trend reverses by 25 bp costs.

Forecast results are rolling walk-forward OOS errors, not an untouched preregistered holdout. Pairwise DM/bootstrap tests are nominal, pairwise and loss-specific. Realized-GARCH has the lowest raw QLIKE; the note does not claim statistical dominance over HARQ. The economic application reuses the same repeatedly examined market episode and is not a confirmatory alpha test.

The original forecasting run did not capture a dependency lockfile. `sessionInfo.txt` records the corrected strategy verification environment only; no retrospective forecasting environment is fabricated.