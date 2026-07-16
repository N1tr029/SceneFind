# SceneFind

SceneFind is a locally testable iPhone MVP for "Shazam for movie and TV clips." It accepts shared URLs, text, images, videos, and Photos imports, then routes verified catalog matches to the exact episode, scene time, and available watch providers. Unknown shared links use Gemini video understanding with a free-tier prototype API key.

## What is included

- Main SwiftUI iOS app target
- iOS Share Extension target
- App Group entitlements using `group.com.example.SceneFind`
- `scenefind://analyze?requestID=<uuid>` deep link handling
- TikTok/YouTube URL and caption capture from the Share Extension
- Public oEmbed metadata lookup for supported social links
- Gemini 3.5 Flash integration with direct public YouTube audio and video input
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

## Simulator test flow

1. Run the main app.
2. Tap **Demo Mode** cases for strong dialogue, weak visual, YouTube, TikTok, imported-video, no-match, and ambiguous flows.
3. Create a free Gemini API key in Google AI Studio. Open **Settings**, enter the key, leave the model as `gemini-3.5-flash`, and tap **Save**.
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

Streaming services generally do not publish timestamp deep links for TV episodes. SceneFind opens the selected episode and copies the verified continue point (`10:25` for the supplied clip) so the viewer can seek there.

## Reset local data

Use Settings inside the app to clear saved scenes. To fully reset simulator data, delete the app from the simulator or erase the simulator contents.

## Future integrations

Future production work can attach real implementations behind the existing protocols for clip retrieval, speech-to-text, web image search, media metadata, streaming availability, and remote scene matching.
