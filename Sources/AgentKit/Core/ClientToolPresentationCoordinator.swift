#if os(iOS)

import ClientToolProtocol
import SwiftUI
import UIKit

/// Scene-bound presentation gateway used by client tools.
///
/// A hidden SwiftUI representable binds this coordinator to the active
/// conversation's UIKit hierarchy. Tools therefore never search globally for a
/// key window and cannot overlap another client-tool presentation.
@MainActor
final class DefaultClientToolPresentationCoordinator: ClientToolPresentationCoordinator {
    private weak var hostViewController: UIViewController?
    private weak var activeToolViewController: UIViewController?

    func bind(to hostViewController: UIViewController) {
        self.hostViewController = hostViewController
    }

    func unbind(from hostViewController: UIViewController) {
        if self.hostViewController === hostViewController {
            self.hostViewController = nil
        }
    }

    func present(
        _ viewController: UIViewController,
        animated: Bool
    ) async throws {
        guard activeToolViewController == nil else {
            throw ClientToolPresentationError.presentationInProgress
        }
        guard let presenter = currentPresenter() else {
            throw ClientToolPresentationError.unavailable
        }
        activeToolViewController = viewController
        await withCheckedContinuation { continuation in
            presenter.present(viewController, animated: animated) {
                continuation.resume()
            }
        }
        guard viewController.presentingViewController != nil else {
            activeToolViewController = nil
            throw ClientToolPresentationError.presentationFailed(
                "UIKit did not attach the requested view controller."
            )
        }
    }

    func dismiss(
        _ viewController: UIViewController,
        animated: Bool
    ) async {
        guard viewController.presentingViewController != nil else {
            if activeToolViewController === viewController {
                activeToolViewController = nil
            }
            return
        }
        await withCheckedContinuation { continuation in
            viewController.dismiss(animated: animated) {
                continuation.resume()
            }
        }
        if activeToolViewController === viewController {
            activeToolViewController = nil
        }
    }

    private func currentPresenter() -> UIViewController? {
        guard let hostViewController,
              let root = hostViewController.viewIfLoaded?.window?.rootViewController else {
            return nil
        }
        var presenter = root
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }
}

struct ClientToolPresentationHost: UIViewControllerRepresentable {
    let presentationCoordinator: DefaultClientToolPresentationCoordinator

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.view.isUserInteractionEnabled = false
        viewController.view.backgroundColor = .clear
        presentationCoordinator.bind(to: viewController)
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
        presentationCoordinator.bind(to: uiViewController)
    }

    static func dismantleUIViewController(
        _ uiViewController: UIViewController,
        coordinator: ()
    ) {
        // The owning ConversationViewModel retains the presentation coordinator.
        // A later host update replaces this weak anchor.
    }
}

#endif
