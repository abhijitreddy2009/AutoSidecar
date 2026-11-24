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
///
/// Every SidecarCore call runs on a private serial queue: device lookups wait on the Sidecar service and
/// were measured blocking for 5 s right after a dropped session, which froze the main thread.
final class SidecarController: @unchecked Sendable {
    private typealias Completion = @convention(block) (NSError?) -> Void
    // The framework keeps the completion block and calls it later, so it must be @escaping
    // (non-escaping crashed: "non-escaping closure has escaped").
    private typealias DeviceCall = @convention(c) (NSObject, Selector, NSObject, @escaping Completion) -> Void

    let isAvailable: Bool
    private let queue = DispatchQueue(label: "SidecarController")
    private let managerClass: AnyClass?
    private let manager: NSObject?

    init() {
        dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW)
        let cls: AnyClass? = NSClassFromString("SidecarDisplayManager")
        managerClass = cls
        manager = (cls as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedManager"))?
            .takeUnretainedValue() as? NSObject
        isAvailable = manager != nil && cls.map { cls in
            ["connectToDevice:completion:", "disconnectFromDevice:completion:"].allSatisfy {
                class_getInstanceMethod(cls, NSSelectorFromString($0)) != nil
            }
        } ?? false
    }

    /// Name of the connected iPad, else the first one macOS offers for Sidecar.
    func iPadName() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let device = self.devices(forKey: "connectedDevices").first(where: Self.isIPad)
                    ?? self.devices(forKey: "devices").first(where: Self.isIPad)
                continuation.resume(returning: device?.value(forKey: "name") as? String)
            }
        }
    }

    func setSidecar(on: Bool) async -> Result<Void, SidecarControlError> {
        guard isAvailable, let managerClass else { return .failure(.unavailable) }
        let selector = NSSelectorFromString(on ? "connectToDevice:completion:" : "disconnectFromDevice:completion:")
        let call = unsafeBitCast(class_getMethodImplementation(managerClass, selector), to: DeviceCall.self)

        return await withCheckedContinuation { continuation in
            queue.async {
                guard let manager = self.manager,
                      let device = self.devices(forKey: on ? "devices" : "connectedDevices").first(where: Self.isIPad) else {
                    continuation.resume(returning: on ? .failure(.iPadNotListed) : .success(()))
                    return
                }
                let completion: Completion = { error in
                    continuation.resume(returning: Self.result(of: error, connecting: on))
                }
                call(manager, selector, device, completion)
            }
        }
    }

    private static func result(of error: NSError?, connecting: Bool) -> Result<Void, SidecarControlError> {
        guard let error else { return .success(()) }
        // Observed: connect can report "already in use" (-100) while the session comes up fine;
        // DisplayObserver is the judge of whether it worked.
        if connecting, error.domain == "SidecarErrorDomain", error.code == -100 { return .success(()) }
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
