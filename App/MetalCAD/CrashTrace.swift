import Foundation

/// Crash breadcrumbs for the blank-document creation crash
/// (device report, 2026-10-26, v4.8): a trail of stage marks is
/// kept in UserDefaults and synchronised after EVERY append, so
/// the trail survives a hard crash that never gets to flush
/// anything else. On the next launch, DocumentsView shows the
/// trail if a creation attempt was still "pending" (begun but
/// never reached the healthy mark in SceneKitView's first update).
/// Diagnostic only — this type changes no app behaviour.
enum CrashTrace {
    private static let trailKey = "mc.crashTrace"
    private static let pendingKey = "mc.crashTracePending"

    /// Append one stage to the trail (capped at 40 entries),
    /// prefixed with its 1-based position, and flush immediately.
    static func mark(_ stage: String) {
        var trail = UserDefaults.standard.stringArray(forKey: trailKey) ?? []
        trail.append("\(trail.count + 1). \(stage)")
        if trail.count > 40 {
            trail = Array(trail.suffix(40))
        }
        UserDefaults.standard.set(trail, forKey: trailKey)
        UserDefaults.standard.synchronize()
    }

    /// Start a fresh trail for a document-creation attempt and
    /// arm the pending flag — if the app dies before `healthy()`,
    /// the next launch knows the last session crashed mid-create.
    static func begin() {
        UserDefaults.standard.removeObject(forKey: trailKey)
        UserDefaults.standard.set(true, forKey: pendingKey)
        UserDefaults.standard.synchronize()
        mark("create: begin")
    }

    /// The editor fully rendered — the creation attempt survived.
    static func healthy() {
        UserDefaults.standard.set(false, forKey: pendingKey)
        UserDefaults.standard.synchronize()
    }

    /// The trail of an interrupted (crashed) session, if one is
    /// pending; nil when the last attempt completed healthily.
    static func pendingTrail() -> [String]? {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return nil }
        return UserDefaults.standard.stringArray(forKey: trailKey) ?? []
    }

    /// Dismiss the pending flag once the trail has been shown.
    static func clearPending() {
        UserDefaults.standard.set(false, forKey: pendingKey)
        UserDefaults.standard.synchronize()
    }
}
