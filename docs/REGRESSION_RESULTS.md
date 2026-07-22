# Live Regression Results

Run on July 21, 2026 with the `SceneFindLiveRegression` scheme against the six public clips in `LiveRegressionCorpusTests.swift`. This exercises real social-page retrieval and configured model APIs; it is separate from deterministic unit tests.

| Clip | Returned result | Episode state | Elapsed |
|---|---|---|---:|
| YouTube `0SRUWOzWw8I` | The Rookie | S3 E10 | 11.8s |
| TikTok `ZTSKqS1Mb` | The Middle | Show-level only | 24.7s |
| TikTok `ZTSKqKK8W` | All American | Show-level only | 34.8s |
| TikTok `ZTA1C7M9n` | The Goldbergs | S2 E2 | 20.3s |
| TikTok `ZTA1V97nG` | No result | TikTok status 10204; oEmbed HTTP 400 | 0.7s |
| TikTok `7654576063070162207` | Malcolm in the Middle | Show-level only | 31.9s |

## Summary

- Show-or-better return rate: 5/6 (83.3%), compared with the reported prototype experience of about 30%.
- Successful-result median and mean: 24.7 seconds.
- Successful results under 30 seconds: 3/5.
- Exact episode fields were returned for 2/6 clips. This is not an accuracy score: the corpus does not yet contain independently verified ground-truth episode labels.
- The failed TikTok clip currently exposes no usable video, caption, or thumbnail to an unsigned web client. SceneFind fails honestly instead of ranking metadata-only guesses.

These numbers are a snapshot of external services and can vary with model load, social-platform responses, region, and cache state. Re-run the opt-in live scheme before a release candidate; normal unit tests never spend API quota.
