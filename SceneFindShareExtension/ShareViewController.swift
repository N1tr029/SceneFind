import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private let viewModel = ShareExtensionViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareExtensionView(viewModel: viewModel) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: SceneFindError.unsupportedSharedItem)
        } openApp: { [weak self] url in
            self?.extensionContext?.open(url) { opened in
                if opened {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    Task { @MainActor [weak self] in
                        self?.viewModel.appOpenFailed()
                    }
                }
            }
        }
        let controller = UIHostingController(rootView: root)
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)

        Task {
            await viewModel.load(from: extensionContext)
        }
    }
}
