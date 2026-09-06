import XCTest
@testable import tandemclip

/// Privacy hold is settable from two places: the picker's ✋ button and the
/// menu-bar item. Config is the single source of truth, and the picker re-reads
/// it via `ClipboardPickerController.syncPrivacyHold()` on `Config.didChange`.
///
/// That design rests on one property of PickerModel: assigning `privacyHold`
/// notifies nobody, while `togglePrivacy()` does. If assignment ever started
/// firing `onPrivacyChange`, the re-seed would write config back to config in a
/// loop, and a user's toggle could be undone by the notification it caused.
/// Nothing else in the suite pins that, so it is pinned here.
final class PickerModelPrivacySyncTests: XCTestCase {

    private func makeModel() -> PickerModel {
        PickerModel(onPickHistory: { _ in }, onPullPeer: { _ in }, onDropFiles: { _ in },
                    onDeleteHistory: { _ in }, onClose: {})
    }

    /// The user acting on the ✋ must notify the owner, which is what persists
    /// the choice to config.
    func testTogglePrivacyNotifiesOwner() {
        let m = makeModel()
        var observed: [Bool] = []
        m.onPrivacyChange = { (on: Bool) in observed.append(on) }

        m.togglePrivacy()
        XCTAssertTrue(m.privacyHold)
        m.togglePrivacy()
        XCTAssertFalse(m.privacyHold)

        XCTAssertEqual(observed, [true, false], "togglePrivacy must report each change to the owner")
    }

    /// Re-seeding from config must NOT notify, or syncPrivacyHold would loop
    /// config -> model -> config.
    func testAssigningPrivacyHoldDoesNotNotify() {
        let m = makeModel()
        var notified = false
        m.onPrivacyChange = { (_: Bool) in notified = true }

        m.privacyHold = true
        m.privacyHold = false

        XCTAssertFalse(notified, "assignment is the re-seed path and must stay silent")
    }

    /// The state the menu bar would produce and the state the picker shows must
    /// agree after a re-seed, including when the picker was built with the
    /// opposite value.
    func testReseedAdoptsExternalChange() {
        let m = makeModel()
        m.privacyHold = false          // panel built while sharing
        m.onPrivacyChange = { (_: Bool) in XCTFail("re-seed must not report a user action") }

        // Menu bar turned it on; the picker re-reads config.
        let configValue = true
        m.privacyHold = configValue

        XCTAssertTrue(m.privacyHold, "the picker must adopt a change made outside it")
    }

    /// The menu item's whole action is `config.privacyHold.toggle()`, and the
    /// picker only learns about it because that write posts `Config.didChange`
    /// (AppController's observer calls `syncPrivacyHold()` from there). If the
    /// notification ever stopped firing, the menu would still work and the
    /// picker would silently show the wrong state, which is the failure this
    /// pins. Nothing else in the suite asserts that post.
    func testTogglingConfigPrivacyHoldPersistsAndPostsDidChange() {
        let config = Config()
        let original = config.privacyHold
        defer { config.privacyHold = original }

        let posted = expectation(description: "Config.didChange after a privacy-hold write")
        posted.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: Config.didChange, object: nil, queue: .main) { _ in posted.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        config.privacyHold.toggle()

        XCTAssertEqual(config.privacyHold, !original,
                       "the menu action's write must round-trip through defaults")
        wait(for: [posted], timeout: 2)
    }
}
