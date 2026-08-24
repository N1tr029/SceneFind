# Historical Live Regression Results (Not a Release Gate)

Run on July 21, 2026 with the old Debug direct-provider pipeline and the six
public clips in `LiveRegressionCorpusTests.swift`. It predates the production
backend and is retained only as historical context.

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

## 2026-08-19 release audit

The requested signed-in corpus of 50 distinct Instagram clips was not completed
in this audit. No connected signed-in Instagram browser session, deployed
production backend, or independently verified show/season/episode ground-truth
set was available. Consequently, the table above must not be used to claim
production accuracy, Instagram reliability, or compliance with the current
release gate.

## 2026-08-19 TikTok timeline alignment audit

A separate 34-clip movie corpus was collected from the signed-in TikTok search
results for `movie clips`. The corpus is fixed in
`backend/scripts/run-tiktok-regression.ts`. TikTok's public caption supplies the
candidate movie label; the test then requires an independent timed-dialogue
index to return the same movie and either:

- at least two dialogue anchors whose calculated timeline offsets agree within
  four seconds; or
- one at-least-90%-similar anchor ending within eight seconds of the TikTok
  clip's end.

The compliant run, using TikTok's timed WebVTT and the public QuoDB endpoint,
passed 10 of 34 clips (29%). Median processing time was 1.35 seconds and p95 was
2.31 seconds. Two clips had no timed TikTok captions. The other failures did
not have enough independently indexed dialogue to support an exact end
timestamp. Public ClipCafe page scraping was explicitly excluded after its
access controls rejected automated requests; its documented API requires a PRO
key and does not expose the canonical in-movie timestamp in its published
response schema.

This is a timestamp-alignment score, not a title-identification score. It does
not test television season/episode identification, provider-edition drift, or
whether a streaming app accepts timestamped deep links. The requested 80% gate
is therefore **not met**, and exact timestamp opening must remain fail-closed.

## 2026-08-19 TikTok episode alignment audit

The follow-up episode-only corpus contains 30 distinct public TikTok videos
across *The Office*, *Friends*, *How I Met Your Mother*, *The Big Bang Theory*,
and *Game of Thrones*. It is fixed in
`backend/scripts/run-tiktok-episode-regression.ts`. Candidates came from the
signed-in TikTok searches for season/episode clips and were restricted to
videos that exposed usable English timed captions. This is a purpose-built
supported-input regression set, not a random sample of all TikTok videos.

Each pass requires all of the following:

- QuoDB dialogue matches the expected show and identifies an episode title.
- TVMaze independently maps that title to the expected season and episode.
- At least two dialogue anchors agree within four seconds and cover the clip
  ending within 20 seconds, or one at-least-90%-similar anchor ends within
  eight seconds of the clip ending. With three or more anchors, the final
  anchor must also agree with the earlier held-out alignment within four
  seconds.
- The reported clip-end timestamp uses the median offset of the three latest
  anchors plus the TikTok duration. Integer-only TikTok durations receive a
  0.5-second midpoint correction because eight signed-in player checks showed
  an average 0.48-second truncation and a 1.10-second worst case.

The final moment-focused run passed **26 of 30 clips (86.7%)**. Median
processing time was **5.70 seconds** and p95 was **8.35 seconds**. Among the 21
accepted clips with at least three independent anchors, **20/21 predicted the
held-out final anchor within two seconds and 21/21 within four seconds**. Median
held-out endpoint error was **0.74 seconds** and p95 was **1.85 seconds**.

The stricter endpoint rules intentionally reject more clips than the earlier
episode-only alignment: two lacked dialogue close enough to the corrected
ending, one had a 4.33-second end discontinuity, and one remained unresolved.
One uploader's Office episode number was also wrong; independent dialogue
identified “Cocktails,” and TVMaze corrected the ground truth to S3 E18 before
the corpus was frozen.

This clears the requested 80% gate for the supported episode-clip corpus. It
does not prove population-wide TikTok accuracy, compensate for streaming
edition timing drift, or prove that every provider accepts a timestamped deep
link. Unsupported/missing-caption clips still return no exact timestamp, and
provider handoff needs physical-device validation against each installed
streaming app.

## 2026-08-19 signed-in TikTok + Instagram 75-clip audit

This audit used 75 fresh clips collected from the signed-in platform searches:
25 movie clips, 25 show clips, and 25 random creator/viral clips. Each category
contains 13 TikToks and 12 Instagram posts/Reels. The fixed corpus and structured
runner are in `LiveRegressionCorpusTests.swift`; the independent TikTok moment
audit is in `backend/scripts/run-cross-platform-75-timestamps.ts`.

### Source retrieval

| Category/platform | Clips | Retrieved | Caption | Timed transcript | Direct video | Preview |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Movie / TikTok | 13 | 13 | 13 | 12 | 13 | 13 |
| Movie / Instagram | 12 | 11 | 11 | 0 | 0 | 11 |
| Show / TikTok | 13 | 13 | 13 | 13 | 13 | 13 |
| Show / Instagram | 12 | 12 | 12 | 0 | 0 | 12 |
| Random / TikTok | 13 | 13 | 13 | 9 | 13 | 13 |
| Random / Instagram | 12 | 12 | 12 | 0 | 0 | 12 |
| **Total** | **75** | **74** | **74** | **34** | **39** | **74** |

Retrieval succeeded for 74/75 clips (98.7%). TikTok supplied a direct video for
39/39 and timed dialogue for 34/39. Instagram supplied caption/preview evidence
for 35/36, but no direct Reel video or timed transcript. The one unavailable
Instagram movie post returned the app's `Video unavailable` state; the simulator
confirmed that SceneFind stopped instead of guessing from the caption.

### Identification and opening

The first full case completed before the configured Gemini free-tier ceiling was
reached: SceneFind identified *I Am Sam* correctly, classified it as a movie, and
resolved an exact Apple TV movie page. It did not return an end timestamp, and
Apple TV cannot seek through a URL timestamp. The next four cases all returned
the explicit provider-quota error. The remaining 70 model-dependent cases were
not mislabeled as accuracy failures; they were not run after the external quota
blocked the same operation repeatedly. This run therefore does **not** establish
a 75-clip identification accuracy rate.

### Independent TikTok moment alignment

The 26 movie/show TikToks were also tested without the model, using their timed
TikTok dialogue against the independent dialogue and episode indexes:

- Movies: 0/13 produced a defensible end timestamp. One lacked timed captions;
  the other 12 had no independently indexed timeline match.
- Shows: 2/13 (15.4%) produced a defensible title/episode/timeline match.
- *Good Luck Charlie* S2 E15 resolved to “Bye Bye Video Diary,” ending at
  22:38.73, with six anchors and 3.77 seconds held-out endpoint error.
- *Modern Family* S1 E3 resolved to “Come Fly with Me,” ending at 20:54.74,
  with four anchors and 1.62 seconds held-out endpoint error.
- Of the six show clips whose captions supplied independent season/episode
  ground truth, 1/6 matched the exact episode.

The fresh-corpus moment result is far below the earlier 86.7% result from the
purpose-built, caption-supported episode corpus. TikTok retrieval is strong, but
exact moment support does not generalize to arbitrary movies/shows when the
independent subtitle index lacks the needed title or episode. Instagram exact
moment support remains unavailable because the app receives neither the Reel
video nor timed dialogue. Exact timestamp opening must remain fail-closed.

## 2026-08-19 layered episode-evidence rerun

The fixed 30-clip TikTok episode corpus was rerun after replacing the
single-index episode lookup with the production layered resolver. The show title
was treated as the output of the preceding identification stage; the season and
episode labels were used only after each result to score it. The resolver used:

- up to three distinctive TikTok transcript anchors searched independently;
- indexed transcript result titles/snippets mapped back to the canonical TVMaze
  episode guide;
- guide-summary overlap with transcribed dialogue and Gemini visual
  observations;
- season/episode text from a social caption only as an untrusted candidate; and
- timed multi-anchor QuoDB evidence as the highest-precedence result when an
  untimed web result disagreed.

An episode passed only when it existed in the canonical guide and had either
independent indexed dialogue support or multiple concrete guide/clip facts. A
caption or preliminary model guess alone could not pass.

The blind run passed **27/30 clips (90.0%)**. Twenty-six episodes were resolved
by timed dialogue alignment and one additional *Friends* S6 E22 clip, which had
no QuoDB result, was recovered through independently indexed transcript
evidence. Three clips remained unverified. The resolver rejected several
conflicting untimed web candidates rather than overriding stronger timed
dialogue. Median end-to-end resolver time was **15.48 seconds** and p95 was
**36.80 seconds**. Held-out endpoint quality was unchanged: 20/21 within two
seconds, 21/21 within four seconds, 0.74-second median error, and 1.85-second p95
error.

This meets the requested 90% exact-episode gate on the fixed supported-input
corpus. It is not a claim of 90% population-wide TikTok/Instagram accuracy:
arbitrary clips without usable speech, independently indexed dialogue, or
retrievable video still fail closed.

## 2026-08-19 provider-independent corrective rerun

The three unverified cases above were investigated against their raw source
evidence instead of being accepted as expected-label misses:

- *How I Met Your Mother* S4 E2 exposed TikTok captions as JSON `utterances`,
  not WebVTT. The caption parser had silently produced zero timed cues.
- *Friends* S5 E16 and *How I Met Your Mother* S5 E18 had matching dialogue on
  episode-specific transcript pages, but the resolver searched only result
  titles/snippets and did not fetch those pages.

The production resolver now parses both TikTok caption formats and, when a
caption/model coordinate maps to a real TVMaze entry, verifies social-clip
dialogue inside search-discovered transcript pages. Candidate metadata chooses
which canonical episode to investigate but is not itself proof. HTTP links in
old search indexes are upgraded to HTTPS; non-public hosts, unsafe redirects,
non-text responses, oversized pages, and weak dialogue matches are rejected.
Deterministic proof returns before the optional Groq tie-breaker.

The complete fixed corpus was then rerun with `GROQ_API_KEY` explicitly unset.
It passed **30/30 clips (100%)**. Median resolver time was **6.52 seconds** and
p95 was **25.11 seconds**. Held-out endpoint quality remained **20/21 within two
seconds and 21/21 within four seconds**, with **0.74-second median** and
**1.85-second p95** error. This proves the 90% supported-corpus episode gate no
longer depends on Groq availability; the population-wide limitations above
still apply.
