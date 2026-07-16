import SwiftUI

struct ShareExtensionView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let done: () -> Void
    let cancel: () -> Void
    let openApp: (URL) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("Find this scene")
                    .font(.title2.bold())
                Text(viewModel.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if viewModel.isLoading {
                    ProgressView()
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

                Button("Cancel", role: .cancel, action: cancel)
            }
            .padding()
            .navigationTitle("SceneFind")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done", action: done)
            }
        }
    }
}
