import XCTest
@testable import tandemclip

/// The automatic reconnect watchdog decides when to tear down and rebuild the
/// LAN transport. Getting it wrong is expensive in both directions — too eager
/// and it churns healthy connections, too shy and sync stays dead until the user
/// clicks Reconnect — so the policy is pinned here rather than only exercised by
/// slow live runs.
final class ReconnectWatchdogTests: XCTestCase {
    private let ladder: [Double] = [60, 120, 300, 900]

    /// The safety property that matters most: a Mac that has never synced with
    /// anyone (solo, or partner switched off) must never rebuild its transport,
    /// no matter how long it sits there with no peers.
    func testNeverFiresBeforeTheFirstSuccessfulSync() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.noteStarted(at: 0)
        for t in stride(from: 0.0, through: 100_000, by: 500) {
            XCTAssertNil(wd.shouldRebuild(at: t, anyPeerOnline: false),
                         "fired at t=\(t) despite never having synced")
        }
    }

    func testDoesNotFireWhileAPeerIsConnected() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.noteStarted(at: 0)
        wd.notePeerOnline(at: 10)
        XCTAssertNil(wd.shouldRebuild(at: 100_000, anyPeerOnline: true))
    }

    /// Losing a peer isn't itself a fault — it must stay quiet for the first
    /// backoff step before rebuilding.
    func testWaitsTheFirstBackoffStepAfterLosingAPeer() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.notePeerOnline(at: 1_000)
        XCTAssertNil(wd.shouldRebuild(at: 1_059, anyPeerOnline: false))
        XCTAssertEqual(wd.shouldRebuild(at: 1_060, anyPeerOnline: false), 60)
    }

    /// Repeated failures escalate through the ladder and then hold at its
    /// ceiling, so a permanently-absent peer costs one rebuild every 15 min.
    func testBackoffEscalatesThenCapsAtTheLastStep() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.notePeerOnline(at: 0)
        var t: Double = 0
        var fired: [Double] = []
        for step in ladder + [900, 900] {
            t += step
            guard let delay = wd.shouldRebuild(at: t, anyPeerOnline: false) else {
                return XCTFail("expected a rebuild at t=\(t)")
            }
            fired.append(delay)
        }
        XCTAssertEqual(fired, [60, 120, 300, 900, 900, 900])
    }

    /// Each attempt restarts the idle clock: the gap is measured from the last
    /// attempt, not from when the peer was lost, so attempts can't bunch up.
    func testIdleClockRestartsFromTheLastAttempt() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.notePeerOnline(at: 0)
        XCTAssertEqual(wd.shouldRebuild(at: 60, anyPeerOnline: false), 60)
        // Second step is 120s and is counted from t=60, not from t=0.
        XCTAssertNil(wd.shouldRebuild(at: 179, anyPeerOnline: false))
        XCTAssertEqual(wd.shouldRebuild(at: 180, anyPeerOnline: false), 120)
    }

    /// A peer returning means the transport works again — the next outage must
    /// start from the fast end of the ladder, not wherever it left off.
    func testRecoveryResetsTheBackoff() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.notePeerOnline(at: 0)
        XCTAssertEqual(wd.shouldRebuild(at: 60, anyPeerOnline: false), 60)
        XCTAssertEqual(wd.shouldRebuild(at: 180, anyPeerOnline: false), 120)
        wd.notePeerOnline(at: 200)
        XCTAssertEqual(wd.strikes, 0)
        XCTAssertNil(wd.shouldRebuild(at: 259, anyPeerOnline: false))
        XCTAssertEqual(wd.shouldRebuild(at: 260, anyPeerOnline: false), 60)
    }

    /// A manual Reconnect buys the same grace the watchdog gives itself, so the
    /// watchdog doesn't immediately rebuild on top of the user's attempt — but it
    /// must not reset the ladder, or repeated clicking would keep it at 60s.
    func testManualAttemptDefersTheWatchdogWithoutResettingTheLadder() {
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.notePeerOnline(at: 0)
        XCTAssertEqual(wd.shouldRebuild(at: 60, anyPeerOnline: false), 60)
        wd.noteAttempt(at: 100)                        // user clicks Reconnect
        XCTAssertEqual(wd.strikes, 1, "manual attempt must not reset the ladder")
        XCTAssertNil(wd.shouldRebuild(at: 219, anyPeerOnline: false))
        XCTAssertEqual(wd.shouldRebuild(at: 220, anyPeerOnline: false), 120)
    }

    /// Regression: `lastPeerOnline` defaults to 0, which reads as "idle since
    /// 1970". If `everSynced` is ever seeded from persisted state without
    /// seeding the clock too, the first tick would fire instantly — before
    /// discovery has had any chance to find anyone.
    func testStartSeedsTheIdleClockSoLaunchIsNotAnInstantFault() {
        let launch: Double = 1_800_000_000   // a realistic epoch timestamp
        var wd = ReconnectWatchdog(backoff: ladder)
        wd.noteStarted(at: launch)
        wd.notePeerOnline(at: launch)
        wd.notePeerOnline(at: launch)        // still connected; clock keeps moving
        XCTAssertNil(wd.shouldRebuild(at: launch + 1, anyPeerOnline: false))
        XCTAssertEqual(wd.lastPeerOnline, launch)
    }
}
