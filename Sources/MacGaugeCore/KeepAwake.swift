import Foundation
import IOKit.pwr_mgt

internal enum SleepAssertionKind { case system, display }

internal protocol SleepAssertionDriver {
    func create(_ kind: SleepAssertionKind, timeout: TimeInterval) throws -> IOPMAssertionID
    func release(_ id: IOPMAssertionID)
}

private struct SystemSleepAssertionDriver: SleepAssertionDriver {
    func create(_ kind: SleepAssertionKind, timeout: TimeInterval) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let type = kind == .system ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let name = kind == .system ? "MacGauge: Keep Mac awake" : "MacGauge: Keep display awake"
        let result = IOPMAssertionCreateWithDescription(type as CFString, name as CFString,
            "User-started keep-awake session" as CFString, nil, nil,
            timeout, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        guard result == kIOReturnSuccess else { throw KeepAwakeError.assertionFailed(result) }
        return id
    }
    func release(_ id: IOPMAssertionID) { IOPMAssertionRelease(id) }
}

public enum KeepAwakeError: LocalizedError {
    case invalidDuration, assertionFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidDuration: return "잠자기 방지 시간을 확인해 주세요."
        case .assertionFailed(let code): return "macOS에 잠자기 방지를 요청하지 못했습니다 (\(code))."
        }
    }
}

/// Owns process-scoped assertions, never modifies persistent power settings.
/// Call from one thread. The UI owns this instance on the main actor.
public final class KeepAwakeSession {
    private let driver: SleepAssertionDriver
    private var assertions: [IOPMAssertionID] = []
    public private(set) var deadline: Date?
    public private(set) var keepsDisplayAwake = false
    public var isActive: Bool { !assertions.isEmpty }

    public convenience init() { self.init(driver: SystemSleepAssertionDriver()) }
    internal init(driver: SleepAssertionDriver) { self.driver = driver }

    /// Replaces an existing session only after all requested assertions succeed.
    public func start(duration: TimeInterval?, keepDisplayAwake: Bool, now: Date = Date()) throws {
        if let duration, !duration.isFinite || duration <= 0 { throw KeepAwakeError.invalidDuration }
        var replacement: [IOPMAssertionID] = []
        do {
            replacement.append(try driver.create(.system, timeout: duration ?? 0))
            if keepDisplayAwake { replacement.append(try driver.create(.display, timeout: duration ?? 0)) }
        } catch {
            replacement.forEach { driver.release($0) }
            throw error
        }
        assertions.forEach { driver.release($0) }
        assertions = replacement
        deadline = duration.map { now.addingTimeInterval($0) }
        keepsDisplayAwake = keepDisplayAwake
    }

    public func stop() {
        assertions.forEach { driver.release($0) }
        assertions = []; deadline = nil; keepsDisplayAwake = false
    }

    /// Releases only the display assertion, preserving the system hold and its original deadline.
    public func allowDisplaySleep(now: Date = Date()) {
        expire(at: now)
        guard keepsDisplayAwake else { return }
        if let display = assertions.popLast() { driver.release(display) }
        keepsDisplayAwake = false
    }

    @discardableResult public func expire(at now: Date = Date()) -> Bool {
        guard isActive, let deadline, now >= deadline else { return false }
        stop(); return true
    }

    deinit { stop() }
}
