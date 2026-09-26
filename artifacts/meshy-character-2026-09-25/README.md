# Meshy character validation — 2026-09-25

Web and native creation screenshots use mocked API responses to exercise actual
components, responsive states and saved-character selection. `*-result.json`
records two real Meshy API generation runs; these are independent of UI mocks.
Actual downloaded GLB/native models were loaded by the desktop Office engine,
verified as the selected asset, with 1.75 m normalized height.

Secrets are stored only in AWS Secrets Manager. No secret values are included.
