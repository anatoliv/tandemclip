import XCTest
import Sentry
@testable import tandemclip

final class CrashReportingTests: XCTestCase {
    func testAcceptsOneHTTPSCrashboxDSN() {
        let value = "https://public-key@ingest.crashbox.dev/6bb1b202-8b83-4ec4-9151-f4ef7548e544"
        XCTAssertEqual(
            CrashReporting.dsn(from: [CrashReporting.infoKey: "  \(value)\n"]),
            value
        )
        XCTAssertEqual(CrashReporting.collectorHost, "ingest.crashbox.dev")
    }

    func testOnlyTheCrashboxIngestHostIsAccepted() {
        let rejected = [
            "https://public-key@crashbox.example.test/project",
            "https://public-key@app.crashbox.dev/project",
            "https://public-key@crashbox.dev/project",
            "https://public-key@ingest.crashbox.dev.evil.example/project",
            "https://public-key@evil-ingest.crashbox.dev/project",
            "https://public-key@ingest.crashbox.dev:8443/project",
            "https://public-key@ingest.crashbox.dev:443/project",
        ]
        for value in rejected {
            XCTAssertNil(
                CrashReporting.dsn(from: [CrashReporting.infoKey: value]),
                "unexpectedly accepted: \(value)"
            )
        }
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
            "http://public-key@ingest.crashbox.dev/project",
            "https://ingest.crashbox.dev/project",
            "https://public-key:secret@ingest.crashbox.dev/project",
            "https://public-key@/project",
            "https://public-key@ingest.crashbox.dev/",
            "https://public-key@ingest.crashbox.dev/project/",
            "https://public-key@ingest.crashbox.dev/one/two",
            "https://public-key@ingest.crashbox.dev/project?fallback=hosted",
            "https://public-key@ingest.crashbox.dev/project#fragment",
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
        XCTAssertLessThanOrEqual(CrashReporting.resourceTimeout, 5)
        XCTAssertLessThanOrEqual(CrashReporting.shutdownTimeout, 0.25)

        let configuration = CrashReporting.transportConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, CrashReporting.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, CrashReporting.resourceTimeout)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testReleaseEnvironmentIsPersistedInTheNativeCrashScope() {
        let options = Options()
        CrashReporting.configure(
            options,
            dsn: "https://public-key@ingest.crashbox.dev/6bb1b202-8b83-4ec4-9151-f4ef7548e544",
            environment: "production"
        )

        XCTAssertEqual(options.environment, "production")
        let scope = options.initialScope(Scope())
        XCTAssertEqual(scope.serialize()["environment"] as? String, "production")
        XCTAssertFalse(options.sendClientReports)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertFalse(options.enableAutoPerformanceTracing)
        XCTAssertFalse(options.enableAppHangTracking)
        XCTAssertFalse(options.enableWatchdogTerminationTracking)
        XCTAssertFalse(options.enableMetricKit)
        XCTAssertFalse(options.enableMetricKitRawPayload)
    }

    func testNativeVerificationCrashNeedsTheExactGateAndARunningReporter() {
        func decide(_ request: String?, active: Bool = true,
                    outcome: ReportingAttemptGate.Outcome = .started,
                    sdkEnabled: Bool = true) -> CrashReporting.NativeTestCrash {
            CrashReporting.nativeTestCrash(request: request, reportingActive: active,
                                           outcome: outcome, sdkEnabled: sdkEnabled)
        }
        XCTAssertEqual(decide("1"), .crash)
        XCTAssertEqual(decide(nil), .notRequested)
        XCTAssertEqual(decide("true"), .notRequested)
        guard case .refused = decide("1", active: false) else { return XCTFail("inactive reporting crashed") }
        for outcome: ReportingAttemptGate.Outcome in [.idle, .starting, .failed] {
            guard case .refused(let reason) = decide("1", outcome: outcome) else {
                return XCTFail("a start that is \(outcome) crashed")
            }
            XCTAssertTrue(reason.contains("did not start"), reason)
        }
        guard case .refused(let reason) = decide("1", sdkEnabled: false) else {
            return XCTFail("a recorded start with the SDK disabled crashed")
        }
        XCTAssertTrue(reason.contains("not running"), reason)
    }

    /// The real request path in this process, where the reporter never started:
    /// it must refuse and never call the crash.
    func testNativeTestCrashRequestRefusesWhenTheReporterDidNotStart() {
        final class Crashed: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            func get() -> Bool { lock.withLock { value } }
        }
        let crashed = Crashed()
        let decided = expectation(description: "decided")
        var decision: CrashReporting.NativeTestCrash?
        CrashReporting.requestNativeTestCrash(request: "1", crash: { crashed.set() }) {
            decision = $0
            decided.fulfill()
        }
        wait(for: [decided], timeout: 5)
        guard case .refused = decision else { return XCTFail("expected a refusal, got \(String(describing: decision))") }
        // A crash is scheduled one second after the decision; give it time to show.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settle.fulfill() }
        wait(for: [settle], timeout: 3)
        XCTAssertFalse(crashed.get())
    }

    // MARK: Never in tests

    func testThisProcessIsRecognisedAsATestRun() {
        XCTAssertTrue(CrashReporting.isTesting)
    }

    func testStartIsRefusedInsideTestsEvenWhenEnabledAndConfigured() {
        let dsn = "https://public-key@ingest.crashbox.dev/project"
        XCTAssertTrue(CrashReporting.shouldStart(enabled: true, dsn: dsn, isTesting: false))
        XCTAssertFalse(CrashReporting.shouldStart(enabled: true, dsn: dsn, isTesting: true))
        XCTAssertFalse(CrashReporting.shouldStart(enabled: false, dsn: dsn, isTesting: false))
        XCTAssertFalse(CrashReporting.shouldStart(enabled: true, dsn: nil, isTesting: false))
        // The real entry point, with this process's own test detection: opted in
        // and given a usable DSN, it still queues no start.
        XCTAssertFalse(CrashReporting.start(enabled: true, dsn: dsn))
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
        XCTAssertTrue(makeApp.contains("TANDEMCLIP_REPORTING_DISABLED_ROLLBACK"))
        XCTAssertTrue(makeApp.contains("a reporting-disabled rollback must not carry a Crashbox DSN"))
        XCTAssertTrue(release.contains("REQUIRE_CRASHBOX=\"$BUILD_REQUIRES_CRASHBOX\""))
        XCTAssertTrue(release.contains("CRASHBOX_ARTIFACT_RECEIPT_FILE"))
        XCTAssertTrue(release.contains("TANDEMCLIP_CRASHBOX_PROJECT_ID"))
        XCTAssertTrue(release.contains("verify-crashbox-artifact-receipt.py"))
        XCTAssertTrue(release.contains("PREPARE_RELEASE"))
        XCTAssertTrue(release.contains("RESUME_PREPARED_RELEASE"))
        XCTAssertTrue(release.contains("prepared-release.py"))
        XCTAssertTrue(release.contains("Scripts/package-dsym.sh"))
        XCTAssertTrue(release.contains("Scripts/dsym-member.py"))
        XCTAssertFalse(release.contains("--sequesterRsrc"))
        XCTAssertTrue(release.contains("--release \"$EVENT_RELEASE\""))
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

        func run(dsn: String?, requireCrashbox: Bool, rollback: Bool = false) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script]
            var environment = ProcessInfo.processInfo.environment
            environment["VERIFY_CRASHBOX_INPUT_ONLY"] = "1"
            environment["TANDEMCLIP_CRASHBOX_CONFIG_FILE"] = absent
            environment["REQUIRE_CRASHBOX"] = requireCrashbox ? "1" : "0"
            environment["TANDEMCLIP_REPORTING_DISABLED_ROLLBACK"] = rollback ? "1" : "0"
            if rollback {
                environment["IDENTITY"] = "Developer ID Application: Test (ABCDEFGHIJ)"
                environment["ALLOW_DIRTY_IDENTITY"] = "1"
            }
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

        for otherHost in ["crashbox.example.test", "app.crashbox.dev", "ingest.crashbox.dev.evil.example"] {
            let wrongHost = try run(dsn: "https://public@\(otherHost)/project", requireCrashbox: true)
            XCTAssertNotEqual(wrongHost.0, 0, "accepted \(otherHost)")
            XCTAssertTrue(wrongHost.1.contains("unsafe or malformed"), wrongHost.1)
        }

        let configured = try run(
            dsn: "https://public-key@ingest.crashbox.dev/6bb1b202-8b83-4ec4-9151-f4ef7548e544",
            requireCrashbox: true
        )
        XCTAssertEqual(configured.0, 0)
        XCTAssertTrue(configured.1.contains("crashbox"))

        let rollback = try run(dsn: nil, requireCrashbox: false, rollback: true)
        XCTAssertEqual(rollback.0, 0)
        XCTAssertTrue(rollback.1.contains("reporting-disabled-rollback"))

        let rollbackWithDSN = try run(
            dsn: "https://public@ingest.crashbox.dev/project",
            requireCrashbox: false,
            rollback: true
        )
        XCTAssertNotEqual(rollbackWithDSN.0, 0)
        XCTAssertTrue(rollbackWithDSN.1.contains("must not carry a Crashbox DSN"))

        let rollbackCannotOverrideRelease = try run(
            dsn: nil,
            requireCrashbox: true,
            rollback: true
        )
        XCTAssertNotEqual(rollbackCannotOverrideRelease.0, 0)
        XCTAssertTrue(rollbackCannotOverrideRelease.1.contains("cannot use the rollback-only"))
    }
}
