import Foundation

public enum SidecarAction: Equatable, Sendable {
    case connect, disconnect
}

public struct SidecarState: Equatable, Sendable {
    public var enabled: Bool
    public var strictWired: Bool
    public var cablePresent = false
    public var sidecarActive = false
    /// User turned Sidecar off while the cable stayed in: respect it until the cable is re-plugged.
    public var suppressed = false
    /// Session began while the iPad was on the cable: unplugging ends it even when strict mode is off.
    public var cabledSession = false
    public var inFlight: SidecarAction?

    public init(enabled: Bool = true, strictWired: Bool = true) {
        self.enabled = enabled
        self.strictWired = strictWired
    }
}

public enum SidecarEvent: Equatable, Sendable {
    case cableAttached, cableDetached
    case sidecarAppeared, sidecarDisappeared
    case settingsChanged(enabled: Bool, strictWired: Bool)
    case actionFinished
    /// Re-run the decision after a backoff (used to retry a failed disconnect).
    case reevaluate
    /// macOS reported the connect failed (session may have flashed up then dropped): not a user choice, retry.
    case connectFailed
    /// The Mac woke, its screens came back or the user unlocked it. A session that ended meanwhile
    /// was ended by the system, not the user, so reconnect if the cable is in.
    case systemResumed
    case manualConnect, manualDisconnect
}

public enum SidecarReducer {
    public static func reduce(_ state: SidecarState, _ event: SidecarEvent) -> (SidecarState, SidecarAction?) {
        var next = state
        switch event {
        case .cableAttached:
            next.cablePresent = true
            next.suppressed = false
        case .cableDetached:
            next.cablePresent = false
            next.suppressed = false
        case .sidecarAppeared:
            next.sidecarActive = true
            next.cabledSession = next.cablePresent
            if next.inFlight == .connect { next.inFlight = nil }
        case .sidecarDisappeared:
            next.sidecarActive = false
            next.cabledSession = false
            if next.inFlight == .disconnect {
                next.inFlight = nil
            } else if next.cablePresent {
                next.suppressed = true
            }
        case let .settingsChanged(enabled, strictWired):
            next.enabled = enabled
            next.strictWired = strictWired
        case .actionFinished:
            next.inFlight = nil
            return (next, nil)
        case .reevaluate:
            break
        case .connectFailed:
            next.suppressed = false
            if next.inFlight == .connect { next.inFlight = nil }
        case .systemResumed:
            next.suppressed = false
        case .manualConnect:
            next.suppressed = false
            let wiredBlocked = next.strictWired && !next.cablePresent
            guard next.inFlight == nil, !next.sidecarActive, !wiredBlocked else { return (next, nil) }
            next.inFlight = .connect
            return (next, .connect)
        case .manualDisconnect:
            guard next.inFlight == nil, next.sidecarActive else { return (next, nil) }
            next.suppressed = next.cablePresent
            next.inFlight = .disconnect
            return (next, .disconnect)
        }
        return decide(next)
    }

    static func decide(_ state: SidecarState) -> (SidecarState, SidecarAction?) {
        guard state.enabled, state.inFlight == nil else { return (state, nil) }
        var next = state
        if state.cablePresent, !state.sidecarActive, !state.suppressed {
            next.inFlight = .connect
            return (next, .connect)
        }
        if !state.cablePresent, state.sidecarActive, state.strictWired || state.cabledSession {
            next.inFlight = .disconnect
            return (next, .disconnect)
        }
        return (state, nil)
    }
}
