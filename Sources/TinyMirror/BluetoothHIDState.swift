import Foundation

/// Pure GATT subscription, session token and backpressure queue state owned by
/// the Bluetooth serial queue. Separated from CoreBluetooth so disconnect and
/// coalescing invariants can be tested without hardware.
struct BluetoothHIDConnectionState {
    enum Channel: Hashable {
        case report(HIDReportID)
        case serviceChanged
        case battery

        var isInput: Bool {
            if case .report = self { return true }
            return false
        }
    }

    struct PendingReport {
        let host: UUID
        let channel: Channel
        let data: Data
        let session: UUID?
        let isAbsoluteRelease: Bool
    }

    private(set) var subscriptions: [UUID: Set<Channel>] = [:]
    private(set) var sessions: [UUID: UUID] = [:]
    private(set) var pending: [PendingReport] = []
    private(set) var hostOrder: [UUID] = []
    private var sentAbsolutePositions: [UUID: Data] = [:]

    func isReady(report: HIDReportID, host: UUID, session: UUID?) -> Bool {
        guard let session, sessions[host] == session else { return false }
        return subscriptions[host]?.contains(.report(report)) == true
    }

    func subscribedReports(for host: UUID) -> Set<HIDReportID> {
        guard let channels = subscriptions[host] else { return [] }
        var reports: Set<HIDReportID> = []
        for channel in channels {
            if case .report(let id) = channel {
                reports.insert(id)
            }
        }
        return reports
    }

    /// Selects the best active input host: prefers a host with AssistiveTouch's
    /// absolute pointer subscribed, then relative mouse, then keyboard, breaking
    /// ties by most recent subscription (so an Apple Watch never steals input from
    /// an active iPhone).
    func preferredInputHost(matching savedHost: UUID? = nil) -> UUID? {
        let activeHosts = Array(sessions.keys)
        guard !activeHosts.isEmpty else { return nil }
        return activeHosts.max { lhs, rhs in
            rank(lhs, savedHost: savedHost) < rank(rhs, savedHost: savedHost)
        }
    }

    private func rank(_ host: UUID, savedHost: UUID?) -> (Int, Int, Int, Int, Int) {
        let reports = subscribedReports(for: host)
        let hasAbsolute = reports.contains(.absolutePointer) ? 1 : 0
        let hasRelative = reports.contains(.relativeMouse) ? 1 : 0
        let hasKeyboard = reports.contains(.keyboard) ? 1 : 0
        let matchesSaved = (savedHost != nil && host == savedHost) ? 1 : 0
        let recency = hostOrder.firstIndex(of: host) ?? -1
        return (hasAbsolute, hasRelative, hasKeyboard, matchesSaved, recency)
    }

    mutating func subscribe(_ channel: Channel, host: UUID) {
        subscriptions[host, default: []].insert(channel)
        if channel.isInput {
            if sessions[host] == nil {
                sessions[host] = UUID()
            }
            hostOrder.removeAll { $0 == host }
            hostOrder.append(host)
        }
    }

    mutating func unsubscribe(_ channel: Channel, host: UUID) {
        subscriptions[host]?.remove(channel)
        if channel == .report(.absolutePointer) {
            sentAbsolutePositions[host] = nil
        }
        pending.removeAll { $0.host == host && $0.channel == channel }
        if !(subscriptions[host]?.contains(where: \.isInput) ?? false) {
            sessions[host] = nil
            hostOrder.removeAll { $0 == host }
            pending.removeAll { $0.host == host && $0.channel.isInput }
        }
        if subscriptions[host]?.isEmpty == true {
            subscriptions[host] = nil
        }
    }

    mutating func enqueue(
        _ channel: Channel,
        data: Data,
        host: UUID,
        session: UUID? = nil,
        absoluteRelease: Bool = false
    ) {
        guard subscriptions[host]?.contains(channel) == true else { return }
        if channel.isInput {
            guard let session, sessions[host] == session else { return }
        }
        let release = absoluteRelease
            && channel == .report(.absolutePointer)
            && data.count == HIDReportID.absolutePointer.reportLength
            && data.first == 0
        let report = PendingReport(
            host: host,
            channel: channel,
            data: data,
            session: session,
            isAbsoluteRelease: release)
        // Coalesce only idle hover moves; keep button transitions, drags, keys, and deltas intact.
        if channel == .report(.absolutePointer),
           data.first == 0,
           let last = pending.last,
           last.host == host,
           last.channel == channel,
           last.data.first == 0,
           !last.isAbsoluteRelease,
           !report.isAbsoluteRelease
        {
            pending[pending.count - 1] = report
        } else {
            pending.append(report)
        }
    }

    /// Returns the next eligible queued report while skipping hosts whose transmit
    /// slot rejected an earlier notification in the same drain pass.
    mutating func nextPendingReportIndex(
        excludingHosts: Set<UUID> = []
    ) -> (index: Int, report: PendingReport)? {
        var index = 0
        while index < pending.count {
            let report = pending[index]
            if excludingHosts.contains(report.host) {
                index += 1
                continue
            }
            let subscribed = subscriptions[report.host]?.contains(report.channel) == true
            let currentSession = !report.channel.isInput
                || (report.session != nil && sessions[report.host] == report.session)
            if subscribed, currentSession {
                if report.isAbsoluteRelease, var position = sentAbsolutePositions[report.host] {
                    position[0] = 0
                    return (
                        index,
                        PendingReport(
                            host: report.host,
                            channel: report.channel,
                            data: position,
                            session: report.session,
                            isAbsoluteRelease: true)
                    )
                }
                return (index, report)
            }
            pending.remove(at: index)
        }
        return nil
    }

    mutating func removePending(at index: Int, accepted: Bool = true) {
        let report = pending.remove(at: index)
        if accepted,
           report.channel == .report(.absolutePointer),
           !report.isAbsoluteRelease,
           report.data.count == HIDReportID.absolutePointer.reportLength
        {
            sentAbsolutePositions[report.host] = report.data
        }
    }

    mutating func reset() {
        subscriptions.removeAll()
        sessions.removeAll()
        pending.removeAll()
        hostOrder.removeAll()
        sentAbsolutePositions.removeAll()
    }
}

/// Bounded outbound BLE wake/reconnect state machine so late cancellation callbacks
/// cannot drop a newer connection attempt and retries stay finite.
struct BluetoothHIDReconnectTracker {
    static let retryDelays: [TimeInterval] = [2, 6, 12, 20, 30]
    static let maxAutomaticAttempts = retryDelays.count + 1
    static let attemptTimeout: TimeInterval = 20

    enum Phase: Equatable {
        case connecting(attempt: UInt64)
        case established(attempt: UInt64)
        case cancelling(attempt: UInt64, retryDesired: Bool)
        case backoff(token: UInt64)
    }

    enum DisconnectFollowUp: Equatable {
        case none
        case retryNow
        case scheduleBackoff(token: UInt64, delay: TimeInterval)
        case notifyChanged
    }

    private(set) var targets: Set<UUID> = []
    private(set) var phases: [UUID: Phase] = [:]
    private(set) var attemptsUsed: [UUID: Int] = [:]
    private var nextToken: UInt64 = 0

    mutating func updateTargets(
        _ newTargets: Set<UUID>,
        activeSessions: Set<UUID>,
        resetExhausted: Bool
    ) -> [UUID] {
        let added = newTargets.subtracting(targets)
        for host in added {
            attemptsUsed[host] = 0
        }
        if resetExhausted {
            for host in newTargets {
                attemptsUsed[host] = 0
            }
        }
        targets = newTargets

        var toCancel: [UUID] = []
        for (host, phase) in phases {
            if !newTargets.contains(host) {
                switch phase {
                case .connecting(let attempt), .established(let attempt):
                    if !activeSessions.contains(host) {
                        phases[host] = .cancelling(attempt: attempt, retryDesired: false)
                        toCancel.append(host)
                    }
                case .cancelling(let attempt, _):
                    phases[host] = .cancelling(attempt: attempt, retryDesired: false)
                case .backoff:
                    phases[host] = nil
                }
            } else if !activeSessions.contains(host) {
                switch phase {
                case .established(let attempt):
                    phases[host] = .cancelling(attempt: attempt, retryDesired: true)
                    toCancel.append(host)
                case .cancelling(let attempt, let retryDesired):
                    if !retryDesired, (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts {
                        phases[host] = .cancelling(attempt: attempt, retryDesired: true)
                    }
                case .backoff:
                    if resetExhausted {
                        phases[host] = nil
                    }
                case .connecting:
                    break
                }
            }
        }
        return toCancel
    }

    mutating func connectableHosts(activeSessions: Set<UUID>) -> Set<UUID> {
        var ready: Set<UUID> = []
        for host in targets where !activeSessions.contains(host) {
            guard (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts else { continue }
            switch phases[host] {
            case nil:
                ready.insert(host)
            case .cancelling(let attempt, false):
                phases[host] = .cancelling(attempt: attempt, retryDesired: true)
            case .connecting, .established, .cancelling(_, true), .backoff:
                break
            }
        }
        return ready
    }

    mutating func beginConnecting(_ host: UUID) -> UInt64 {
        nextToken &+= 1
        let attempt = nextToken
        attemptsUsed[host, default: 0] += 1
        phases[host] = .connecting(attempt: attempt)
        return attempt
    }

    mutating func markUnretrievable(_ host: UUID) {
        attemptsUsed[host] = Self.maxAutomaticAttempts
        phases[host] = nil
    }

    mutating func noteSessionEstablished(_ host: UUID) {
        attemptsUsed[host] = 0
        switch phases[host] {
        case .connecting(let attempt):
            phases[host] = .established(attempt: attempt)
        case .backoff:
            phases[host] = nil
        case .established, .cancelling, nil:
            break
        }
    }

    mutating func markTimedOut(host: UUID, attempt: UInt64, hasActiveSession: Bool) -> Bool {
        guard !hasActiveSession, phases[host] == .connecting(attempt: attempt) else { return false }
        phases[host] = .cancelling(attempt: attempt, retryDesired: false)
        return true
    }

    mutating func handleTermination(host: UUID, hasActiveSession: Bool) -> DisconnectFollowUp {
        guard let previous = phases.removeValue(forKey: host) else { return .none }
        guard !hasActiveSession else { return .none }
        guard targets.contains(host) else { return .notifyChanged }

        let used = attemptsUsed[host] ?? 0
        if case .cancelling(_, true) = previous, used < Self.maxAutomaticAttempts {
            return .retryNow
        }
        if case .established = previous, used < Self.maxAutomaticAttempts {
            return .retryNow
        }
        if used < Self.maxAutomaticAttempts {
            nextToken &+= 1
            let token = nextToken
            let delayIndex = min(max(0, used - 1), Self.retryDelays.count - 1)
            let delay = Self.retryDelays[delayIndex]
            phases[host] = .backoff(token: token)
            return .scheduleBackoff(token: token, delay: delay)
        }
        return .notifyChanged
    }

    mutating func completeBackoff(host: UUID, token: UInt64, hasActiveSession: Bool) -> Bool {
        guard phases[host] == .backoff(token: token) else { return false }
        phases[host] = nil
        return !hasActiveSession
            && targets.contains(host)
            && (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts
    }

    func reconnectingHosts(activeSessions: Set<UUID>) -> Set<UUID> {
        var result: Set<UUID> = []
        for (host, phase) in phases where !activeSessions.contains(host) {
            switch phase {
            case .connecting, .backoff, .cancelling(_, true):
                result.insert(host)
            case .cancelling(_, false):
                if targets.contains(host), (attemptsUsed[host] ?? 0) < Self.maxAutomaticAttempts {
                    result.insert(host)
                }
            case .established:
                break
            }
        }
        return result
    }

    mutating func cancelEstablishedOnPeripheralReset() -> [UUID] {
        var toCancel: [UUID] = []
        for (host, phase) in phases {
            if case .established(let attempt) = phase {
                phases[host] = .cancelling(attempt: attempt, retryDesired: targets.contains(host))
                toCancel.append(host)
            }
        }
        return toCancel
    }

    mutating func cancelAllForStop() -> [UUID] {
        targets.removeAll()
        return suspendForLifecycleTeardown()
    }

    mutating func suspendForLifecycleTeardown() -> [UUID] {
        var toCancel: [UUID] = []
        for (host, phase) in phases {
            switch phase {
            case .connecting, .established, .cancelling:
                toCancel.append(host)
            case .backoff:
                break
            }
        }
        phases.removeAll()
        attemptsUsed.removeAll()
        return toCancel
    }

    mutating func resetForCentralPowerOff() {
        phases.removeAll()
        attemptsUsed.removeAll()
    }
}
