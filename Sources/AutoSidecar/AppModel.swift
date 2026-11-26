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

    @ObservationIgnored private let logger = Logger(subsystem: "io.github.abhijitreddy2009.AutoSidecar", category: "app")
    @ObservationIgnored private let usb = USBMonitor()
    @ObservationIgnored private let display = DisplayObserver()
    @ObservationIgnored private let controller = SidecarController()
    @ObservationIgnored private var appleDevices: [UInt64: USBDevice] = [:]
    @ObservationIgnored private var actionToken = 0
    @ObservationIgnored private var connectRetries = 0
    @ObservationIgnored private var disconnectRetries = 0
    @ObservationIgnored private var unplugCheck: Task<Void, Never>?
    @ObservationIgnored private var lastConnectAt: Date?
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var pluggedInAt: Date?
    @ObservationIgnored private var retryPending = false
    /// While true, state is recorded but nothing is acted on: launch reports cable and screen one at a time.
    @ObservationIgnored private var launching = true
    /// Mac asleep, screens off or session locked/switched away: Sidecar can't run, so don't try.
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var lastPowerEventAt: Date?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var powerObservers: [NSObjectProtocol] = []

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
        // A menu bar app has no windows, so macOS would otherwise consider it idle and quit it.
        ProcessInfo.processInfo.disableAutomaticTermination("Watching for the iPad cable")
        observePower()
        display.start()
        usb.start()
        launching = false
        send(.reevaluate)
        refreshName()
    }

    // MARK: - Sleep, wake, screen lock

    /// Seen on real hardware: display sleep ends the Sidecar session while the iPad stays on the cable.
    /// Without this, that looked like the user turning Sidecar off, and it never came back.
    private func observePower() {
        let center = NSWorkspace.shared.notificationCenter
        let pausing: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                            NSWorkspace.sessionDidResignActiveNotification]
        let resuming: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                                             NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pausing {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.systemPaused(note.name) }
            })
        }
        for name in resuming {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.systemResumed(note.name) }
            })
        }
    }

    private func systemPaused(_ name: Notification.Name) {
        paused = true
        lastPowerEventAt = Date()
        resumeTask?.cancel()
        log("Paused: \(name.rawValue)")
    }

    private func systemResumed(_ name: Notification.Name) {
        paused = false
        lastPowerEventAt = Date()
        log("Resumed: \(name.rawValue)")
        scheduleResume()
    }

    /// Give the iPad and the Sidecar service a moment after wake, then reconnect if the cable is in.
    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !paused else { return }
            connectRetries = 0
            lastError = nil
            send(.systemResumed)
        }
    }

    private var endedBySystem: Bool {
        paused || lastPowerEventAt.map { Date().timeIntervalSince($0) < 30 } ?? false
    }

    private func refreshName() {
        Task { @MainActor in
            if let name = await controller.iPadName() { iPadName = name }
        }
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
            pluggedInAt = Date()
            send(.cableAttached)
        } else if present == nil, wasPresent {
            if inSessionStartWindow {
                confirmUnplug()
            } else {
                unplugged()
            }
        }
    }

    /// The iPad briefly drops off USB (~150 ms) just after it's plugged in and again when wired
    /// Sidecar starts. Only in those first seconds is a USB disappearance ambiguous; any other
    /// time it's a real unplug and Sidecar is told to disconnect at once.
    private var inSessionStartWindow: Bool {
        [pluggedInAt, lastConnectAt, sessionStartedAt].contains { $0.map { Date().timeIntervalSince($0) < 5 } ?? false }
    }

    private func confirmUnplug() {
        unplugCheck?.cancel()
        unplugCheck = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !appleDevices.values.contains(where: DeviceMatcher.isIPad) else { return }
            unplugged()
        }
    }

    private func unplugged() {
        log("iPad unplugged")
        cabledIPad = nil
        send(.cableDetached)
    }

    private func displayChanged(active: Bool) {
        guard active != state.sidecarActive else { return }
        log(active ? "Sidecar on" : "Sidecar off")
        if active {
            lastError = nil
            sessionStartedAt = Date()
            refreshName()
        } else {
            disconnectRetries = 0
        }
        let weDisconnected = state.inFlight == .disconnect
        send(active ? .sidecarAppeared : .sidecarDisappeared)
        if !active, state.cablePresent, endedBySystem, !weDisconnected {
            log("Session ended by sleep or lock, will reconnect")
            if !paused { scheduleResume() } // otherwise wake/unlock triggers it
            return
        }
        // Starting wired Sidecar can reset the iPad's USB link, and macOS then drops the new session
        // (SidecarErrorDomain -101) within a second. That's a failed attempt, not the user's choice.
        if !active, state.cablePresent, let started = lastConnectAt, Date().timeIntervalSince(started) < 10 {
            lastConnectAt = nil
            retryConnect(token: actionToken)
        }
    }

    private func send(_ event: SidecarEvent) {
        var (next, action) = SidecarReducer.reduce(state, event)
        if launching, action != nil {
            next.inFlight = nil
            action = nil
        }
        state = next
        if let action { perform(action) }
    }

    private func perform(_ action: SidecarAction) {
        actionToken += 1
        let token = actionToken
        Task { @MainActor in
            if action == .connect { try? await Task.sleep(for: Self.connectDelay) }
            guard token == actionToken, stillWanted(action) else {
                log("Skipped \(action == .connect ? "connect" : "disconnect"): token \(token == actionToken ? "current" : "stale"), active \(display.isSidecarActive), cable \(state.cablePresent)")
                return finish(token)
            }
            log(action == .connect ? "Connecting" : "Disconnecting")
            if action == .connect { lastConnectAt = Date() }
            var result = await controller.setSidecar(on: action == .connect)
            // The iPad can take a while to become available after plugging in, waking or logging in
            // (the Sidecar service starts late at login): keep trying for about a minute.
            for _ in 0..<20 {
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
        case .connect: return !active && state.cablePresent && !paused
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

    /// One failed attempt can be reported twice (the error and the screen disappearing): retry once.
    private func retryConnect(token: Int) {
        guard connectRetries < 3, !retryPending else { return }
        retryPending = true
        connectRetries += 1
        log("Retrying connection (\(connectRetries)/3)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            retryPending = false
            log("Retry firing (token \(token == actionToken ? "current" : "stale"), active \(display.isSidecarActive))")
            guard token == actionToken else { return }
            send(.connectFailed)
        }
    }

    /// `log stream --predicate 'subsystem == "io.github.abhijitreddy2009.AutoSidecar"'`
    private func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
