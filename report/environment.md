# Environment provenance

`sessionInfo.txt` records the actual R 4.6.1 strategy verification on 2026-09-14. The six strategy packages were installed into an isolated workspace library.

The original forecasting run has no recoverable package lock or session record. Its historical `rugarch` version is unknown. These current versions must not be represented as the original forecasting environment. Forecasts are preserved as saved evidence; the correction does not refit forecasting models.
