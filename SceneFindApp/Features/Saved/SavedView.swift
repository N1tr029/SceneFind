import SwiftUI
import UIKit

struct SavedView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: SceneFindModel
    @State private var searchText = ""

    private var filtered: [ClipAnalysisResult] {
        guard !searchText.isEmpty else { return model.savedResults }
        return model.savedResults.filter {
            $0.topCandidate.mediaTitle.localizedCaseInsensitiveContains(searchText) ||
            ($0.topCandidate.episodeTitle ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            CinematicBackground()
            if filtered.isEmpty {
                ContentUnavailableView("No saved scenes", systemImage: "bookmark", description: Text("Saved results appear here."))
            } else {
                List {
                    ForEach(filtered) { result in
                        Button { router.navigate(to: .savedDetail(result.id)) } label: {
                            SavedRow(result: result)
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.removeSaved(id: result.id) } label: {
                                Label("Remove", systemImage: "bookmark.slash")
                            }
                            Button { UIPasteboard.general.string = result.topCandidate.mediaTitle } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Saved")
        .searchable(text: $searchText, prompt: "Search saved scenes")
        .toolbar {
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

struct SavedRow: View {
    let result: ClipAnalysisResult

    var body: some View {
        HStack(spacing: 12) {
            ShowCoverArtwork(candidate: result.topCandidate)
                .frame(width: 48, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Text(result.topCandidate.mediaTitle)
                    .font(.headline)
                Text("\(result.topCandidate.episodeLine) • \(result.topCandidate.sceneTimestampSeconds?.timestampString ?? "Unknown time")")
                    .font(.subheadline)
                Text("\(result.createdAt.formatted(date: .abbreviated, time: .shortened)) • \(Int(result.topCandidate.confidence * 100))% • \(result.analysisDetails.sourcePlatform.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
