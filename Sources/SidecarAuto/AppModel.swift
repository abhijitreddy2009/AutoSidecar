import AppKit
import Observation
import OSLog
import ServiceManagement
import SidecarCore

@MainActor
@Observable
final class AppModel {
    private(set) var state: SidecarState
    private(set) var cabledIPad: USBDevice?
    private(set) var iPadName: String?
    private(set) var lastError: String?

    var autoConnect: Bool {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
            send(.settingsChanged(enabled: autoConnect, strictWired: true))
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Couldn't change Launch at Login"
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    @ObservationIgnored private let logger = Logger(subsystem: "io.github.abhijitreddy2009.SidecarAuto", category: "app")
    @ObservationIgnored private let usb = USBMonitor()
    @ObservationIgnored private let display = DisplayObserver()
    @ObservationIgnored private let controller = SidecarController()
    @ObservationIgnored private var appleDevices: [UInt64: USBDevice] = [:]
    @ObservationIgnored private var actionToken = 0
    @ObservationIgnored private var connectRetries = 0
    @ObservationIgnored private var disconnectRetries = 0
    @ObservationIgnored private var unplugCheck: Task<Void, Never>?
    @ObservationIgnored private var lastConnectAt: Date?

    /// A freshly plugged iPad needs a moment before Sidecar can reach it.
    private static let connectDelay: Duration = .seconds(1)

    var statusText: String {
        let name = iPadName ?? "iPad"
        if !controller.isAvailable { return "Sidecar isn't available on this Mac" }
        if state.inFlight == .connect { return "\(name) — Connecting…" }
        if state.inFlight == .disconnect { return "\(name) — Disconnecting…" }
        if state.sidecarActive { return "\(name) — Connected" }
        if !state.cablePresent { return "Plug in your iPad" }
        if let lastError { return lastError }
        return "\(name) — Ready"
    }

    var cableWarning: String? {
        guard let speed = cabledIPad?.speed, !speed.isFastEnoughForSidecar else { return nil }
        return "USB 2 cable · may be unstable"
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["autoConnect": true])
        autoConnect = defaults.bool(forKey: "autoConnect")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        state = SidecarState(enabled: defaults.bool(forKey: "autoConnect"), strictWired: true)

        usb.onAttach = { [weak self] device in
            MainActor.assumeIsolated { self?.updateDevices { $0[device.registryID] = device } }
        }
        usb.onDetach = { [weak self] device in
            MainActor.assumeIsolated { self?.updateDevices { $0[device.registryID] = nil } }
        }
        display.onChange = { [weak self] active in
            MainActor.assumeIsolated { self?.displayChanged(active: active) }
        }
        usb.start()
        display.start()
    }

    func connectNow() {
        connectRetries = 0
        send(.manualConnect)
    }

    func disconnectNow() { send(.manualDisconnect) }

    // MARK: - Events

    private func updateDevices(_ change: (inout [UInt64: USBDevice]) -> Void) {
        let wasPresent = state.cablePresent
        change(&appleDevices)
        let present = appleDevices.values.first(where: DeviceMatcher.isIPad)
        if present != nil {
            unplugCheck?.cancel()
            cabledIPad = present
        }
        if let present, !wasPresent {
            log("\(present.productName) plugged in · \(present.speed.label)")
            connectRetries = 0
            lastError = nil
            send(.cableAttached)
        } else if present == nil, wasPresent {
            confirmUnplug()
        }
    }

    /// Starting wired Sidecar makes the iPad drop off USB for ~150 ms and come back.
    /// Only treat it as unplugged if it stays gone, or that blink would end the new session.
    private func confirmUnplug() {
        unplugCheck?.cancel()
        unplugCheck = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !appleDevices.values.contains(where: DeviceMatcher.isIPad) else { return }
            log("iPad unplugged")
            cabledIPad = nil
            send(.cableDetached)
        }
    }

    private func displayChanged(active: Bool) {
        guard active != state.sidecarActive else { return }
        log(active ? "Sidecar on" : "Sidecar off")
        if active {
            lastError = nil
        } else {
            disconnectRetries = 0
        }
        send(active ? .sidecarAppeared : .sidecarDisappeared)
        // Starting wired Sidecar can reset the iPad's USB link, and macOS then drops the new session
        // (SidecarErrorDomain -101) within a second. That's a failed attempt, not the user's choice.
        if !active, state.cablePresent, let started = lastConnectAt, Date().timeIntervalSince(started) < 10 {
            lastConnectAt = nil
            retryConnect(token: actionToken)
        }
    }

    private func send(_ event: SidecarEvent) {
        let (next, action) = SidecarReducer.reduce(state, event)
        state = next
        iPadName = controller.connectedDeviceNames().first ?? controller.deviceNames().first ?? iPadName
        if let action { perform(action) }
    }

    private func perform(_ action: SidecarAction) {
        actionToken += 1
        let token = actionToken
        Task { @MainActor in
            if action == .connect { try? await Task.sleep(for: Self.connectDelay) }
            guard token == actionToken, stillWanted(action) else { return finish(token) }
            log(action == .connect ? "Connecting" : "Disconnecting")
            if action == .connect { lastConnectAt = Date() }
            var result = await controller.setSidecar(on: action == .connect)
            // The iPad can take a few seconds to become available after plugging in.
            for _ in 0..<2 {
                guard case .failure(.iPadNotListed) = result, action == .connect else { break }
                try? await Task.sleep(for: .seconds(3))
                guard token == actionToken, stillWanted(action) else { return finish(token) }
                result = await controller.setSidecar(on: true)
            }
            switch result {
            case let .failure(error):
                lastError = error.localizedDescription
                log("Error: \(error.localizedDescription)")
                finish(token, failed: action)
            case .success:
                try? await Task.sleep(for: .seconds(10))
                guard token == actionToken, state.inFlight != nil else { return }
                log("Sidecar didn't change state within 10 s")
                finish(token, failed: action)
            }
        }
    }

    private func stillWanted(_ action: SidecarAction) -> Bool {
        let active = display.isSidecarActive
        switch action {
        case .connect: return !active && state.cablePresent
        case .disconnect: return active
        }
    }

    private func finish(_ token: Int, failed: SidecarAction? = nil) {
        guard token == actionToken else { return }
        send(.actionFinished)
        switch failed {
        case .connect:
            retryConnect(token: token)
        case .disconnect where disconnectRetries < 3:
            // A session left running without the cable must not stay up: back off and retry.
            disconnectRetries += 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard token == actionToken else { return }
                send(.reevaluate)
            }
        default:
            break
        }
    }

    private func retryConnect(token: Int) {
        guard connectRetries < 3 else { return }
        connectRetries += 1
        log("Retrying connection (\(connectRetries)/3)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard token == actionToken else { return }
            send(.connectFailed)
        }
    }

    /// `log stream --predicate 'subsystem == "io.github.abhijitreddy2009.SidecarAuto"'`
    private func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
