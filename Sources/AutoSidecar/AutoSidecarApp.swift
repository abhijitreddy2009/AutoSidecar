import AppKit
import SwiftUI

@main
struct AutoSidecarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: "ipad.landscape")
                .symbolVariant(model.state.sidecarActive ? .fill : .none)
        }
    }
}

private struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Text(model.statusText)
        if let warning = model.cableWarning {
            Text(warning)
        }

        Divider()

        if model.state.sidecarActive {
            Button("Disconnect") { model.disconnectNow() }
        } else {
            Button("Connect") { model.connectNow() }
                .disabled(!model.state.cablePresent || model.state.inFlight != nil)
        }

        Divider()

        Toggle("Connect Automatically", isOn: $model.autoConnect)
        Toggle("Launch at Login", isOn: $model.launchAtLogin)

        Divider()

        Button("Quit AutoSidecar") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
