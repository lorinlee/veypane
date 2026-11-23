import Foundation

public enum MemoryPressureSeverity: String, Codable, Equatable, Sendable {
    case warning
    case critical
}

public enum WebContentRecoveryDecision: Equatable, Sendable {
    case notNeeded
    case autoReload
    case suppressedManualReloadRequired
}

/// Loop-guarded renderer-crash recovery state for a single `WKWebView` (`t455`).
/// Ensures background terminated tabs defer reload until focused, foreground/focused tabs
/// auto-recover cleanly once or twice, and repeated rapid crashes stop looping so the user can retry manually.
public struct WebContentRecoveryState: Equatable, Sendable {
    public static let defaultMaxConsecutiveAutoRecoveries: Int = 2
    public static let defaultAutoRecoveryCooldownSeconds: TimeInterval = 15.0

    public private(set) var needsRecovery: Bool = false
    public private(set) var consecutiveCrashCount: Int = 0
    public private(set) var totalTerminationCount: Int = 0
    public private(set) var lastTerminationAt: Date?
    public private(set) var lastAutoRecoveryAt: Date?
    public let maxConsecutiveAutoRecoveries: Int
    public let autoRecoveryCooldownSeconds: TimeInterval

    public init(
        maxConsecutiveAutoRecoveries: Int = defaultMaxConsecutiveAutoRecoveries,
        autoRecoveryCooldownSeconds: TimeInterval = defaultAutoRecoveryCooldownSeconds
    ) {
        self.maxConsecutiveAutoRecoveries = max(1, maxConsecutiveAutoRecoveries)
        self.autoRecoveryCooldownSeconds = max(0, autoRecoveryCooldownSeconds)
    }

    public mutating func recordTermination(now: Date = Date()) {
        needsRecovery = true
        consecutiveCrashCount &+= 1
        totalTerminationCount &+= 1
        lastTerminationAt = now
    }

    public mutating func consumeAutoRecoveryIfAllowed(now: Date = Date()) -> WebContentRecoveryDecision {
        guard needsRecovery else { return .notNeeded }
        if consecutiveCrashCount > maxConsecutiveAutoRecoveries {
            return .suppressedManualReloadRequired
        }
        if let last = lastAutoRecoveryAt, now.timeIntervalSince(last) < autoRecoveryCooldownSeconds {
            return .suppressedManualReloadRequired
        }
        needsRecovery = false
        lastAutoRecoveryAt = now
        return .autoReload
    }

    public mutating func clearPendingRecovery() {
        needsRecovery = false
    }

    public mutating func recordSuccessfulNavigation() {
        needsRecovery = false
        consecutiveCrashCount = 0
    }
}

public enum PadWorkspaceEngine {
    public static let maxClosedPadsHistory = 25
    public static let maxRecentHistory = 40

    public static func recordHistory(
        in state: inout WorkspaceState,
        title: String,
        url: URL,
        now: Date = Date()
    ) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = cleanTitle.isEmpty ? (url.host ?? url.absoluteString) : cleanTitle

        state.recentHistory.removeAll { $0.url.absoluteString.lowercased() == url.absoluteString.lowercased() }
        state.recentHistory.insert(
            RecentHistoryEntry(title: resolvedTitle, url: url, visitedAt: now),
            at: 0
        )
        if state.recentHistory.count > maxRecentHistory {
            state.recentHistory.removeLast(state.recentHistory.count - maxRecentHistory)
        }
    }

    public static func reorderPad(draggedID: UUID, before targetID: UUID, in state: inout WorkspaceState) {
        guard draggedID != targetID,
              let fromIndex = state.pads.firstIndex(where: { $0.id == draggedID }),
              let toIndex = state.pads.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        movePad(from: fromIndex, to: toIndex, in: &state)
    }

    public static func addPad(
        to state: inout WorkspaceState,
        url: URL,
        title: String? = nil,
        hasCustomTitle: Bool = false,
        symbolName: String = "globe",
        profileID: UUID? = nil,
        select: Bool = true
    ) -> Pad {
        let inferredTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String
        if let inferredTitle, !inferredTitle.isEmpty {
            resolvedTitle = inferredTitle
        } else {
            resolvedTitle = url.host ?? url.absoluteString
        }

        let pad = Pad(
            title: resolvedTitle,
            hasCustomTitle: hasCustomTitle,
            url: url,
            symbolName: symbolName,
            profileID: profileID ?? state.activeProfileID
        )
        state.pads.append(pad)
        if select || state.selectedPadID == nil {
            state.selectedPadID = pad.id
        }
        return pad
    }

    public static func renamePad(
        id: UUID,
        newTitle: String,
        in state: inout WorkspaceState
    ) {
        guard let idx = state.pads.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.pads[idx].hasCustomTitle = false
            state.pads[idx].title = state.pads[idx].url.host ?? state.pads[idx].url.absoluteString
        } else {
            state.pads[idx].title = trimmed
            state.pads[idx].hasCustomTitle = true
        }
    }

    public static func resetCustomTitle(
        id: UUID,
        fallbackPageTitle: String? = nil,
        in state: inout WorkspaceState
    ) {
        guard let idx = state.pads.firstIndex(where: { $0.id == id }) else { return }
        state.pads[idx].hasCustomTitle = false
        if let raw = fallbackPageTitle, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.pads[idx].applyObservedPageTitle(raw)
        } else {
            state.pads[idx].title = state.pads[idx].url.host ?? state.pads[idx].url.absoluteString
        }
    }

    /// Removes a pad and records it onto `closedPads` stack for `⌘⇧T` restore.
    @discardableResult
    public static func removePad(id: UUID, from state: inout WorkspaceState, now: Date = Date()) -> Pad? {
        guard let index = state.pads.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = state.pads.remove(at: index)
        state.closedPads.insert(
            ClosedPadRecord(pad: removed, closedIndex: index, closedAt: now),
            at: 0
        )
        if state.closedPads.count > maxClosedPadsHistory {
            state.closedPads.removeLast(state.closedPads.count - maxClosedPadsHistory)
        }

        if state.selectedPadID == id {
            if state.pads.isEmpty {
                state.selectedPadID = nil
            } else {
                let fallbackIndex = min(index, state.pads.count - 1)
                state.selectedPadID = state.pads[fallbackIndex].id
            }
        }
        return removed
    }

    /// Reopens the most recently closed pad (`⌘⇧T`).
    @discardableResult
    public static func reopenLastClosedPad(in state: inout WorkspaceState, now: Date = Date()) -> Pad? {
        guard !state.closedPads.isEmpty else { return nil }
        let record = state.closedPads.removeFirst()
        var restored = record.pad
        restored.isHibernated = false
        restored.lastActiveAt = now

        let insertIndex = min(max(0, record.closedIndex), state.pads.count)
        state.pads.insert(restored, at: insertIndex)
        state.selectedPadID = restored.id
        return restored
    }

    public static func movePad(from sourceIndex: Int, to destinationIndex: Int, in state: inout WorkspaceState) {
        guard state.pads.indices.contains(sourceIndex) else { return }
        let item = state.pads.remove(at: sourceIndex)
        let clamped = min(max(0, destinationIndex), state.pads.count)
        state.pads.insert(item, at: clamped)
    }

    /// Cycles selection forward (`⌃Tab`) or backward (`⌃⇧Tab`).
    @discardableResult
    public static func cyclePad(forward: Bool, in state: inout WorkspaceState, now: Date = Date()) -> UUID? {
        guard !state.pads.isEmpty else { return nil }
        let currentIndex = state.pads.firstIndex(where: { $0.id == state.selectedPadID }) ?? 0
        let count = state.pads.count
        let nextIndex = forward
            ? (currentIndex + 1) % count
            : (currentIndex - 1 + count) % count
        let targetID = state.pads[nextIndex].id
        selectPad(id: targetID, in: &state, now: now)
        return targetID
    }

    /// Jumps to pad shortcut `⌘1`…`⌘9` (1-based number). `⌘9` jumps to the 9th pad if at least 9 exist, or the last pad when fewer? Spec says `⌘1…⌘9 jump`: 1..8 direct index, 9 -> index 8 if count >= 9 else last pad if count > 0? Wait: standard browser `⌘9` jumps to last tab, or 9th if <=8 doesn't exist. Wait: if there are 10 pads, does `⌘9` jump to 9th or last? Let's jump to `shortcutNumber - 1` when `shortcutNumber <= state.pads.count` for 1...9, and if `shortcutNumber == 9 && state.pads.count > 9` or `state.pads.count < 9`? Wait: let's make 1...8 jump to `number - 1` (if in range), and `9` jump to index 8 when `count >= 9` or `state.pads.last` when `count < 9`? Even better: let's make `1...9` jump directly to `number - 1` if `number - 1 < count`! Wait—what if user presses `⌘9` with 4 pads expecting last pad or no-op? In Safari/Chrome, `⌘1`..`⌘8` select tabs 1..8 and `⌘9` selects the last tab (which IS tab 9 when there are 9 tabs!). Let's check: if `count == 9`, `count - 1 == 8` (9th pad)! Let's check if any test expects 9th vs last: if we support `jumpToNumber(_ number: Int, in state: inout WorkspaceState)` where `1...8` selects index `number - 1` (when `< count`) and `9` selects `min(8, count - 1)` when `count <= 9` or `8` when `>= 9`? Direct 1-based index `number - 1` when `< count` is crystal-clear and predictable for `"⌘1…⌘9 jump"`. Let's use direct 1-based index `0..<9` when `< state.pads.count`.
    @discardableResult
    public static func selectPadByShortcutNumber(_ number: Int, in state: inout WorkspaceState, now: Date = Date()) -> UUID? {
        guard (1...9).contains(number) else { return nil }
        let index = number - 1
        guard state.pads.indices.contains(index) else { return nil }
        let id = state.pads[index].id
        selectPad(id: id, in: &state, now: now)
        return id
    }

    public static func selectPad(id: UUID, in state: inout WorkspaceState, now: Date = Date()) {
        guard let index = state.pads.firstIndex(where: { $0.id == id }) else { return }
        // Refresh the departing pad's `lastActiveAt` BEFORE leaving it so a pad that was actively viewed
        // for longer than `autoHibernateMinutes` is not immediately evicted on the next 60s timer tick (`t455`).
        if let previousID = state.selectedPadID,
           previousID != id,
           let prevIndex = state.pads.firstIndex(where: { $0.id == previousID }),
           !state.pads[prevIndex].isHibernated {
            state.pads[prevIndex].lastActiveAt = now
        }
        state.selectedPadID = id
        state.pads[index].isHibernated = false
        state.pads[index].lastActiveAt = now
    }

    /// Marks the currently selected non-hibernated pad active at `now` so long active viewing sessions
    /// never accumulate stale `lastActiveAt` timestamps.
    public static func touchActivePad(in state: inout WorkspaceState, now: Date = Date()) {
        guard let selectedID = state.selectedPadID,
              let idx = state.pads.firstIndex(where: { $0.id == selectedID }),
              !state.pads[idx].isHibernated else {
            return
        }
        state.pads[idx].lastActiveAt = now
    }

    /// Evaluates idle background pads and marks eligible ones hibernated when `autoHibernateMinutes > 0`.
    /// Returns the IDs of pads newly transitioned to hibernated so the UI can unload their `WKWebView`s.
    public static func hibernateIdlePads(
        in state: inout WorkspaceState,
        now: Date = Date(),
        protectedPadIDs: Set<UUID> = []
    ) -> [UUID] {
        touchActivePad(in: &state, now: now)
        let minutes = AppSettings.sanitizedAutoHibernateMinutes(state.settings.autoHibernateMinutes)
        guard minutes > 0 else { return [] }
        let thresholdSeconds = TimeInterval(minutes) * 60.0
        var newlyHibernated: [UUID] = []

        for index in state.pads.indices {
            let pad = state.pads[index]
            if pad.id == state.selectedPadID || pad.isHibernated || protectedPadIDs.contains(pad.id) {
                continue
            }
            if now.timeIntervalSince(pad.lastActiveAt) >= thresholdSeconds {
                state.pads[index].isHibernated = true
                newlyHibernated.append(pad.id)
            }
        }
        return newlyHibernated
    }

    /// Enforces `settings.maxLivePads` (> 0) by marking the least-recently-active non-protected background
    /// live pads hibernated until `livePadIDs.count - evicted.count <= maxLivePads`.
    public static func evictExcessLivePadsForCapacity(
        in state: inout WorkspaceState,
        livePadIDs: Set<UUID>,
        protectedPadIDs: Set<UUID> = []
    ) -> [UUID] {
        let cap = AppSettings.sanitizedMaxLivePads(state.settings.maxLivePads)
        guard cap > 0, livePadIDs.count > cap else { return [] }
        let excessCount = livePadIDs.count - cap

        let candidates: [(index: Int, pad: Pad)] = state.pads.enumerated().compactMap { idx, pad in
            guard livePadIDs.contains(pad.id),
                  !pad.isHibernated,
                  pad.id != state.selectedPadID,
                  !protectedPadIDs.contains(pad.id) else {
                return nil
            }
            return (idx, pad)
        }
        .sorted { lhs, rhs in
            if lhs.pad.lastActiveAt != rhs.pad.lastActiveAt {
                return lhs.pad.lastActiveAt < rhs.pad.lastActiveAt
            }
            return lhs.index < rhs.index
        }

        var evicted: [UUID] = []
        for entry in candidates.prefix(excessCount) {
            state.pads[entry.index].isHibernated = true
            evicted.append(entry.pad.id)
        }
        return evicted
    }

    /// Graceful memory-pressure eviction policy (`t455`).
    /// - `.warning` + Always Keep (`autoHibernateMinutes == 0`): evicts nothing (app avoids proactive discard).
    /// - `.warning` + timed retention (`autoHibernateMinutes > 0`): evicts stalest 50% (at least 1) of background live pads.
    /// - `.critical` (any mode): evicts eligible background live pads while ALWAYS preserving `selectedPadID` and `protectedPadIDs` (e.g. PiP).
    public static func evictPadsForMemoryPressure(
        in state: inout WorkspaceState,
        livePadIDs: Set<UUID>,
        protectedPadIDs: Set<UUID> = [],
        severity: MemoryPressureSeverity
    ) -> [UUID] {
        let alwaysKeep = (AppSettings.sanitizedAutoHibernateMinutes(state.settings.autoHibernateMinutes) == 0)
        if severity == .warning && alwaysKeep {
            return []
        }

        let candidates: [(index: Int, pad: Pad)] = state.pads.enumerated().compactMap { idx, pad in
            guard livePadIDs.contains(pad.id),
                  !pad.isHibernated,
                  pad.id != state.selectedPadID,
                  !protectedPadIDs.contains(pad.id) else {
                return nil
            }
            return (idx, pad)
        }
        .sorted { lhs, rhs in
            if lhs.pad.lastActiveAt != rhs.pad.lastActiveAt {
                return lhs.pad.lastActiveAt < rhs.pad.lastActiveAt
            }
            return lhs.index < rhs.index
        }

        guard !candidates.isEmpty else { return [] }
        let evictCount: Int = switch severity {
        case .warning:
            max(1, (candidates.count + 1) / 2)
        case .critical:
            candidates.count
        }

        var evicted: [UUID] = []
        for entry in candidates.prefix(evictCount) {
            state.pads[entry.index].isHibernated = true
            evicted.append(entry.pad.id)
        }
        return evicted
    }

    public static func findPad(matching query: String, in pads: [Pad]) -> Pad? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let uuid = UUID(uuidString: trimmed),
           let exactID = pads.first(where: { $0.id == uuid }) {
            return exactID
        }

        let lowered = trimmed.lowercased()
        if let exactTitle = pads.first(where: { $0.title.lowercased() == lowered }) {
            return exactTitle
        }
        if let hostMatch = pads.first(where: { ($0.url.host ?? "").lowercased() == lowered }) {
            return hostMatch
        }
        return pads.first(where: {
            $0.title.lowercased().contains(lowered) || $0.url.absoluteString.lowercased().contains(lowered)
        })
    }
}
