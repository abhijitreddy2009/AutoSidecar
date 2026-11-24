import AppKit
import SidecarCore

/// Ground truth for "is Sidecar running": a Sidecar screen exists.
final class DisplayObserver {
    var onChange: ((_ active: Bool) -> Void)?
    private var token: NSObjectProtocol?

    var isSidecarActive: Bool {
        NSScreen.screens.contains { DeviceMatcher.isSidecarScreen(name: $0.localizedName) }
    }

    func start() {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            onChange?(isSidecarActive)
        }
        onChange?(isSidecarActive)
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
