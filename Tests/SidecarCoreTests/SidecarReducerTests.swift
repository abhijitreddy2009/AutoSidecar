import XCTest
@testable import SidecarCore

final class SidecarReducerTests: XCTestCase {
    private func run(_ events: [SidecarEvent], from start: SidecarState = .init()) -> (SidecarState, [SidecarAction?]) {
        var state = start
        var actions: [SidecarAction?] = []
        for event in events {
            let (next, action) = SidecarReducer.reduce(state, event)
            state = next
            actions.append(action)
        }
        return (state, actions)
    }

    func testPlugInConnectsAndUnplugDisconnects() {
        let (state, actions) = run([.cableAttached, .sidecarAppeared, .cableDetached, .sidecarDisappeared])
        XCTAssertEqual(actions, [.connect, nil, .disconnect, nil])
        XCTAssertFalse(state.sidecarActive)
        XCTAssertNil(state.inFlight)
    }

    func testWirelessSessionWithoutCableIsKilledInStrictMode() {
        let (_, actions) = run([.sidecarAppeared])
        XCTAssertEqual(actions, [.disconnect])
    }

    func testWirelessSessionAllowedWhenStrictOff() {
        let (_, actions) = run([.sidecarAppeared], from: .init(enabled: true, strictWired: false))
        XCTAssertEqual(actions, [nil])
    }

    func testUnplugEndsCabledSessionEvenWhenStrictOff() {
        let (_, actions) = run([.cableAttached, .sidecarAppeared, .cableDetached],
                               from: .init(enabled: true, strictWired: false))
        XCTAssertEqual(actions, [.connect, nil, .disconnect])
    }

    func testSessionThatDropsAfterConnectErrorIsRetriedNotSuppressed() {
        // Real trace: display appears, relay closes session (-101), display disappears.
        let (state, actions) = run([.cableAttached, .sidecarAppeared, .sidecarDisappeared, .connectFailed])
        XCTAssertEqual(actions, [.connect, nil, nil, .connect])
        XCTAssertFalse(state.suppressed)
    }

    func testSessionEndedBySleepReconnectsOnWake() {
        // Real trace: display sleep ended the session while the iPad stayed on the cable.
        let (state, actions) = run([.cableAttached, .sidecarAppeared, .sidecarDisappeared, .systemResumed])
        XCTAssertEqual(actions, [.connect, nil, nil, .connect])
        XCTAssertFalse(state.suppressed)
    }

    func testWakeWithoutCableDoesNothing() {
        let (_, actions) = run([.systemResumed])
        XCTAssertEqual(actions, [nil])
    }

    func testFailedDisconnectCanBeRetried() {
        let (state, actions) = run([.cableAttached, .sidecarAppeared, .cableDetached, .actionFinished, .reevaluate])
        XCTAssertEqual(actions, [.connect, nil, .disconnect, nil, .disconnect])
        XCTAssertEqual(state.inFlight, .disconnect)
    }

    func testUserDisconnectWhileCabledIsRespectedUntilReplug() {
        let (state, actions) = run([.cableAttached, .sidecarAppeared, .sidecarDisappeared])
        XCTAssertEqual(actions, [.connect, nil, nil])
        XCTAssertTrue(state.suppressed)
        let (_, replug) = run([.cableDetached, .cableAttached], from: state)
        XCTAssertEqual(replug, [nil, .connect])
    }

    func testNoDoubleTriggerWhileInFlight() {
        let (_, actions) = run([.cableAttached, .cableDetached, .cableAttached])
        XCTAssertEqual(actions, [.connect, nil, nil])
    }

    func testFailedConnectDoesNotLoop() {
        let (state, actions) = run([.cableAttached, .actionFinished])
        XCTAssertEqual(actions, [.connect, nil])
        XCTAssertNil(state.inFlight)
    }

    func testDisabledDoesNothing() {
        let (_, actions) = run([.cableAttached, .sidecarAppeared, .cableDetached], from: .init(enabled: false))
        XCTAssertEqual(actions, [nil, nil, nil])
    }

    func testManualConnectBlockedWithoutCableInStrictMode() {
        let (_, actions) = run([.manualConnect])
        XCTAssertEqual(actions, [nil])
    }

    func testManualDisconnectSuppressesAutoReconnect() {
        let (state, actions) = run([.cableAttached, .sidecarAppeared, .manualDisconnect, .sidecarDisappeared])
        XCTAssertEqual(actions, [.connect, nil, .disconnect, nil])
        XCTAssertTrue(state.suppressed)
    }

    func testDeviceMatching() {
        let iPad = USBDevice(registryID: 1, vendorID: 0x05AC, productName: "iPad", serial: "ABC", speed: .superSpeed)
        let iPhone = USBDevice(registryID: 2, vendorID: 0x05AC, productName: "iPhone", serial: "X", speed: .high)
        let fake = USBDevice(registryID: 3, vendorID: 0x1234, productName: "iPad case", serial: nil, speed: .high)
        XCTAssertTrue(DeviceMatcher.isIPad(iPad))
        XCTAssertFalse(DeviceMatcher.isIPad(iPhone))
        XCTAssertFalse(DeviceMatcher.isIPad(fake))
        XCTAssertTrue(DeviceMatcher.isSidecarScreen(name: "Sidecar Display (AirPlay)"))
        XCTAssertTrue(DeviceMatcher.isSidecarScreen(name: "Abhi's iPad"))
        XCTAssertFalse(DeviceMatcher.isSidecarScreen(name: "LG UltraFine"))
        XCTAssertFalse(USBSpeed.high.isFastEnoughForSidecar)
        XCTAssertTrue(USBSpeed.superSpeedPlus.isFastEnoughForSidecar)
    }

    func testRegistrySpeedMapping() {
        // Real ioreg values from a USB 2 hub: "Device Speed" = 2, "USBSpeed" = 3.
        XCTAssertEqual(USBSpeed.fromRegistry(deviceSpeed: 2, hostSpeed: 3), .high)
        XCTAssertEqual(USBSpeed.fromRegistry(deviceSpeed: nil, hostSpeed: 3), .high)
        XCTAssertEqual(USBSpeed.fromRegistry(deviceSpeed: nil, hostSpeed: 4), .superSpeed)
        XCTAssertEqual(USBSpeed.fromRegistry(deviceSpeed: nil, hostSpeed: nil), .unknown)
    }
}
