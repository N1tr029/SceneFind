import SwiftUI
import UIKit

struct SavedView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @State private var searchText = ""
    @State private var filter: SavedFilter = .all

    private var filteredResults: [ClipAnalysisResult] {
        model.savedResults.filter { result in
            let matchesSearch = searchText.isEmpty ||
                result.topCandidate.mediaTitle.localizedCaseInsensitiveContains(searchText) ||
                (result.topCandidate.episodeTitle ?? "").localizedCaseInsensitiveContains(searchText)
            return matchesSearch && filter.includes(result.topCandidate.mediaType)
        }
    }

    private var televisionGroups: [SavedShowGroup] {
        Dictionary(grouping: filteredResults.filter { $0.topCandidate.mediaType == .television }) {
            $0.topCandidate.mediaTitle
        }
        .map { SavedShowGroup(title: $0.key, results: $0.value) }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var movies: [ClipAnalysisResult] {
        filteredResults.filter { $0.topCandidate.mediaType == .movie }
    }

    private var otherMedia: [ClipAnalysisResult] {
        filteredResults.filter { $0.topCandidate.mediaType == .other }
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            VStack(spacing: 0) {
                HStack {
                    Label("\(model.savedResults.count) saved", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.sceneCoral)
                    Spacer()
                    SignalBars(accent: .sceneCoral)
                        .frame(width: 46, height: 18)
                }
                .padding(.horizontal)
                .padding(.top, 4)

                Picker("Saved category", selection: $filter) {
                    ForEach(SavedFilter.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if filteredResults.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: filter.symbolName,
                        description: Text(emptyDescription)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    savedList
                }
            }
        }
        .navigationTitle("Saved for later")
        .searchable(text: $searchText, prompt: "Search titles or episodes")
        .animation(.smooth(duration: 0.3), value: filter)
        .sensoryFeedback(.selection, trigger: filter)
        .toolbar {
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh saved items")
        }
    }

    private var savedList: some View {
        List {
            ForEach(televisionGroups) { group in
                Section {
                    ForEach(group.results) { result in
                        savedResultButton(result, showsArtwork: false)
                    }
                } header: {
                    SavedShowHeader(group: group)
                }
            }

            if !movies.isEmpty {
                Section {
                    ForEach(movies) { result in
                        savedResultButton(result)
                    }
                } header: {
                    Label("Movies", systemImage: "film")
                }
            }

            if !otherMedia.isEmpty {
                Section {
                    ForEach(otherMedia) { result in
                        savedResultButton(result)
                    }
                } header: {
                    Label("Other media", systemImage: "play.rectangle")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    private func savedResultButton(_ result: ClipAnalysisResult, showsArtwork: Bool = true) -> some View {
        Button { router.navigate(to: .savedDetail(result.id)) } label: {
            SavedRow(result: result, showsArtwork: showsArtwork)
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button(role: .destructive) { model.removeSaved(id: result.id) } label: {
                Label("Remove", systemImage: "bookmark.slash")
            }
            Button { UIPasteboard.general.string = result.topCandidate.mediaTitle } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .listRowBackground(Color.sceneSurface)
        .listRowSeparatorTint(.white.opacity(0.07))
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No matches" }
        switch filter {
        case .all: return "Nothing saved yet"
        case .television: return "No TV scenes saved"
        case .movies: return "No movies saved"
        case .other: return "No other media saved"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Try another title or episode name." }
        return "Use Save for later on a match to add it here."
    }
}

private enum SavedFilter: String, CaseIterable, Identifiable {
    case all
    case television
    case movies
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .television: "TV"
        case .movies: "Movies"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "bookmark"
        case .television: "tv"
        case .movies: "film"
        case .other: "play.rectangle"
        }
    }

    func includes(_ mediaType: MediaType) -> Bool {
        switch self {
        case .all: true
        case .television: mediaType == .television
        case .movies: mediaType == .movie
        case .other: mediaType == .other
        }
    }
}

private struct SavedShowGroup: Identifiable {
    let title: String
    let results: [ClipAnalysisResult]

    var id: String { title.lowercased() }
}

private struct SavedShowHeader: View {
    let group: SavedShowGroup

    var body: some View {
        HStack(spacing: 10) {
            if let candidate = group.results.first?.topCandidate {
                ShowCoverArtwork(candidate: candidate)
                    .frame(width: 30, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(group.results.count) saved scene\(group.results.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

struct SavedRow: View {
    let result: ClipAnalysisResult
    var showsArtwork = true

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                ShowCoverArtwork(candidate: result.topCandidate)
                    .frame(width: 48, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(rowTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(primaryDetail)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text("\(result.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(Int(result.topCandidate.confidence * 100))% · \(result.analysisDetails.sourcePlatform.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var rowTitle: String {
        if result.topCandidate.mediaType == .television {
            return result.topCandidate.episodeTitle ?? result.topCandidate.episodeLine
        }
        return result.topCandidate.mediaTitle
    }

    private var primaryDetail: String {
        let timestamp = result.topCandidate.sceneTimestampSeconds?.timestampString ?? "Unknown time"
        switch result.topCandidate.mediaType {
        case .television:
            return "\(result.topCandidate.episodeLine) · \(timestamp)"
        case .movie:
            return "\(result.topCandidate.releaseYear) · \(timestamp)"
        case .other:
            return "\(result.analysisDetails.sourcePlatform.label) · \(timestamp)"
        }
    }
}
