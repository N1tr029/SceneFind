# SceneFind

SceneFind is a locally testable iPhone MVP for "Shazam for movie and TV clips." It accepts shared URLs, text, images, videos, and Photos imports, then routes verified catalog matches to the exact episode, scene time, and available watch providers. Unknown shared links use Gemini video understanding with a free-tier prototype API key.

## What is included

- Main SwiftUI iOS app target
- iOS Share Extension target
- App Group entitlements using `group.com.kavigandham.scenefind`
- `scenefind://analyze?requestID=<uuid>` deep link handling
- TikTok/YouTube URL and caption capture from the Share Extension
- Public evidence lookup per platform: the YouTube watch page's title and full
  description, TikTok's page data plus its free ASR caption track, and the
  Instagram Reel's `og:description` caption
- Two-stage identification: a text-only pass over the caption and transcript
  first, escalating to Gemini video analysis only when the text cannot support a
  match or cannot locate the scene
- Scene timestamps matched against a real subtitle index where possible, and
  bounded by the title's real runtime otherwise, with each result labelled
  "Matched to dialogue" or "Estimated"
- Gemini 3.6 Flash integration with direct public YouTube audio and video input
- Keychain-backed Gemini API key and configurable model in Settings, with Debug-only local storage for unsigned simulator builds
- Verified match for the supplied `QD4bDD7L66M` Short: *Modern Family*, S4 E4, around 10:06
- Where-to-watch provider rows and a start/continue-after-clip chooser
- PhotosPicker video import
- AVFoundation thumbnail/frame extraction
- Vision-ready architecture through separated visual matching services
- Codable JSON storage with FileManager in the App Group container
- Mock media dataset with 8 TV shows, 7 movies, episodes, and subtitles
- Subtitle matching engine with normalization, stop-word removal, token overlap, phrase scoring, and edit similarity
- Async mock analysis stages
- Unit tests for matching and pipeline behavior

## Generate and run

```sh
xcodegen generate
open SceneFind.xcodeproj
```

In Xcode, select the `SceneFind` scheme and an iPhone Simulator, then run.

For command-line verification:

```sh
xcodebuild -project SceneFind.xcodeproj -scheme SceneFind -destination 'platform=iOS Simulator,name=iPhone 15' build
xcodebuild -project SceneFind.xcodeproj -scheme SceneFind -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Use a different simulator name if needed.

## TestFlight deployment

Xcode Cloud builds `main` with the `TestFlight` workflow and distributes successful archives to the internal testing group.

## Simulator test flow

1. Run the main app.
2. Tap **Demo Mode** cases for strong dialogue, weak visual, YouTube, TikTok, imported-video, no-match, and ambiguous flows.
3. Create a free Gemini API key in Google AI Studio. Open **Settings**, enter the key, leave the model as `gemini-3.6-flash`, and tap **Save**.
4. Tap **Paste a link** and use `https://www.youtube.com/shorts/QD4bDD7L66M` to exercise the verified result flow without an API call, or paste another public YouTube clip to exercise Gemini video understanding and structured identification.
5. Tap **Choose a video** to import a video from Photos if your simulator has one.
6. Test the share extension from Safari by opening any page, using Share, enabling SceneFind under Edit Actions if needed, and choosing SceneFind.
7. Tap **Find in SceneFind**. If iOS does not permit the Share Extension to launch its containing app, close the share sheet and open SceneFind; it automatically consumes the pending request and starts analysis.
8. On the result screen, choose a provider and select **Start from the beginning** or **Continue after this clip**.

## Physical iPhone notes

- Xcode may require a personal Apple ID team for signing.
- Use the same Team for the app and share extension targets.
- Keep the App Group identifier synchronized in:
  - `Shared/AppGroupConfiguration.swift`
  - `SceneFindApp/SceneFind.entitlements`
  - `SceneFindShareExtension/SceneFindShareExtension.entitlements`
- Free personal-team signing can run the app locally, but App Group capability availability depends on your Apple account configuration.
- If prompted, trust the developer profile in iOS Settings.
- Enable SceneFind in the iOS share sheet from Safari, Photos, TikTok, YouTube, or another source app.

## Privacy

The app does not scrape restricted media, bypass DRM, or access social accounts. For shared links it may request public oEmbed metadata and send the URL, caption, title, and author to Gemini. Public YouTube links are supplied directly to Gemini as video input; TikTok and other platforms currently use available public metadata and Gemini's model knowledge, so uncatalogued matches should be treated as prototype suggestions rather than independently verified results. Properly signed builds store the prototype key in iOS Keychain. Unsigned Debug simulator builds fall back to local app preferences because they may not have the Keychain entitlement; this fallback is not compiled into Release builds. Verified catalog entries, including the supplied *Modern Family* example, do not make an API call.

## Watch destinations

SceneFind does not let the model invent provider URLs — a guessed content id
opens to "not found". Instead it finds the real page the way a search engine
does, then proves it.

Provider ids such as Apple TV's `umc.cmc.3151jcjocan3bys22epi0qeg6` or Peacock's
per-episode UUID cannot be derived from a title, but every provider publishes
crawlable episode pages, so those ids are sitting in public search results.
`EpisodeWatchLinkFinder` searches for the episode, collects any provider URLs,
then **fetches each one and checks the page's own `og:title` names the same show
and season/episode** before offering it. A link is therefore only ever shown when
the provider's own page confirms it. Verified for *The Middle* S5E8 on
2026-07-24, which yielded working Apple TV and HBO Max episode URLs.

Reading search results without a key is unreliable — DuckDuckGo's HTML endpoint
answered one request with `200` and the next two with `202`. Set a search API key
to make this dependable: **Settings → Recognition → API settings → Watch-link
search**, or `SearchAPIKey` in `PrototypeSecrets.plist`, or the `SEARCH_API_KEY`
secret in Xcode Cloud. Either a SerpApi key (64 hex characters) or a Brave Search
key (`BSA…`) works — the app tells them apart by shape. Without a key SceneFind
falls back to the keyless attempt, then the show's publisher-declared page from
TVmaze, then the service's own search page.

Results are cached to disk in the App Group container, keyed by
title/season/episode, misses included. That is not an optimisation: SerpApi's free
plan allows 250 searches a month and an episode's page URL never changes, so a
lookup should be paid for once rather than once per launch. Foreign storefronts
(`/ca/`, `/au/`) are filtered out, since a regional catalogue will not play for a
US viewer.

Checked against the live services on 2026-07-24:

- **Hulu needs the `dl.hulu.com` host.** `www.hulu.com` is folding into Disney+
  and `302`s every path — including a valid episode UUID — to the Disney+ home
  page with the path discarded, so its episode pages can no longer be scraped or
  verified. `dl.hulu.com` still publishes an apple-app-site-association covering
  `/watch/*` for the Hulu app, and iOS matches a Universal Link against that file
  before any web request, so `dl.hulu.com/watch/<id>` still opens the app at the
  episode. Only the browser fallback ends up on Disney+.
- **`max.com` now redirects to `hbomax.com`.** Watch links belong on
  `play.hbomax.com`, which serves an AASA and opens the app; `www.hbomax.com`
  returns 404 for its AASA and will only ever open Safari.
- **Only YouTube and Netflix honour a timestamp in the URL** (`?t=90s` and
  `?t=<seconds>` on a `/watch/` path respectively). Disney+ strips an added `t`
  during canonicalisation, and Apple's `resumeTime` is a contract Apple imposes
  on its own channel partners rather than something `tv.apple.com` accepts. For
  every other service SceneFind opens the title and copies the timestamp so the
  viewer can seek there, instead of pretending the link will seek.

## Reset local data

Use Settings inside the app to clear saved scenes. To fully reset simulator data, delete the app from the simulator or erase the simulator contents.

## Future integrations

Future production work can attach real implementations behind the existing protocols for clip retrieval, speech-to-text, web image search, media metadata, streaming availability, and remote scene matching.
