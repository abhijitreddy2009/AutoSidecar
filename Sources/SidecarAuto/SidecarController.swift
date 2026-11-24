import Foundation
import ObjectiveC

enum SidecarControlError: LocalizedError {
    case unavailable
    case iPadNotListed
    case sidecar(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Sidecar isn't available on this Mac."
        case .iPadNotListed:
            "iPad not available. Unlock it and sign in to the same Apple Account."
        case let .sidecar(message):
            message
        }
    }
}

/// Talks to macOS's own Sidecar service through the private SidecarCore framework (the same calls
/// System Settings makes). Verified on macOS 27: connect/disconnect add/remove the "Sidecar Display".
/// Private API: if Apple renames these selectors, `isAvailable` turns false and the menu says so.
@MainActor
final class SidecarController {
    private typealias Completion = @convention(block) (NSError?) -> Void
    // The framework keeps the completion block and calls it later, so it must be @escaping
    // (non-escaping crashed: "non-escaping closure has escaped").
    private typealias DeviceCall = @convention(c) (NSObject, Selector, NSObject, @escaping Completion) -> Void

    private let managerClass: AnyClass?
    private let manager: NSObject?

    init() {
        dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW)
        let cls: AnyClass? = NSClassFromString("SidecarDisplayManager")
        managerClass = cls
        manager = (cls as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedManager"))?
            .takeUnretainedValue() as? NSObject
    }

    var isAvailable: Bool {
        guard let managerClass, manager != nil else { return false }
        return ["connectToDevice:completion:", "disconnectFromDevice:completion:"].allSatisfy {
            class_getInstanceMethod(managerClass, NSSelectorFromString($0)) != nil
        }
    }

    /// iPads macOS currently offers for Sidecar (the list fills in a moment after launch).
    func deviceNames() -> [String] {
        devices(forKey: "devices").compactMap { $0.value(forKey: "name") as? String }
    }

    func connectedDeviceNames() -> [String] {
        devices(forKey: "connectedDevices").compactMap { $0.value(forKey: "name") as? String }
    }

    func setSidecar(on: Bool) async -> Result<Void, SidecarControlError> {
        guard isAvailable, let manager, let managerClass else { return .failure(.unavailable) }
        let pool = devices(forKey: on ? "devices" : "connectedDevices")
        guard let device = pool.first(where: Self.isIPad) else {
            return on ? .failure(.iPadNotListed) : .success(())
        }

        let selector = NSSelectorFromString(on ? "connectToDevice:completion:" : "disconnectFromDevice:completion:")
        let call = unsafeBitCast(class_getMethodImplementation(managerClass, selector), to: DeviceCall.self)
        let error: NSError? = await withCheckedContinuation { continuation in
            let completion: Completion = { continuation.resume(returning: $0) }
            call(manager, selector, device, completion)
        }
        guard let error else { return .success(()) }
        // Observed: connect can report "already in use" (-100) while the session comes up fine;
        // DisplayObserver is the judge of whether it worked.
        if on, error.domain == "SidecarErrorDomain", error.code == -100 { return .success(()) }
        return .failure(.sidecar(error.localizedDescription))
    }

    private func devices(forKey key: String) -> [NSObject] {
        (manager?.value(forKey: key) as? [NSObject]) ?? []
    }

    private static func isIPad(_ device: NSObject) -> Bool {
        let name = device.value(forKey: "name") as? String ?? ""
        let type = device.value(forKey: "deviceTypeIdentifier") as? String ?? ""
        return type.localizedCaseInsensitiveContains("ipad") || name.localizedCaseInsensitiveContains("ipad")
    }
}
