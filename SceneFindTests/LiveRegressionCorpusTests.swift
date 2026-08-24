import XCTest

final class LiveRegressionCorpusTests: XCTestCase {
    func testCrossPlatform75ClipCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCENEFIND_RUN_75_CLIP_CORPUS"] == "1" else {
            throw XCTSkip("Set SCENEFIND_RUN_75_CLIP_CORPUS=1 to run the 75-clip TikTok/Instagram audit.")
        }

        let mode = environment["SCENEFIND_75_CLIP_MODE"] ?? "full"
        let requestedIndexes = Set(
            (environment["SCENEFIND_75_CLIP_INDEXES"] ?? "")
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        )
        let selected = crossPlatform75ClipCorpus.enumerated().filter { index, _ in
            requestedIndexes.isEmpty || requestedIndexes.contains(index + 1)
        }
        XCTAssertFalse(selected.isEmpty)

        let metadataService = OEmbedSocialClipMetadataService()
        let identificationService = HybridClipIdentificationService()
        let destinationResolver = StreamingDestinationResolver()
        var retrieved = 0
        var identified = 0
        var correctlyClassified = 0
        var expectedTitleMatches = 0
        var expectedTitleChecks = 0
        var expectedEpisodeMatches = 0
        var expectedEpisodeChecks = 0
        var timestamped = 0
        var exactDestinations = 0
        var seekableDestinations = 0

        for (index, item) in selected {
            let started = Date()
            let url = try XCTUnwrap(URL(string: item.url))
            let request = SharedClipRequest(
                sourceType: .url,
                sourcePlatform: item.platform,
                originalURL: url,
                pageTitle: "75-clip \(item.category) regression"
            )
            var record: [String: Any] = [
                "index": index + 1,
                "category": item.category,
                "platform": item.platform.rawValue,
                "url": item.url,
            ]

            do {
                let metadata = try await metadataService.metadata(for: url)
                retrieved += 1
                record["retrieved"] = true
                record["hasCaption"] = metadata.caption?.isEmpty == false
                record["hasTranscript"] = metadata.transcript?.isEmpty == false
                record["transcriptWords"] = metadata.transcript?.wordCount ?? 0
                record["hasVideo"] = metadata.videoURL != nil
                record["hasPreview"] = metadata.thumbnailURL != nil
                record["durationSeconds"] = metadata.clipDurationSeconds ?? NSNull()
            } catch {
                record["retrieved"] = false
                record["retrievalError"] = conciseError(error)
            }

            if mode == "full" {
                do {
                    let result = try await identificationService.identify(request: request)
                    let candidate = result.topCandidate
                    identified += 1
                    record["identified"] = true
                    record["detectedTitle"] = candidate.mediaTitle
                    record["detectedType"] = candidate.mediaType.rawValue
                    record["detectedSeason"] = candidate.seasonNumber ?? NSNull()
                    record["detectedEpisode"] = candidate.episodeNumber ?? NSNull()
                    record["confidence"] = rounded(candidate.confidence)
                    record["timestampAccuracy"] = candidate.timestampAccuracy?.rawValue ?? NSNull()
                    let endTimestamp = candidate.clipEndTimestampSeconds ?? candidate.sceneTimestampSeconds
                    record["endTimestampSeconds"] = endTimestamp.map(rounded) ?? NSNull()
                    if endTimestamp != nil { timestamped += 1 }

                    let classificationMatch = item.expectedMediaType == candidate.mediaType
                    record["classificationMatch"] = classificationMatch
                    if classificationMatch { correctlyClassified += 1 }

                    if let expectedTitle = item.expectedTitle {
                        expectedTitleChecks += 1
                        let matches = normalizedTitle(candidate.mediaTitle).contains(normalizedTitle(expectedTitle))
                            || normalizedTitle(expectedTitle).contains(normalizedTitle(candidate.mediaTitle))
                        record["expectedTitle"] = expectedTitle
                        record["titleMatch"] = matches
                        if matches { expectedTitleMatches += 1 }
                    }

                    if let expectedSeason = item.expectedSeason,
                       let expectedEpisode = item.expectedEpisode {
                        expectedEpisodeChecks += 1
                        let matches = candidate.seasonNumber == expectedSeason
                            && candidate.episodeNumber == expectedEpisode
                        record["expectedSeason"] = expectedSeason
                        record["expectedEpisode"] = expectedEpisode
                        record["episodeMatch"] = matches
                        if matches { expectedEpisodeMatches += 1 }
                    }

                    if let provider = candidate.watchProviders?.first,
                       let destination = await destinationResolver.destination(
                           for: provider,
                           candidate: candidate
                       ) {
                        record["destinationProvider"] = provider.name
                        record["destinationLevel"] = destination.level.rawValue
                        record["destinationURL"] = destination.primaryURL.absoluteString
                        let exact = destination.level == .exactEpisode
                        let seekable = endTimestamp != nil
                            && WatchDestinationPolicy.supportsTimestamp(destination.primaryURL)
                        record["exactDestination"] = exact
                        record["seekableDestination"] = seekable
                        if exact { exactDestinations += 1 }
                        if seekable { seekableDestinations += 1 }
                    } else {
                        record["destinationLevel"] = NSNull()
                        record["exactDestination"] = false
                        record["seekableDestination"] = false
                    }
                } catch {
                    record["identified"] = false
                    record["identificationError"] = conciseError(error)
                }
            }

            record["elapsedSeconds"] = rounded(Date().timeIntervalSince(started))
            printJSON(["CORPUS_RESULT": record])
        }

        let denominator = selected.count
        let summary: [String: Any] = [
            "mode": mode,
            "clips": denominator,
            "retrieved": retrieved,
            "retrievalRate": rounded(Double(retrieved) / Double(denominator)),
            "identified": identified,
            "identificationRate": rounded(Double(identified) / Double(denominator)),
            "correctlyClassified": correctlyClassified,
            "classificationRate": rounded(Double(correctlyClassified) / Double(denominator)),
            "expectedTitleMatches": expectedTitleMatches,
            "expectedTitleChecks": expectedTitleChecks,
            "expectedEpisodeMatches": expectedEpisodeMatches,
            "expectedEpisodeChecks": expectedEpisodeChecks,
            "timestamped": timestamped,
            "timestampRate": rounded(Double(timestamped) / Double(denominator)),
            "exactDestinations": exactDestinations,
            "exactDestinationRate": rounded(Double(exactDestinations) / Double(denominator)),
            "seekableDestinations": seekableDestinations,
            "seekableDestinationRate": rounded(Double(seekableDestinations) / Double(denominator)),
        ]
        printJSON(["CORPUS_SUMMARY": summary])
    }

    func testPublicClipRegressionCorpus() async throws {
        guard ProcessInfo.processInfo.environment["SCENEFIND_RUN_LIVE_CORPUS"] == "1" else {
            throw XCTSkip("Set SCENEFIND_RUN_LIVE_CORPUS=1 to run paid/free-tier API regression calls.")
        }
        guard GeminiConfiguration.isConfigured else {
            throw XCTSkip("The local Debug Gemini key is not configured.")
        }

        // The first three are the clips the evidence-first pipeline was built
        // against, one per platform, and each exercises a different path:
        //   Instagram — the answer is in the Reel's og:description caption
        //               ("Ant-Man (2015)"), with no fetchable video at all.
        //   TikTok    — the caption is just "#fyp"; the identification comes
        //               from TikTok's free ASR caption track, which also gives
        //               the dialogue that locates the scene in the runtime.
        //   YouTube   — oEmbed answers 401 for this video because embedding is
        //               disabled, so the title and episode have to come from the
        //               watch page's own description.
        let urls = [
            "https://www.instagram.com/reel/DUnCvbnif6s/",
            "https://www.tiktok.com/t/ZTAY2LwFE/",
            "https://youtube.com/shorts/N4UpQBoE9Ak",
            "https://youtube.com/shorts/0SRUWOzWw8I",
            "https://www.tiktok.com/t/ZTSKqS1Mb/",
            "https://www.tiktok.com/t/ZTSKqKK8W/",
            "https://www.tiktok.com/t/ZTA1C7M9n/",
            "https://www.tiktok.com/t/ZTA1V97nG/",
            "https://www.tiktok.com/@mtyfvaqmyg8/video/7654576063070162207"
        ]
        let service = HybridClipIdentificationService()

        for rawURL in urls {
            let url = try XCTUnwrap(URL(string: rawURL))
            let started = Date()
            do {
                let result = try await service.identify(request: SharedClipRequest(
                    sourceType: .url,
                    sourcePlatform: SharedPlatform.detect(url: url),
                    originalURL: url,
                    pageTitle: "Live regression clip"
                ))
                let candidate = result.topCandidate
                let timestamp = candidate.sceneTimestampSeconds
                    .map { "\($0.timestampString) (\(candidate.timestampAccuracy?.label ?? "unlabelled"))" }
                    ?? "no timestamp"
                print(
                    "LIVE_RESULT | \(url.host() ?? "unknown") | \(candidate.mediaTitle) | "
                    + "\(candidate.episodeLine) | \(timestamp) | "
                    + "\(String(format: "%.1f", Date().timeIntervalSince(started)))s"
                )
            } catch {
                print(
                    "LIVE_RESULT | \(url.host() ?? "unknown") | ERROR | "
                    + "\(type(of: error)) | \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
                )
            }
        }
    }
}

private struct CrossPlatformCorpusItem {
    let category: String
    let platform: SharedPlatform
    let url: String
    let expectedMediaType: MediaType
    let expectedTitle: String?
    let expectedSeason: Int?
    let expectedEpisode: Int?

    init(
        _ category: String,
        _ platform: SharedPlatform,
        _ url: String,
        _ expectedMediaType: MediaType,
        title: String? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) {
        self.category = category
        self.platform = platform
        self.url = url
        self.expectedMediaType = expectedMediaType
        self.expectedTitle = title
        self.expectedSeason = season
        self.expectedEpisode = episode
    }
}

private let crossPlatform75ClipCorpus: [CrossPlatformCorpusItem] = [
    // Movies: 13 TikToks with caption-derived title labels, then 12 Instagram #movieclips results.
    .init("movie", .tiktok, "https://www.tiktok.com/@salvadorlerma/video/7609423841747684622", .movie, title: "I Am Sam"),
    .init("movie", .tiktok, "https://www.tiktok.com/@randommm.clipss/video/7291167856643935534", .movie, title: "Believe Me: The Abduction of Lisa McVey"),
    .init("movie", .tiktok, "https://www.tiktok.com/@movieclips/video/7668009517312986382", .movie, title: "Spider-Man: No Way Home"),
    .init("movie", .tiktok, "https://www.tiktok.com/@deenk54/video/7301881307280280875", .movie, title: "Serendipity"),
    .init("movie", .tiktok, "https://www.tiktok.com/@movieclips/video/7668011828550667533", .movie, title: "Spider-Man: No Way Home"),
    .init("movie", .tiktok, "https://www.tiktok.com/@hxm54/video/7256891577187126574", .movie, title: "The Clique"),
    .init("movie", .tiktok, "https://www.tiktok.com/@movieclips/video/7665950674969988366", .movie, title: "Rambo: First Blood Part II"),
    .init("movie", .tiktok, "https://www.tiktok.com/@carparkmovies/video/7567803945897364758", .movie, title: "Desert Flower"),
    .init("movie", .tiktok, "https://www.tiktok.com/@mvdoanl/video/7594524142473415967", .movie, title: "Frequency"),
    .init("movie", .tiktok, "https://www.tiktok.com/@__moviesclips/video/7337032123280313642", .movie, title: "Pirates of the Caribbean"),
    .init("movie", .tiktok, "https://www.tiktok.com/@oippr4me/video/7595150640184036622", .movie, title: "Blades of Glory"),
    .init("movie", .tiktok, "https://www.tiktok.com/@johhny.movies/video/7256891639271050539", .movie, title: "The Blind Side"),
    .init("movie", .tiktok, "https://www.tiktok.com/@movieclips/video/7650168133856070925", .movie, title: "The Fast and the Furious"),
    .init("movie", .instagram, "https://www.instagram.com/p/DavHQ1ntBdf/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/B2CfvD1Ign3/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DTyquUWESic/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DalzUOSu6_i/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DW2KNyyie20/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DapCXQRhqW1/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DWhBiebEcBn/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DTlvuWlAZp2/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/Dbta8dGtm9m/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DVClcN6Ahl8/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DcFwqP3xl62/", .movie),
    .init("movie", .instagram, "https://www.instagram.com/p/DaZdPLTTY-O/", .movie),

    // Shows: 13 TikToks (including six caption-labelled episodes), then 12 Instagram #tvshowclips results.
    .init("show", .tiktok, "https://www.tiktok.com/@primetelevision888/video/7660500502450294030", .television, title: "Jessie", season: 1, episode: 5),
    .init("show", .tiktok, "https://www.tiktok.com/@tv.shows.movie.clip/video/7672927452393524493", .television, title: "Hangin' with Mr. Cooper", season: 1, episode: 2),
    .init("show", .tiktok, "https://www.tiktok.com/@liz_secret67/video/7671732028768881940", .television, title: "Dance Moms"),
    .init("show", .tiktok, "https://www.tiktok.com/@primetelevision888/video/7665587050594323725", .television, title: "Jessie", season: 4, episode: 1),
    .init("show", .tiktok, "https://www.tiktok.com/@primetelevision888/video/7670303506355555598", .television, title: "Jessie", season: 3, episode: 2),
    .init("show", .tiktok, "https://www.tiktok.com/@gog66ni/video/7672329840732785934", .television, title: "The Simpsons"),
    .init("show", .tiktok, "https://www.tiktok.com/@susana12g/video/7653707880159366413", .television, title: "From"),
    .init("show", .tiktok, "https://www.tiktok.com/@primetelevision888/video/7667058232807968014", .television, title: "Good Luck Charlie", season: 2, episode: 15),
    .init("show", .tiktok, "https://www.tiktok.com/@lee.i.thao/video/7669015789143362829", .television, title: "9-1-1"),
    .init("show", .tiktok, "https://www.tiktok.com/@voivi35/video/7644333858338475278", .television, title: "Desperate Housewives"),
    .init("show", .tiktok, "https://www.tiktok.com/@funniest_sitcoms/video/7664216630465006870", .television, title: "Modern Family"),
    .init("show", .tiktok, "https://www.tiktok.com/@primetelevision888/video/7670599842082606349", .television, title: "Wizards of Waverly Place", season: 4, episode: 16),
    .init("show", .tiktok, "https://www.tiktok.com/@dramaclubfox/video/7322948494770130219", .television, title: "9-1-1: Lone Star"),
    .init("show", .instagram, "https://www.instagram.com/p/Da4a0APsiyh/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DbsykmAT0Iu/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DZVUzatsP1V/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/Db792TexLAN/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DZNVQs3J1f8/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/Daxav6Hzbcy/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/Db8FcJxpSgZ/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DaxEWXOSQVc/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DZIpjUIh2rP/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DZTL3XaK9HZ/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/DaObH33zQ-3/", .television),
    .init("show", .instagram, "https://www.instagram.com/p/Da3RJ66MW6-/", .television),

    // Random creator/viral clips: 13 TikToks, then 12 Instagram #viralclips results.
    .init("random", .tiktok, "https://www.tiktok.com/@julian51957/video/7649822734649806110", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@theviralclips.01/video/7671379306186034462", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@dailymail/video/7671209465890327822", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@zynju2x/video/7673440978652515614", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@mebathefirst/video/7671243469716737302", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@jetfinds2/video/7666483970657324290", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@thenoemurillo/video/7670717441508429070", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@finds4feed/video/7657059756707826957", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@divinitypew/video/7668390700001643807", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@money.clipxz/video/7657748130435222814", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@prod.mir0/video/7673358980428729613", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@.jadenn_0/video/7649420335682522381", .other),
    .init("random", .tiktok, "https://www.tiktok.com/@thestarfamclips/video/7674744779791502605", .other),
    .init("random", .instagram, "https://www.instagram.com/p/Db1y31xEdUP/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DYcwJqQy8Y_/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DZWt8AxhUv0/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/Db0Xs_mTr7f/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DcBfUWMzgZe/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DakR3jeMdby/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DcD-30rRZeL/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DbDyIVKOHiS/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/DcB6M9MTWKq/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/BwGqa2nhMa8/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/Db8nbvQPwT1/", .other),
    .init("random", .instagram, "https://www.instagram.com/p/C6ry3E7uaU4/", .other),
]

private func normalizedTitle(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func conciseError(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}

private func rounded(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

private func printJSON(_ value: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}
