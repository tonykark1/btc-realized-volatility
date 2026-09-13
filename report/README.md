# Report bundle

This folder contains the public research note for the finished BTC realized-volatility project.

## Main files

- `btc_realized_volatility_report.pdf` — 8-page public research note.
- `btc_realized_volatility_report.html` — browser version; keep the `figures/` folder beside it.
- `btc_realized_volatility_report.qmd` — static report source. It does not rerun or refit the research models.
- `linkedin_post.md` — concise post copy.
- `linkedin_carousel.md` — text for an 8-slide carousel.
- `source_data/` — compact saved evidence used to audit the published tables and figures. Large generated panels and raw market data are intentionally not committed.
- `source_manifest.json` — SHA-256 manifest and provenance.
- `validation.md` / `validate_report.py` — consistency checks.

## Research snapshot

The report is tied to repository research snapshot `e3fe98639e63a58883b8376e58d1e26c8b07e34e`. The later report commit only adds these publication artifacts.

## Correction recorded

The strategy-lab EWMA benchmark was corrected so that the `t+1` forecast formed at origin `t` incorporates observed `RV_t`. No strategy parameter was retuned after the correction. The corrected values appear in the report and `source_data/strategy_metrics_*.csv`.

## Scope

Forecast results are walk-forward OOS errors, not an untouched preregistered holdout after the complete research process. Pairwise DM/bootstrap tests are reported as pairwise, loss-specific inference; no global model-selection claim is made. The trading exercise is an economic application on the same repeatedly examined period, not a confirmatory alpha test.
