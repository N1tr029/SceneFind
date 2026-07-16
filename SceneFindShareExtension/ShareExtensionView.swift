import SwiftUI
import UIKit

struct ShareExtensionView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let cancel: () -> Void
    let openApp: (URL) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ShareThumbnail(request: viewModel.request)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find this scene")
                            .font(.title2.bold())
                        Text(viewModel.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                if viewModel.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(viewModel.request == nil ? "Reading shared clip" : "Opening SceneFind")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button {
                    Task {
                        if let url = await viewModel.save() {
                            openApp(url)
                        }
                    }
                } label: {
                    Label("Find in SceneFind", systemImage: "waveform.badge.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.request == nil || viewModel.isLoading)

                if let url = viewModel.openURL {
                    Link(destination: url) {
                        Label("Open SceneFind again", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("SceneFind")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
            }
        }
    }
}

private struct ShareThumbnail: View {
    let request: SharedClipRequest?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: request?.sourceType == .video ? "video.fill" : "link")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var image: UIImage? {
        guard let fileURL = SharedContainerStore.shared.resolveFileURL(fileName: request?.thumbnailFileName) else {
            return nil
        }
        return UIImage(contentsOfFile: fileURL.path)
    }
}
