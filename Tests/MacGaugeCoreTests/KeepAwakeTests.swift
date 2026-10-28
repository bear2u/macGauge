import XCTest
import IOKit.pwr_mgt
@testable import MacGaugeCore

private final class FakeSleepDriver: SleepAssertionDriver {
    var created: [(SleepAssertionKind, TimeInterval)] = []
    var released: [IOPMAssertionID] = []
    var failDisplay = false
    func create(_ kind: SleepAssertionKind, timeout: TimeInterval) throws -> IOPMAssertionID {
        if kind == .display && failDisplay { throw KeepAwakeError.assertionFailed(-1) }
        created.append((kind, timeout)); return IOPMAssertionID(created.count)
    }
    func release(_ id: IOPMAssertionID) { released.append(id) }
}

final class KeepAwakeTests: XCTestCase {
    func testTimedSessionRequestsBothAssertionsAndExpires() throws {
        let driver = FakeSleepDriver(), now = Date(timeIntervalSince1970: 100)
        let session = KeepAwakeSession(driver: driver)
        try session.start(duration: 60, keepDisplayAwake: true, now: now)
        XCTAssertEqual(driver.created.map(\.0), [.system, .display])
        XCTAssertEqual(driver.created.map(\.1), [60, 60])
        XCTAssertTrue(session.keepsDisplayAwake)
        XCTAssertFalse(session.expire(at: now.addingTimeInterval(59)))
        XCTAssertTrue(session.expire(at: now.addingTimeInterval(60)))
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(driver.released, [1, 2])
        session.stop()
        XCTAssertEqual(driver.released, [1, 2])
    }
    func testIndefiniteSessionOnlyHoldsSystemAndReleasesOnDeinit() throws {
        let driver = FakeSleepDriver()
        var session: KeepAwakeSession? = KeepAwakeSession(driver: driver)
        try session?.start(duration: nil, keepDisplayAwake: false)
        XCTAssertNil(session?.deadline)
        XCTAssertEqual(driver.created.map(\.0), [.system])
        XCTAssertEqual(driver.created.map(\.1), [0])
        XCTAssertFalse(session!.expire(at: .distantFuture))
        session = nil
        XCTAssertEqual(driver.released, [1])
    }
    func testPartialFailureReleasesNewAssertionAndPreservesExistingSession() throws {
        let driver = FakeSleepDriver(), now = Date(timeIntervalSince1970: 100)
        let session = KeepAwakeSession(driver: driver)
        try session.start(duration: 60, keepDisplayAwake: false, now: now)
        driver.failDisplay = true
        XCTAssertThrowsError(try session.start(duration: 120, keepDisplayAwake: true, now: now))
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.keepsDisplayAwake)
        XCTAssertEqual(session.deadline, now.addingTimeInterval(60))
        XCTAssertEqual(driver.released, [2])
    }
    func testReplacementReleasesOldAssertions() throws {
        let driver = FakeSleepDriver()
        let observed = KeepAwakeSession(driver: driver)
        try observed.start(duration: nil, keepDisplayAwake: true)
        try observed.start(duration: 30, keepDisplayAwake: false)
        XCTAssertEqual(driver.released, [1, 2])
        XCTAssertFalse(observed.keepsDisplayAwake)
        XCTAssertTrue(observed.isActive)
    }
    func testInvalidDurationDoesNotAcquireAssertions() {
        let driver = FakeSleepDriver()
        let observed = KeepAwakeSession(driver: driver)
        for duration in [0.0, -1.0, .infinity, .nan] {
            XCTAssertThrowsError(try observed.start(duration: duration, keepDisplayAwake: false))
        }
        XCTAssertTrue(driver.created.isEmpty)
        XCTAssertFalse(observed.isActive)
    }
}
