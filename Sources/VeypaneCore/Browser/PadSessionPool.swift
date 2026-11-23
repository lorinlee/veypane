import Foundation

/// Unit-testable pad session lifecycle coordinator ensuring:
/// 1. Switching pads or showing/hiding the panel never destroys or reloads existing live pad sessions.
/// 2. Navigating an uninitialized/hibernated pad vs. an already-live pad issues strictly one load request (never two).
public struct PadSessionPool<Session> {
    private var sessions: [UUID: Session] = [:]
    public private(set) var webViewCreations: Int = 0
    public private(set) var loadRequests: Int = 0
    public private(set) var reloadRequests: Int = 0
    public private(set) var padSwitchCount: Int = 0

    public init() {}

    public var livePadIDs: Set<UUID> {
        Set(sessions.keys)
    }

    public func existingSession(for padID: UUID) -> Session? {
        sessions[padID]
    }

    @discardableResult
    public mutating func ensureSession(
        for pad: Pad,
        makeAndInitialLoad: (Pad) -> Session
    ) -> Session {
        if let existing = sessions[pad.id] {
            return existing
        }
        webViewCreations &+= 1
        loadRequests &+= 1
        let created = makeAndInitialLoad(pad)
        sessions[pad.id] = created
        return created
    }

    @discardableResult
    public mutating func switchPad(
        from previousPadID: UUID?,
        to targetPad: Pad,
        makeAndInitialLoad: (Pad) -> Session
    ) -> Session {
        if previousPadID != targetPad.id {
            padSwitchCount &+= 1
        }
        return ensureSession(for: targetPad, makeAndInitialLoad: makeAndInitialLoad)
    }

    @discardableResult
    public mutating func navigate(
        pad: Pad,
        to url: URL,
        makeAndInitialLoad: (Pad) -> Session,
        loadURLOnExisting: (Session, URL) -> Void
    ) -> Session {
        if let existing = sessions[pad.id] {
            loadRequests &+= 1
            loadURLOnExisting(existing, url)
            return existing
        }
        var updatedPad = pad
        updatedPad.url = url
        return ensureSession(for: updatedPad, makeAndInitialLoad: makeAndInitialLoad)
    }

    public mutating func reload(
        pad: Pad,
        makeAndInitialLoad: (Pad) -> Session,
        reloadExisting: (Session) -> Void
    ) {
        if let existing = sessions[pad.id] {
            reloadRequests &+= 1
            reloadExisting(existing)
        } else {
            _ = ensureSession(for: pad, makeAndInitialLoad: makeAndInitialLoad)
        }
    }

    @discardableResult
    public mutating func evictSession(for padID: UUID) -> Session? {
        sessions.removeValue(forKey: padID)
    }
}
