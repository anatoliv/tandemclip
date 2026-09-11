import XCTest
@testable import tandemclip

final class CrashReportingTests: XCTestCase {
    func testAcceptsOneHTTPSCrashboxDSN() {
        let value = "https://public-key@crashbox.example.test/6bb1b202-8b83-4ec4-9151-f4ef7548e544"
        XCTAssertEqual(
            CrashReporting.dsn(from: [CrashReporting.infoKey: "  \(value)\n"]),
            value
        )
    }

    func testMissingEmptyAndNonStringConfigurationMeanReportingDisabled() {
        XCTAssertNil(CrashReporting.dsn(from: nil))
        XCTAssertNil(CrashReporting.dsn(from: [:]))
        XCTAssertNil(CrashReporting.dsn(from: [CrashReporting.infoKey: " \n"]))
        XCTAssertNil(CrashReporting.dsn(from: [CrashReporting.infoKey: 42]))
    }

    func testRejectsMalformedOrUnsafeEndpointsBeforeSDKStartup() {
        let rejected = [
            "not a URL",
            "http://public-key@crashbox.example.test/project",
            "https://crashbox.example.test/project",
            "https://public-key:secret@crashbox.example.test/project",
            "https://public-key@/project",
            "https://public-key@crashbox.example.test/",
            "https://public-key@crashbox.example.test/project/",
            "https://public-key@crashbox.example.test/one/two",
            "https://public-key@crashbox.example.test/project?fallback=hosted",
            "https://public-key@crashbox.example.test/project#fragment",
            "https://public-key@o123.ingest.sentry.io/project",
        ]

        for value in rejected {
            XCTAssertNil(
                CrashReporting.dsn(from: [CrashReporting.infoKey: value]),
                "unexpectedly accepted: \(value)"
            )
        }
    }

    func testFailureBudgetsStaySmallAndFinite() {
        XCTAssertEqual(CrashReporting.maximumCachedEnvelopes, 10)
        XCTAssertLessThanOrEqual(CrashReporting.requestTimeout, 5)
        XCTAssertLessThanOrEqual(CrashReporting.resourceTimeout, 10)
        XCTAssertLessThanOrEqual(CrashReporting.shutdownTimeout, 0.25)

        let configuration = CrashReporting.transportConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, CrashReporting.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, CrashReporting.resourceTimeout)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTrackedInfoPlistDeclaresCrashboxOnlyAndNoSecret() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Packaging/Info.plist"))
        let parsed = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(parsed[CrashReporting.infoKey] as? String, "")
        XCTAssertNil(parsed["SentryDSN"], "hosted-provider fallback must not remain in the bundle")
    }

    func testBuildAndReleaseScriptsHaveNoHostedProviderFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let makeApp = try String(
            contentsOf: root.appendingPathComponent("Scripts/make-app.sh"),
            encoding: .utf8
        )
        let release = try String(
            contentsOf: root.appendingPathComponent("Scripts/release.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(makeApp.contains("TANDEMCLIP_CRASHBOX_DSN"))
        XCTAssertTrue(makeApp.contains("Packaging/crashbox-dsn.local"))
        XCTAssertTrue(makeApp.contains("Set :CrashboxDSN"))
        XCTAssertTrue(makeApp.contains("crashbox_dsn_is_valid"))
        XCTAssertTrue(makeApp.contains("a distributable release requires a protected Crashbox DSN"))
        XCTAssertTrue(release.contains("REQUIRE_CRASHBOX=\"${PUBLISH:-0}\""))
        for legacy in ["TANDEMCLIP_" + "SENTRY_DSN", "Packaging/" + "sentry-dsn.local", "Set :" + "SentryDSN"] {
            XCTAssertFalse(makeApp.contains(legacy), "legacy build input remains: \(legacy)")
        }
        for legacy in ["SENTRY_" + "AUTH_TOKEN", "sentry-" + "cli", "debug-files " + "upload"] {
            XCTAssertFalse(release.contains(legacy), "hosted symbol upload remains: \(legacy)")
        }
    }

    func testReleaseInputGuardFailsClosedBeforeBuilding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/make-app.sh").path
        let absent = root.appendingPathComponent(".build/test-missing-crashbox-input").path

        func run(dsn: String?, requireCrashbox: Bool) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script]
            var environment = ProcessInfo.processInfo.environment
            environment["VERIFY_CRASHBOX_INPUT_ONLY"] = "1"
            environment["TANDEMCLIP_CRASHBOX_CONFIG_FILE"] = absent
            environment["REQUIRE_CRASHBOX"] = requireCrashbox ? "1" : "0"
            if let dsn {
                environment["TANDEMCLIP_CRASHBOX_DSN"] = dsn
            } else {
                environment.removeValue(forKey: "TANDEMCLIP_CRASHBOX_DSN")
            }
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return (process.terminationStatus, text)
        }

        let disabled = try run(dsn: nil, requireCrashbox: false)
        XCTAssertEqual(disabled.0, 0)
        XCTAssertTrue(disabled.1.contains("disabled"))

        let missing = try run(dsn: nil, requireCrashbox: true)
        XCTAssertNotEqual(missing.0, 0)
        XCTAssertTrue(missing.1.contains("requires a protected Crashbox DSN"))

        let malformed = try run(dsn: "https://public@sentry.io/project", requireCrashbox: true)
        XCTAssertNotEqual(malformed.0, 0)
        XCTAssertTrue(malformed.1.contains("unsafe or malformed"))

        let configured = try run(
            dsn: "https://public-key@ingest.crashbox.dev/6bb1b202-8b83-4ec4-9151-f4ef7548e544",
            requireCrashbox: true
        )
        XCTAssertEqual(configured.0, 0)
        XCTAssertTrue(configured.1.contains("crashbox"))
    }
}
