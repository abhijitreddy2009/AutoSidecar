import Foundation

public enum USBSpeed: Int, Sendable {
    case low = 0, full = 1, high = 2, superSpeed = 3, superSpeedPlus = 4, superSpeedPlus2x2 = 5
    case unknown = -1

    public var label: String {
        switch self {
        case .low: "USB 1 · 1.5 Mb/s"
        case .full: "USB 1 · 12 Mb/s"
        case .high: "USB 2 · 480 Mb/s"
        case .superSpeed: "USB 3 · 5 Gb/s"
        case .superSpeedPlus: "USB 3 · 10 Gb/s"
        case .superSpeedPlus2x2: "USB 3 · 20 Gb/s"
        case .unknown: "Unknown speed"
        }
    }

    /// Registry "Device Speed" uses this enum's raw values; "USBSpeed" (IOUSBHost) is numbered
    /// none=0, full=1, low=2, high=3, super=4, super+=5, super+2x2=6. Verified against `ioreg` on a USB 2 hub.
    public static func fromRegistry(deviceSpeed: Int?, hostSpeed: Int?) -> USBSpeed {
        if let deviceSpeed, let speed = USBSpeed(rawValue: deviceSpeed) { return speed }
        switch hostSpeed {
        case 1: return .full
        case 2: return .low
        case 3: return .high
        case 4: return .superSpeed
        case 5: return .superSpeedPlus
        case 6: return .superSpeedPlus2x2
        default: return .unknown
        }
    }

    /// Sidecar video over USB is reported to need USB 3 link speeds; USB 2 cables tend to fail or stutter.
    public var isFastEnoughForSidecar: Bool {
        self == .unknown || rawValue >= USBSpeed.superSpeed.rawValue
    }
}

public struct USBDevice: Equatable, Hashable, Sendable, Identifiable {
    public let registryID: UInt64
    public let vendorID: Int
    public let productName: String
    public let serial: String?
    public let speed: USBSpeed

    public var id: UInt64 { registryID }

    public init(registryID: UInt64, vendorID: Int, productName: String, serial: String?, speed: USBSpeed) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productName = productName
        self.serial = serial
        self.speed = speed
    }
}

public enum DeviceMatcher {
    public static let appleVendorID = 0x05AC

    /// An iPad on the cable.
    public static func isIPad(_ device: USBDevice) -> Bool {
        device.vendorID == appleVendorID && device.productName.localizedCaseInsensitiveContains("ipad")
    }

    /// Sidecar adds a virtual screen named "Sidecar Display (AirPlay)" (seen on macOS 27) or after the iPad.
    public static func isSidecarScreen(name: String) -> Bool {
        name.localizedCaseInsensitiveContains("sidecar") || name.localizedCaseInsensitiveContains("ipad")
    }
}
