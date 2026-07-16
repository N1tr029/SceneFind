import Foundation

enum MockMediaLibrary {
    static let titles: [MediaTitle] = {
        let showData: [(String, String, String, [String])] = [
            ("Paper County", "A warm workplace comedy about a paper company trying to survive modern sales.", "StreamBox", ["That is not a meeting, it is a room full of panic.", "Scranton never looked so heroic from a copy machine.", "The quarterly numbers are hiding inside the birthday cake.", "If the paper jams again, we vote with our feet.", "I declared casual Friday on a Wednesday."]),
            ("Orbital Cafeteria", "A science crew keeps a diner open on a drifting space station.", "Galaxy+", ["The oxygen alarm is just the chef asking for attention.", "Nobody orders soup during a meteor shower.", "Mission control never mentioned the singing freezer.", "We are astronauts, not dishwashers with helmets.", "The stars look close enough to burn the toast."]),
            ("Harbor After Midnight", "A coastal mystery where every clue arrives with the tide.", "HarborMax", ["The lighthouse blinked twice before the phone rang.", "Every boat in this harbor has a secret name.", "Meet me where the fog forgets the shoreline.", "That tide chart is a confession in blue ink.", "Nobody leaves by ferry after midnight."]),
            ("Metro Medics", "A fast, humane hospital drama set under a commuter rail station.", "Pulse", ["The train delay bought us four minutes.", "You do not need a miracle, you need pressure on the wound.", "Tell radiology the elevator is our ambulance now.", "Her pulse is matching the platform clock.", "The city is loud, but this room is listening."]),
            ("Crown of Static", "A political thriller about pirate radio and a fractured monarchy.", "Regal", ["The crown speaks only when the signal breaks.", "Static is safer than a loyal court.", "Your Majesty, the antenna is pointed at the truth.", "Every broadcast has a traitor in the room.", "Turn the dial before they turn the guards."]),
            ("Desert Kin", "A family saga across a solar farm in the high desert.", "Sunset", ["The panels remember every storm we survived.", "You cannot inherit the desert, only borrow its heat.", "Dad buried the deed beneath turbine seven.", "At noon even our shadows negotiate.", "This land has been listening longer than we have."]),
            ("North Pier", "A quiet ensemble drama about a failing seaside arcade.", "CinemaNow", ["The last token still works if you believe in bad wiring.", "We close at nine, unless the ocean asks nicely.", "That prize bear has watched three owners give up.", "You fixed the skee ball machine and broke my alibi.", "The pier creaks when it knows you are lying."]),
            ("The Long Classroom", "A hopeful school dramedy following one class over ten years.", "Learn+", ["Attendance is not the same as being seen.", "Put the answer down, then tell me why it scares you.", "This chalk line is the border of your old excuse.", "Nobody graduates from kindness by accident.", "The bell is loud because endings are hard."])
        ]

        let movieData: [(String, String, String, [String])] = [
            ("Axiom Sunrise", "A grounded sci-fi rescue mission at the edge of Mars orbit.", "Galaxy+", ["We have one sunrise left before the orbit closes.", "The mission was never the planet, it was bringing you home.", "Astronauts do not panic, they calculate loudly.", "Mars keeps the receipts for every brave idea.", "Point the dish at Earth and tell them we tried."]),
            ("The Blue Umbrella Job", "A stylish heist built around one rainy afternoon.", "Vault", ["When the blue umbrella opens, everyone changes partners.", "Rain hides footsteps, not motives.", "The vault code is written on the receipt.", "We steal the painting after the thunder.", "No getaway car looks innocent in daylight."]),
            ("Last Train to Aurora", "A romantic thriller aboard a train crossing frozen country.", "CinemaNow", ["Aurora is not a city, it is our last chance.", "Car seven is missing from the map.", "The conductor punched a ticket for a ghost.", "Snow makes every lie look clean.", "Kiss me before the tunnel tells the truth."]),
            ("Garden of Glass", "A contemplative fantasy about memory, grief, and impossible flowers.", "DreamHouse", ["Every glass flower blooms for a memory you refuse to name.", "Do not touch the roses unless you are ready to remember.", "The garden keeps what the house forgets.", "My mother planted silence here.", "Break one petal and the whole summer returns."]),
            ("Signal at Noon", "An urgent desert survival thriller around a broken radio tower.", "Sunset", ["At noon the signal bounces off the salt flats.", "If the tower falls, nobody knows we were here.", "Save the battery for a voice that answers.", "The desert is quiet because it is counting.", "Three clicks means run. Four means too late."]),
            ("The Ordinary Hero", "A tender city adventure about a courier pulled into a rescue.", "MetroPlay", ["I deliver envelopes, not destiny.", "The bridge is closing and she is still on the bus.", "Ordinary people only look ordinary from far away.", "Take my bike and do not ask heroic questions.", "The whole city moved one block to help us."]),
            ("Velvet Observatory", "A noir mystery set inside an art deco planetarium.", "Starlight", ["The stars on that ceiling are arranged like a threat.", "Velvet hides dust better than blood.", "Meet me under Orion when the projector fails.", "Every astronomer has one earthly secret.", "The dome went dark before she screamed."])
        ]

        let shows = showData.enumerated().map { index, item in
            media(title: item.0, type: .television, year: 2011 + index, overview: item.1, service: item.2, phrases: item.3, episodes: 3)
        }
        let movies = movieData.enumerated().map { index, item in
            media(title: item.0, type: .movie, year: 2006 + index, overview: item.1, service: item.2, phrases: item.3, episodes: 1)
        }
        return shows + movies
    }()

    private static func media(title: String, type: MediaType, year: Int, overview: String, service: String, phrases: [String], episodes: Int) -> MediaTitle {
        let id = stableID(title)
        let records = (1...episodes).map { episodeNumber in
            let episodeTitle = type == .movie ? title : ["Pilot Light", "Second Signal", "The Turning Point", "Final Cut"][episodeNumber - 1]
            let segments = phrases.enumerated().map { index, phrase in
                SubtitleSegment(
                    id: stableID("\(title)-\(episodeNumber)-\(index)"),
                    startSeconds: Double(180 + index * 210 + episodeNumber * 17),
                    endSeconds: Double(184 + index * 210 + episodeNumber * 17),
                    text: phrase
                )
            }
            return EpisodeRecord(
                id: stableID("\(title)-episode-\(episodeNumber)"),
                seasonNumber: type == .movie ? 0 : 1,
                episodeNumber: type == .movie ? 0 : episodeNumber,
                title: episodeTitle,
                runtimeSeconds: type == .movie ? 6900 : 2700,
                subtitleSegments: segments
            )
        }
        return MediaTitle(id: id, title: title, mediaType: type, releaseYear: year, overview: overview, posterAssetName: nil, streamingService: service, episodes: records)
    }

    static func stableID(_ seed: String) -> UUID {
        let scalars = Array(seed.utf8)
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in scalars.enumerated() {
            bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(index & 0xff)
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

