import XCTest
@testable import tandemclip

/// The point of a source identity is that it can be *trusted without being
/// re-derived*. That only holds if everything short of a full, lowercase, hex
/// SHA is rejected outright — a value that looks like identity and is not gets
/// quoted as proof, which is worse than having none. These pin that boundary.
final class BuildIdentityTests: XCTestCase {
    private let realCommit = "c3eb2974fcb3789411a9e86c9fe2003b0723d9d4"

    func testAcceptsAFullLowercaseHexSHA() {
        XCTAssertTrue(BuildIdentity.isWellFormed(realCommit))
        XCTAssertTrue(BuildIdentity.isWellFormed(String(repeating: "0", count: 40)))
        XCTAssertTrue(BuildIdentity.isWellFormed(String(repeating: "f", count: 40)))
    }

    func testRejectsAbbreviatedOrOverlongSHAs() {
        // An abbreviation identifies a prefix, and prefixes collide as history
        // grows — identity that can become wrong later is not identity.
        XCTAssertFalse(BuildIdentity.isWellFormed("c3eb297"))
        XCTAssertFalse(BuildIdentity.isWellFormed(String(realCommit.dropLast())))
        XCTAssertFalse(BuildIdentity.isWellFormed(realCommit + "a"))
    }

    func testRejectsUppercaseAndMixedCase() {
        // git rev-parse emits lowercase, so anything else came from elsewhere,
        // and accepting both spellings makes one commit two release names.
        XCTAssertFalse(BuildIdentity.isWellFormed(realCommit.uppercased()))
        XCTAssertFalse(BuildIdentity.isWellFormed("C3eb2974fcb3789411a9e86c9fe2003b0723d9d4"))
    }

    func testRejectsNonHexAndPlaceholders() {
        XCTAssertFalse(BuildIdentity.isWellFormed(""))
        XCTAssertFalse(BuildIdentity.isWellFormed("unknown"))
        XCTAssertFalse(BuildIdentity.isWellFormed("HEAD"))
        XCTAssertFalse(BuildIdentity.isWellFormed(String(repeating: "z", count: 40)))
        // Right length, one character out of alphabet — the near-miss a sloppy
        // length-only check would wave through.
        XCTAssertFalse(BuildIdentity.isWellFormed(String(realCommit.dropLast()) + "g"))
        // Non-ASCII digits satisfy Character.isNumber but are not hex.
        XCTAssertFalse(BuildIdentity.isWellFormed(String(realCommit.dropLast()) + "٤"))
    }

    func testCommitIsReadFromInfoDictionaryAndTrimmed() {
        XCTAssertEqual(
            BuildIdentity.commit(from: [BuildIdentity.infoKey: "  \(realCommit)\n"]),
            realCommit
        )
    }

    func testCommitIsNilWhenMissingEmptyOrMalformed() {
        // The tracked Packaging/Info.plist ships this key empty, so a dev build
        // must report *no* identity rather than an empty-string one.
        XCTAssertNil(BuildIdentity.commit(from: [:]))
        XCTAssertNil(BuildIdentity.commit(from: nil))
        XCTAssertNil(BuildIdentity.commit(from: [BuildIdentity.infoKey: ""]))
        XCTAssertNil(BuildIdentity.commit(from: [BuildIdentity.infoKey: "c3eb297"]))
        XCTAssertNil(BuildIdentity.commit(from: [BuildIdentity.infoKey: realCommit.uppercased()]))
        XCTAssertNil(BuildIdentity.commit(from: [BuildIdentity.infoKey: 42]))
    }

    func testEventReleaseCarriesTheCommitAfterTheBuildNumber() {
        XCTAssertEqual(
            BuildIdentity.eventRelease(version: "0.25.0", build: "62", commit: realCommit),
            "com.tandemclip@0.25.0+62.\(realCommit)"
        )
    }

    func testEventReleaseFallsBackRatherThanInventingAnIdentity() {
        // An unidentified build must be *visibly* unidentified in Crashbox, not
        // decorated with a placeholder that reads like a revision.
        let bare = "com.tandemclip@0.25.0+62"
        XCTAssertEqual(BuildIdentity.eventRelease(version: "0.25.0", build: "62", commit: nil), bare)
        XCTAssertEqual(BuildIdentity.eventRelease(version: "0.25.0", build: "62", commit: "unknown"), bare)
        XCTAssertEqual(BuildIdentity.eventRelease(version: "0.25.0", build: "62", commit: "c3eb297"), bare)
    }

    /// The tracked plist must keep the key present and empty: present so the
    /// injection has something to Set, empty so no revision is ever committed
    /// and then shipped as though it described the build.
    func testTrackedInfoPlistDeclaresTheKeyAndLeavesItEmpty() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // tandemclipTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Packaging/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        let value = try XCTUnwrap(parsed?[BuildIdentity.infoKey] as? String,
                                 "Packaging/Info.plist must declare \(BuildIdentity.infoKey)")
        XCTAssertTrue(value.isEmpty, "the tracked plist must not carry a baked commit")
    }
}
