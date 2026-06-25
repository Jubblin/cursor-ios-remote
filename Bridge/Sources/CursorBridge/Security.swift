import Foundation

enum BridgeSecurity {
    static let maxHTTPBodyBytes = 65536
    static let maxDeviceTokens = 10
    static let expectedIOSBundleId = "com.jubblin.app.cursorremote"

    /// Listen address. Set `CURSOR_BRIDGE_BIND_ALL=1` to bind all interfaces (default for remote iPhone use).
    /// Set `CURSOR_BRIDGE_BIND=127.0.0.1` or a Tailscale IP to restrict exposure.
    static func listenAddress() -> String {
        if ProcessInfo.processInfo.environment["CURSOR_BRIDGE_BIND_ALL"] == "1" {
            return "0.0.0.0"
        }
        if let custom = ProcessInfo.processInfo.environment["CURSOR_BRIDGE_BIND"]?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return custom
        }
        return "0.0.0.0"
    }

    static func bindsAllInterfaces(_ address: String) -> Bool {
        address == "0.0.0.0" || address == "::"
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Data(lhs.utf8)
        let right = Data(rhs.utf8)
        guard left.count == right.count else { return false }
        return left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                var difference: UInt8 = 0
                for index in 0 ..< left.count {
                    difference |= leftBytes[index] ^ rightBytes[index]
                }
                return difference == 0
            }
        }
    }
}

final class AuthRateLimiter {
    private struct Entry {
        var failures: Int
        var windowStart: Date
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let maxFailures: Int
    private let windowSeconds: TimeInterval

    init(maxFailures: Int = 20, windowSeconds: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.windowSeconds = windowSeconds
    }

    func isBlocked(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        guard let entry = entries[key] else { return false }
        return entry.failures >= maxFailures
    }

    func recordFailure(key: String) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        let now = Date()
        if var entry = entries[key] {
            entry.failures += 1
            entries[key] = entry
        } else {
            entries[key] = Entry(failures: 1, windowStart: now)
        }
    }

    func reset(key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    private func pruneLocked() {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.windowStart) < windowSeconds }
    }
}

enum Hostname {
    static func local() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
    }
}
