# Public-bundle validation

- The corrected EWMA timing is guarded by `tests/test_ewma_timing.R`.
- Corrected 10 bp Sharpe ratios in the committed aggregate tables are: EWMA vol target `-0.03696`, trend + EWMA `0.74889`, model vol target `-0.15583`, trend + model vol `0.68824`, plain trend `0.77281`, and trend x model-vol z `0.78704`.
- The complete transaction-cost grid shows the trend-z overlay ranking reverses at 25 bp: plain trend Sharpe about `0.59574` versus about `0.50935` for the overlay.
- Forecasting metrics and original pairwise inference are unchanged. No strategy parameter was retuned for publication.
- The public GitHub bundle intentionally omits heavyweight per-origin forecast and full daily strategy panels; those remain in the archived local audit bundle.
