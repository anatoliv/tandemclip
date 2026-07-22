import Foundation

/// Decides when the automatic reconnect watchdog should rebuild the transport.
///
/// Pure policy — no clock, no I/O — so the backoff ladder is unit-testable
/// without waiting out real timers. The caller supplies the time and the
/// environment gating (pairing code present, not paused, network allowed);
/// this type only answers "has sync been dead long enough to be worth a
/// rebuild?". See `SyncEngine.watchdogTick`.
///
/// Two properties keep it from becoming a churn machine:
/// - `everSynced`: it never fires until this Mac has actually connected to a
///   peer at least once, so a genuinely solo Mac (or one whose partner is
///   simply switched off) never rebuilds its transport on a loop.
/// - growing backoff, reset the moment a peer comes back.
struct ReconnectWatchdog {
    /// Idle thresholds, in seconds, one per consecutive failed attempt. The last
    /// entry is the steady-state ceiling.
    let backoff: [Double]

    private(set) var everSynced = false
    private(set) var lastPeerOnline: Double = 0
    private(set) var lastAttempt: Double = 0
    private(set) var strikes = 0

    init(backoff: [Double]) {
        precondition(!backoff.isEmpty, "watchdog needs at least one backoff step")
        self.backoff = backoff
    }

    /// Seed the idle clock at launch, so "idle since 1970" can't read as an
    /// instant fault before discovery has had any chance to run.
    mutating func noteStarted(at time: Double) {
        lastPeerOnline = time
    }

    /// A peer is connected: the transport is provably working. Arms the watchdog
    /// for the future and clears any accumulated backoff.
    mutating func notePeerOnline(at time: Double) {
        everSynced = true
        lastPeerOnline = time
        strikes = 0
    }

    /// Record a rebuild attempt made outside the watchdog (the user's Reconnect),
    /// so it gets the same grace period before the watchdog tries again. It
    /// deliberately does not clear `strikes`: repeated manual clicks shouldn't
    /// reset the ladder, only an actual reconnection should.
    mutating func noteAttempt(at time: Double) {
        lastAttempt = time
    }

    /// The idle threshold that was exceeded (for logging), or nil to hold off.
    /// Records the attempt when it returns non-nil.
    mutating func shouldRebuild(at time: Double, anyPeerOnline: Bool) -> Double? {
        guard everSynced, !anyPeerOnline else { return nil }
        let delay = backoff[min(strikes, backoff.count - 1)]
        guard time - max(lastPeerOnline, lastAttempt) >= delay else { return nil }
        lastAttempt = time
        strikes += 1
        return delay
    }
}
