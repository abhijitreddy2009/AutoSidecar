import Foundation
import IOKit
import IOKit.usb
import SidecarCore

/// Event-driven USB hot-plug watcher for Apple devices (no polling).
final class USBMonitor {
    var onAttach: ((USBDevice) -> Void)?
    var onDetach: ((USBDevice) -> Void)?

    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var known: [UInt64: USBDevice] = [:]

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.matching(), { ctx, iterator in
            guard let ctx else { return }
            Unmanaged<USBMonitor>.fromOpaque(ctx).takeUnretainedValue().drain(iterator, attached: true)
        }, context, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.matching(), { ctx, iterator in
            guard let ctx else { return }
            Unmanaged<USBMonitor>.fromOpaque(ctx).takeUnretainedValue().drain(iterator, attached: false)
        }, context, &removedIterator)

        // Draining arms the notifications and reports iPads already plugged in at launch.
        drain(addedIterator, attached: true)
        drain(removedIterator, attached: false)
    }

    deinit {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    // A top-level "idVendor" key matches nothing for IOUSBHostDevice (verified: 0 results vs 9),
    // so match on class only and filter the vendor in drain().
    private static func matching() -> CFDictionary {
        IOServiceMatching("IOUSBHostDevice")
    }

    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if attached {
                let device = Self.describe(service, entryID: entryID)
                guard device.vendorID == DeviceMatcher.appleVendorID else { continue }
                known[entryID] = device
                onAttach?(device)
            } else if let device = known.removeValue(forKey: entryID) {
                onDetach?(device)
            }
        }
    }

    private static func describe(_ service: io_service_t, entryID: UInt64) -> USBDevice {
        func property<T>(_ key: String) -> T? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? T
        }
        let speed = USBSpeed.fromRegistry(deviceSpeed: property("Device Speed"), hostSpeed: property("USBSpeed"))
        return USBDevice(
            registryID: entryID,
            vendorID: property("idVendor") ?? 0,
            productName: property("USB Product Name") ?? property("kUSBProductString") ?? "Unknown",
            serial: property("USB Serial Number") ?? property("kUSBSerialNumberString"),
            speed: speed
        )
    }
}
