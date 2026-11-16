import XCTest

// Lints the release plumbing (workflows, scripts, .gitignore) through the real files.
// The scripts the workflows delegate to are run for real; the only fake is the GitHub CLI,
// the system boundary that must never be reached from a test.

// MARK: - Workflow lint

final class ReleaseWorkflowTests: XCTestCase {
    private let signingSecrets = ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"]
    private let notarizationSecrets = ["APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"]

    func testSecretsAreNotInTheJobOrWorkflowEnvironment() throws {
        let release = try Workflow("release.yml")

        XCTAssertNil(release.header.range(of: #"\$\{\{[^}]*\bsecrets\."#, options: .regularExpression),
                     "A secret in job-level env is visible to every step, third-party actions included")
    }

    func testEachSecretReachesOnlyTheStepThatNeedsIt() throws {
        let release = try Workflow("release.yml")

        let sign = try release.step("Sign with certificate")
        let notarize = try release.step("Notarize")
        XCTAssertEqual(Set(sign.secretValues), Set(signingSecrets))
        XCTAssertEqual(Set(notarize.secretValues), Set(notarizationSecrets))
        for step in release.steps where step.name != sign.name && step.name != notarize.name {
            XCTAssertTrue(step.secretValues.isEmpty, "\(step.name) must not receive secret values: \(step.secretValues)")
        }
    }

    func testTheGitHubTokenIsNotHandedToEveryStep() throws {
        let release = try Workflow("release.yml")

        XCTAssertNil(release.header.range(of: #"\$\{\{[^}]*\bgithub\.token"#, options: .regularExpression),
                     "The job token can write releases; only the steps that call GitHub should get it")
    }

    func testEveryActionIsPinnedToACommitWithAVersionComment() throws {
        for file in ["build.yml", "release.yml"] {
            let workflow = try Workflow(file)
            let actions = workflow.steps.compactMap(\.uses)
            XCTAssertFalse(actions.isEmpty, file)
            for step in workflow.steps {
                guard let uses = step.uses else { continue }
                XCTAssertNotNil(uses.range(of: #"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$"#, options: .regularExpression),
                                "\(file): \(uses) must be pinned to a full commit SHA; a tag such as v4 can be moved, GitHub's own actions included")
                XCTAssertNotNil(step.text.range(of: #"uses:\s*\S+@[0-9a-f]{40}\s+# v\d+\.\d+\.\d+"#, options: .regularExpression),
                                "\(file): \(uses) needs an exact version comment (# v1.2.3) so the pin can be reviewed")
            }
        }
    }

    func testTheReleaseJobRunsOneAtATimeAndNeverCancelsARunHalfwayThroughPublishing() throws {
        let release = try Workflow("release.yml")

        XCTAssertTrue(release.header.contains("\n    concurrency:\n      group: release\n      cancel-in-progress: false\n"),
                      "two releases must queue, and cancelling mid-notarization could leave a tag without its asset")
    }

    func testEveryJobHasATimeoutSoAStuckStepCannotRunForSixHours() throws {
        for file in ["build.yml", "release.yml"] {
            let header = try Workflow(file).header
            let minutes = captures(#"\n    timeout-minutes: (\d+)\n"#, in: header).first?.first.flatMap(Int.init)
            XCTAssertNotNil(minutes, "\(file) needs a job-level timeout-minutes")
            XCTAssertLessThanOrEqual(minutes ?? .max, 120, file)
        }
    }

    func testNotarizationIsBoundedSoTheStepCannotWaitForeverOnApple() throws {
        let notarize = try Workflow("release.yml").step("Notarize")

        XCTAssertTrue(notarize.text.contains("--wait --timeout 30m"), notarize.text)
    }

    func testXcodeGenIsInstalledAtAPinnedVersionNotWhateverHomebrewHasToday() throws {
        for file in ["build.yml", "release.yml"] {
            let workflow = try Workflow(file)
            let install = try workflow.step("Install XcodeGen")

            XCTAssertTrue(install.text.contains("scripts/install-xcodegen.sh"), file)
            XCTAssertFalse(workflow.text.contains("brew install xcodegen"), "\(file): an unpinned install can change what ships")
        }
    }

    func testTheReleaseJobUsesTheProtectedReleaseEnvironment() throws {
        let release = try Workflow("release.yml")

        XCTAssertTrue(release.header.contains("\n    environment: release\n"))
    }

    func testManualReleasesCanOnlyRunFromMain() throws {
        let release = try Workflow("release.yml")

        XCTAssertTrue(release.header.contains("\n    if: github.ref == 'refs/heads/main'\n"))
    }

    func testWorkflowsDefaultToReadOnlyPermissions() throws {
        for file in ["build.yml", "release.yml"] {
            let workflow = try Workflow(file)
            XCTAssertTrue(workflow.text.contains("\npermissions:\n  contents: read\n"),
                          "\(file) needs a workflow-level read-only permissions block")
        }
        let build = try Workflow("build.yml")
        XCTAssertFalse(build.text.contains(": write"), "The build workflow never needs write access")
    }

    func testOnlyTheReleaseJobCanWriteContents() throws {
        let release = try Workflow("release.yml")

        XCTAssertTrue(release.header.contains("\n    permissions:\n      contents: write\n"))
    }

    func testCheckoutDoesNotLeaveCredentialsOnDisk() throws {
        for file in ["build.yml", "release.yml"] {
            let checkout = try XCTUnwrap(try Workflow(file).steps.first { $0.uses?.hasPrefix("actions/checkout@") == true })
            XCTAssertTrue(checkout.text.contains("persist-credentials: false"), file)
        }
    }

    func testReleaseBuildIsStampedWithTheVersionFromTheTag() throws {
        let release = try Workflow("release.yml")

        let resolve = try release.step("Resolve version")
        XCTAssertTrue(resolve.text.contains("scripts/release-resolve-version.sh"))
        let build = try release.step("Build (Release)")
        XCTAssertTrue(build.text.contains(#"MARKETING_VERSION="$APP_VERSION""#))
        XCTAssertTrue(build.text.contains(#"CURRENT_PROJECT_VERSION="$APP_BUILD""#))
        XCTAssertTrue(build.text.contains("steps.ver.outputs.marketing"))
        XCTAssertTrue(build.text.contains("steps.ver.outputs.build"))
    }

    func testTheBuiltBundleVersionIsCheckedBeforePublishing() throws {
        let release = try Workflow("release.yml")

        let build = try release.indexOfStep("Build (Release)")
        let verify = try release.indexOfStep("Verify bundle version")
        let publish = try release.indexOfStep("Publish release")
        XCTAssertLessThan(build, verify)
        XCTAssertLessThan(verify, publish)
        XCTAssertTrue(release.steps[verify].text.contains("CFBundleShortVersionString"))
    }

    func testSigningModeIsDecidedBeforeAnythingIsBuilt() throws {
        let release = try Workflow("release.yml")

        let check = try release.step("Check signing secrets")
        XCTAssertLessThan(try release.indexOfStep("Check signing secrets"), try release.indexOfStep("Build (Release)"))
        XCTAssertTrue(check.text.contains("scripts/release-check-signing.sh"))
        for secret in signingSecrets + notarizationSecrets {
            XCTAssertTrue(check.text.contains("HAVE_\(secret): ${{ secrets.\(secret) != '' }}"),
                          "The check should see whether \(secret) is set, never its value")
        }
        XCTAssertTrue(check.secretValues.isEmpty)
    }

    func testSigningAndNotarizationFollowTheCheckedMode() throws {
        let release = try Workflow("release.yml")

        XCTAssertTrue(try release.step("Sign with certificate").condition?.contains("steps.signing.outputs.mode != 'ad-hoc'") == true,
                      "signed and notarized builds both sign with the certificate")
        XCTAssertTrue(try release.step("Notarize").condition?.contains("steps.signing.outputs.mode == 'notarized'") == true,
                      "only the notarized mode has the Apple credentials to notarize")
        let adHoc = try release.step("Ad-hoc sign")
        XCTAssertTrue(adHoc.condition?.contains("steps.signing.outputs.mode == 'ad-hoc'") == true)
        XCTAssertFalse(adHoc.text.contains("env.MACOS_CERTIFICATE_P12"))
    }

    func testASignedBuildMustCarryACertificateTiedRequirementBeforeItIsPackaged() throws {
        let release = try Workflow("release.yml")

        let verify = try release.step("Verify stable code identity")
        XCTAssertTrue(verify.condition?.contains("steps.signing.outputs.mode != 'ad-hoc'") == true)
        XCTAssertTrue(verify.text.contains("codesign -d -r-"), verify.text)
        XCTAssertTrue(verify.text.contains("cdhash"), "a requirement tied to the code hash changes every build")
        XCTAssertLessThan(try release.indexOfStep("Sign with certificate"), try release.indexOfStep("Verify stable code identity"))
        XCTAssertLessThan(try release.indexOfStep("Verify stable code identity"), try release.indexOfStep("Package .app"))
    }

    func testSelfSignedCertificatesAreTrustedOnlyOnTheRunnerAndOnlyWhenCodesignWouldRefuseThem() throws {
        let sign = try Workflow("release.yml").step("Sign with certificate")

        XCTAssertTrue(sign.text.contains("identity_is_valid"), "trust is added only if the identity is not already valid")
        XCTAssertTrue(sign.text.contains("add-trusted-cert"), sign.text)
        XCTAssertTrue(sign.text.contains("remove-trusted-cert"), "the trust must not outlive the step")
        XCTAssertTrue(sign.text.contains("trap cleanup EXIT"))
    }

    func testReleaseNotesDescribeTheSigningModeAndNotarizationOutcomeActuallyUsed() throws {
        let notes = try Workflow("release.yml").step("Write release notes")

        XCTAssertTrue(notes.text.contains("steps.signing.outputs.mode"))
        XCTAssertTrue(notes.text.contains("steps.notarize.outputs.done"))
        XCTAssertTrue(notes.text.contains("scripts/release-notes.sh"))
    }

    func testReleaseNeverRebuildsAnExistingTag() throws {
        let release = try Workflow("release.yml")

        for name in ["Check signing secrets", "Build (Release)", "Sign with certificate", "Notarize", "Publish release"] {
            XCTAssertTrue(try release.step(name).condition?.contains("steps.existing.outputs.exists != 'true'") == true, name)
        }
    }

    func testTheExistingReleaseCheckLeavesTheDecisionToTheScriptSoNoFailureReadsAsNoRelease() throws {
        let check = try Workflow("release.yml").step("Check whether the release exists")

        XCTAssertTrue(check.text.contains("scripts/release-exists.sh"))
        XCTAssertFalse(check.text.contains("gh release view"), "any failure of that call used to count as 'no release'")
        XCTAssertTrue(check.text.contains("id: existing"))
        XCTAssertTrue(check.text.contains("TAG: ${{ steps.ver.outputs.tag }}"))
        XCTAssertTrue(check.text.contains("GH_REPO: ${{ github.repository }}"))
    }

    func testWorkflowsParseAsYAML() throws {
        for file in ["build.yml", "release.yml"] {
            let result = try Shell.run("/usr/bin/env", ["ruby", "-ryaml", "-e", "YAML.load_file(ARGV[0])", Repo.url(".github/workflows/\(file)").path],
                                       path: "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
            try XCTSkipIf(result.status == 127, "ruby is not available")
            XCTAssertEqual(result.status, 0, "\(file) does not parse: \(result.output)")
        }
    }

    func testActionlintAcceptsTheWorkflowsWhenInstalled() throws {
        let files = ["build.yml", "release.yml"].map { Repo.url(".github/workflows/\($0)").path }

        let result = try Shell.run("/usr/bin/env", ["actionlint"] + files, path: "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")

        try XCTSkipIf(result.status == 127, "actionlint is not installed")
        XCTAssertEqual(result.status, 0, result.output)
    }
}

// MARK: - Version and signing scripts

final class ReleaseScriptTests: XCTestCase {
    private func resolve(versionFile: String = "v0.2.1\n", inputTag: String? = nil) throws -> Shell.Outcome {
        let file = try Shell.makeTempDirectory(for: self).appendingPathComponent("VERSION")
        try versionFile.write(to: file, atomically: true, encoding: .utf8)
        var env: [String: String] = [:]
        if let inputTag { env["INPUT_TAG"] = inputTag }
        return try Shell.runScript("release-resolve-version.sh", args: [file.path], env: env)
    }

    func testTheTagComesFromTheVERSIONFile() throws {
        let result = try resolve(versionFile: "v1.4.2\n")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["tag"], "v1.4.2")
        XCTAssertEqual(result.outputs["marketing"], "1.4.2")
    }

    func testAnEmptyDispatchInputFallsBackToTheVERSIONFile() throws {
        let result = try resolve(versionFile: "v0.3.0\n", inputTag: "")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["tag"], "v0.3.0")
    }

    func testADispatchInputThatMatchesVERSIONIsAccepted() throws {
        let result = try resolve(versionFile: "v0.3.0\n", inputTag: "v0.3.0")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["tag"], "v0.3.0")
    }

    func testADispatchInputThatDisagreesWithVERSIONFailsNamingBoth() throws {
        let result = try resolve(versionFile: "v0.3.0\n", inputTag: "v0.4.0")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("v0.4.0"), result.output)
        XCTAssertTrue(result.output.contains("v0.3.0"), result.output)
        XCTAssertNil(result.outputs["tag"], "A failed check must not leave a tag for later steps")
    }

    func testMalformedTagsAreRejected() throws {
        XCTAssertEqual(try resolve(versionFile: "v0.2.1\n").status, 0, "A well-formed tag is the control for the rejections below")
        for bad in ["0.2.1", "v0.2", "v1.2.3-beta", "v01.2.3", "v1.2.3.4", "release", "v1.1000.0"] {
            XCTAssertNotEqual(try resolve(versionFile: "\(bad)\n").status, 0, "\(bad) in VERSION should be rejected")
            XCTAssertNotEqual(try resolve(versionFile: "\(bad)\n", inputTag: bad).status, 0, "\(bad) as the dispatch input should be rejected")
        }
    }

    func testTheBuildNumberIncreasesWithEveryRelease() throws {
        let versions = ["v0.2.1", "v0.2.2", "v0.2.10", "v0.3.0", "v0.10.0", "v1.0.0", "v1.0.1", "v1.2.0", "v2.0.0"]

        let builds = try versions.map { version -> Int in
            let result = try resolve(versionFile: "\(version)\n")
            XCTAssertEqual(result.status, 0, result.output)
            return try XCTUnwrap(Int(try XCTUnwrap(result.outputs["build"])), version)
        }

        XCTAssertEqual(builds, builds.sorted())
        XCTAssertEqual(Set(builds).count, builds.count, "Two releases must never share a build number")
    }

    // MARK: Signing mode

    private let allSecrets = ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY",
                              "APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"]

    private func checkSigning(present: [String]) throws -> Shell.Outcome {
        let env = Dictionary(uniqueKeysWithValues: allSecrets.map { ("HAVE_\($0)", present.contains($0) ? "true" : "false") })
        return try Shell.runScript("release-check-signing.sh", env: env)
    }

    private let certificateSecrets = ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"]
    private let appleSecrets = ["APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"]

    func testEverySigningAndNotarizationSecretMeansSignAndNotarize() throws {
        let result = try checkSigning(present: allSecrets)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "notarized")
    }

    func testTheThreeCertificateSecretsAloneMeanSignedButNotNotarized() throws {
        let result = try checkSigning(present: certificateSecrets)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "signed")
    }

    func testASignedSetupMissingACertificateSecretFailsNamingOnlyTheMissingOnes() throws {
        for missing in certificateSecrets {
            let result = try checkSigning(present: certificateSecrets.filter { $0 != missing })

            XCTAssertNotEqual(result.status, 0, "Without \(missing) the configuration is partial")
            XCTAssertNil(result.outputs["mode"])
            XCTAssertTrue(result.output.contains(missing), result.output)
            for present in certificateSecrets where present != missing {
                XCTAssertFalse(result.output.contains(present), "\(present) is set and should not be named: \(result.output)")
            }
        }
    }

    func testNoSecretsMeansAnAdHocBuild() throws {
        let result = try checkSigning(present: [])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "ad-hoc")
    }

    func testCertificateWithSomeButNotAllNotarizationSecretsFailsNamingTheMissingOnes() throws {
        let result = try checkSigning(present: certificateSecrets + ["APPLE_ID"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(result.outputs["mode"])
        for missing in ["APPLE_TEAM_ID", "APPLE_APP_PASSWORD"] {
            XCTAssertTrue(result.output.contains(missing), "\(missing) should be named: \(result.output)")
        }
        XCTAssertFalse(result.output.contains("MACOS_CERTIFICATE_P12"), "Only the missing secrets should be named")
        XCTAssertFalse(result.output.contains("APPLE_ID"), "Only the missing secrets should be named")
    }

    func testNotarizationSecretsWithoutACertificateFailsNamingTheMissingOnes() throws {
        let result = try checkSigning(present: ["APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"])

        XCTAssertNotEqual(result.status, 0)
        for missing in ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"] {
            XCTAssertTrue(result.output.contains(missing), "\(missing) should be named: \(result.output)")
        }
    }

    func testAnySingleMissingSecretFailsTheCheck() throws {
        for missing in allSecrets {
            let result = try checkSigning(present: allSecrets.filter { $0 != missing })

            XCTAssertNotEqual(result.status, 0, "Without \(missing) the configuration is partial")
            XCTAssertTrue(result.output.contains(missing), result.output)
        }
    }

    // MARK: Release notes

    private func notes(mode: String, notarized: String) throws -> Shell.Outcome {
        try Shell.runScript("release-notes.sh", args: [mode, notarized])
    }

    func testNotarizedReleasesAreDescribedAsSignedAndNotarized() throws {
        let result = try notes(mode: "notarized", notarized: "true")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Signed and notarized"))
        XCTAssertFalse(result.output.localizedCaseInsensitiveContains("ad-hoc"))
        XCTAssertFalse(result.output.contains("xattr"))
    }

    func testSignedBuildsAreNotCalledAdHocAndPromisePermissionsSurviveUpdates() throws {
        let result = try notes(mode: "signed", notarized: "")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Signed macOS build"), result.output)
        XCTAssertTrue(result.output.contains("not notarized"))
        XCTAssertTrue(result.output.contains("Gatekeeper still asks once"), result.output)
        XCTAssertTrue(result.output.contains("keeps your Screen Recording and Microphone permissions"), result.output)
        XCTAssertFalse(result.output.localizedCaseInsensitiveContains("again after each"))
        XCTAssertTrue(result.output.contains("xattr -dr com.apple.quarantine"), "Users still need the Gatekeeper workaround")
    }

    func testOnlyANotarizedModeThatReportedSuccessCanClaimNotarization() throws {
        XCTAssertNotEqual(try notes(mode: "notarized", notarized: "").status, 0, "the notarize step did not report success")
        XCTAssertNotEqual(try notes(mode: "signed", notarized: "true").status, 0)
        XCTAssertNotEqual(try notes(mode: "developer-id", notarized: "").status, 0, "the old mode name is gone")
    }

    func testAdHocReleasesCarryTheLaunchInstructions() throws {
        let result = try notes(mode: "ad-hoc", notarized: "")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Ad-hoc signed"))
        XCTAssertTrue(result.output.contains("xattr -dr com.apple.quarantine MeetingAssistant.app"))
        XCTAssertFalse(result.output.contains("Signed macOS build"))
    }

    func testAnAdHocBuildCanNeverBeDescribedAsNotarized() throws {
        XCTAssertEqual(try notes(mode: "ad-hoc", notarized: "").status, 0, "A valid combination is the control for the rejections below")
        XCTAssertNotEqual(try notes(mode: "ad-hoc", notarized: "true").status, 0)
        XCTAssertNotEqual(try notes(mode: "mystery", notarized: "").status, 0)
    }

    func testTheScriptsTheWorkflowsCallAreExecutable() throws {
        for name in ["release-resolve-version.sh", "release-check-signing.sh", "release-exists.sh", "release-notes.sh", "setup-release-signing.sh", "install-xcodegen.sh",
                     "make-self-signed-identity.sh", "verify-stable-signing-identity.sh"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Repo.url("scripts/\(name)").path), name)
        }
    }
}

// MARK: - Release existence check

final class ReleaseExistsScriptTests: XCTestCase {
    private let releaseLookup = "api repos/*/releases/tags/*"
    private let tagLookup = "api repos/*/git/ref/tags/*"

    private struct Check {
        let result: Shell.Outcome
        let calls: [String]
    }

    private func check(tag: String = "v1.2.3", release: FakeGitHub.Answer, tagRef: FakeGitHub.Answer = .notFound,
                       repo: String? = "acme/widgets") throws -> Check {
        let github = try FakeGitHub(for: self, rules: [(releaseLookup, release), (tagLookup, tagRef)])
        var env = github.environment
        env["GH_TOKEN"] = "fake-token"
        if let repo { env["GH_REPO"] = repo }
        let result = try Shell.runScript("release-exists.sh", args: [tag], env: env)
        return Check(result: result, calls: github.calls)
    }

    func testAPublishedReleaseMeansThereIsNothingToDo() throws {
        let outcome = try check(release: .ok)

        XCTAssertEqual(outcome.result.status, 0, outcome.result.output)
        XCTAssertEqual(outcome.result.outputs["exists"], "true")
        XCTAssertTrue(outcome.result.output.contains("v1.2.3"), "the notice names the release: \(outcome.result.output)")
    }

    func testNoReleaseAndNoTagMeansTheVersionIsFree() throws {
        let outcome = try check(release: .notFound, tagRef: .notFound)

        XCTAssertEqual(outcome.result.status, 0, outcome.result.output)
        XCTAssertEqual(outcome.result.outputs["exists"], "false")
    }

    func testOnlyANotFoundAnswerCountsAsNoRelease() throws {
        let answers: [FakeGitHub.Answer] = [
            .failure(code: 502, message: "Bad Gateway"),
            .failure(code: 503, message: "Service Unavailable"),
            .failure(code: 500, message: "Server Error"),
            .failure(code: 403, message: "API rate limit exceeded"),
            .failure(code: 401, message: "Bad credentials"),
        ]
        for answer in answers {
            let outcome = try check(release: answer)

            XCTAssertNotEqual(outcome.result.status, 0, "\(answer): a failed lookup must not read as 'no release'")
            XCTAssertNil(outcome.result.outputs["exists"], "\(answer): no verdict may be left for later steps")
            XCTAssertTrue(outcome.result.output.contains("::error::"), outcome.result.output)
        }
    }

    func testTheFailureNamesWhatGitHubSaid() throws {
        let outcome = try check(release: .failure(code: 502, message: "Bad Gateway"))

        XCTAssertTrue(outcome.result.output.contains("HTTP 502"), outcome.result.output)
        XCTAssertTrue(outcome.result.output.contains("v1.2.3"), outcome.result.output)
    }

    func testATagThatAlreadyExistsWithoutAReleaseFailsSoNewCodeIsNeverAttachedToAnOldTag() throws {
        let outcome = try check(release: .notFound, tagRef: .ok)

        XCTAssertNotEqual(outcome.result.status, 0)
        XCTAssertNil(outcome.result.outputs["exists"])
        XCTAssertTrue(outcome.result.output.contains("::error::"), outcome.result.output)
        XCTAssertTrue(outcome.result.output.contains("v1.2.3"), outcome.result.output)
        XCTAssertTrue(outcome.result.output.contains("tag"), outcome.result.output)
    }

    func testAnErrorLookingUpTheTagFailsToo() throws {
        let outcome = try check(release: .notFound, tagRef: .failure(code: 502, message: "Bad Gateway"))

        XCTAssertNotEqual(outcome.result.status, 0)
        XCTAssertNil(outcome.result.outputs["exists"])
    }

    func testTheTagIsOnlyLookedUpWhenThereIsNoRelease() throws {
        let outcome = try check(release: .ok, tagRef: .ok)

        XCTAssertEqual(outcome.result.status, 0, "a release with its tag is the normal state of a published version")
        XCTAssertEqual(outcome.calls.count, 1, outcome.calls.joined(separator: "\n"))
    }

    func testItAsksAboutTheExactTagInTheNamedRepository() throws {
        let outcome = try check(release: .notFound, tagRef: .notFound, repo: "someone/else")

        XCTAssertEqual(outcome.calls, ["gh api repos/someone/else/releases/tags/v1.2.3",
                                       "gh api repos/someone/else/git/ref/tags/v1.2.3"])
    }

    func testItOnlyReadsFromGitHub() throws {
        let outcome = try check(release: .notFound, tagRef: .notFound)

        XCTAssertFalse(outcome.calls.isEmpty)
        for call in outcome.calls {
            XCTAssertTrue(call.hasPrefix("gh api repos/"), call)
            XCTAssertFalse(call.contains("--method") || call.contains("-X"), "a check must never write: \(call)")
        }
    }

    func testAMalformedTagIsRefusedBeforeGitHubIsAsked() throws {
        for bad in ["", "1.2.3", "v1.2", "v1.2.3/../x", "v1.2.3 v1.2.4", "$(id)"] {
            let outcome = try check(tag: bad, release: .notFound)

            XCTAssertNotEqual(outcome.result.status, 0, "'\(bad)' should be refused")
            XCTAssertTrue(outcome.calls.isEmpty, "'\(bad)' must not reach the API path: \(outcome.calls)")
        }
    }

    func testTheRepositoryMustBeNamed() throws {
        let outcome = try check(release: .notFound, repo: nil)

        XCTAssertNotEqual(outcome.result.status, 0)
        XCTAssertTrue(outcome.calls.isEmpty)
    }
}

// MARK: - Pinned XcodeGen

final class InstallXcodeGenScriptTests: XCTestCase {
    private struct Install {
        let result: Shell.Outcome
        let destination: URL
        let pathAdditions: [String]
        let curlCalls: [String]
    }

    /// A release zip with the layout XcodeGen publishes (xcodegen/bin/xcodegen), whose binary reports `reports`.
    private func makeArchive(reports version: String) throws -> (zip: URL, sha256: String) {
        let work = try Shell.makeTempDirectory(for: self)
        let bin = work.appendingPathComponent("xcodegen/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = bin.appendingPathComponent("xcodegen")
        try "#!/bin/sh\necho 'Version: \(version)'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let zip = work.appendingPathComponent("xcodegen.zip")
        let made = try Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", work.appendingPathComponent("xcodegen").path, zip.path])
        XCTAssertEqual(made.status, 0, made.output)
        let digest = try Shell.run("/usr/bin/shasum", ["-a", "256", zip.path])
        return (zip, String(try XCTUnwrap(digest.output.split(separator: " ").first)))
    }

    /// Runs a copy of the script. `pin` rewrites its checksum to the fixture's, which is the only way to
    /// exercise the success path without the real release zip; nil keeps the real pin.
    private func install(serving archive: URL?, pin: String? = nil, curlFails: Bool = false) throws -> Install {
        let checkout = try Shell.makeTempDirectory(for: self)
        let bin = try Shell.makeTempDirectory(for: self)
        let destination = try Shell.makeTempDirectory(for: self).appendingPathComponent("xcodegen-install")
        let log = bin.appendingPathComponent("curl.log")
        let pathFile = bin.appendingPathComponent("github_path")
        FileManager.default.createFile(atPath: pathFile.path, contents: nil)

        var script = try Repo.text("scripts/install-xcodegen.sh")
        if let pin {
            script = script.replacingOccurrences(of: #"SHA256="[0-9a-f]{64}""#, with: "SHA256=\"\(pin)\"", options: .regularExpression)
        }
        let copy = checkout.appendingPathComponent("install-xcodegen.sh")
        try script.write(to: copy, atomically: true, encoding: .utf8)

        let curl = bin.appendingPathComponent("curl")
        try """
        #!/bin/bash
        echo "curl $*" >> "$CURL_LOG"
        [ -z "${CURL_FAILS:-}" ] || exit 22
        while [ $# -gt 0 ]; do
          if [ "$1" = "--output" ]; then cp "$FAKE_ARCHIVE" "$2"; fi
          shift
        done
        """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)

        var env = ["PATH": "\(bin.path):/usr/bin:/bin", "CURL_LOG": log.path, "GITHUB_PATH": pathFile.path]
        if let archive { env["FAKE_ARCHIVE"] = archive.path }
        if curlFails { env["CURL_FAILS"] = "1" }
        let result = try Shell.runBash(copy, args: [destination.path], env: env)
        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return Install(result: result, destination: destination, pathAdditions: lines(pathFile), curlCalls: lines(log))
    }

    func testTheScriptPinsAnExactVersionAndItsChecksum() throws {
        let script = try Repo.text("scripts/install-xcodegen.sh")

        XCTAssertNotNil(script.range(of: #"(?m)^VERSION="\d+\.\d+\.\d+"$"#, options: .regularExpression))
        XCTAssertNotNil(script.range(of: #"(?m)^SHA256="[0-9a-f]{64}"$"#, options: .regularExpression))
        XCTAssertTrue(script.contains("https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"))
    }

    func testAVerifiedDownloadIsUnpackedAndItsBinDirectoryPutOnThePath() throws {
        let archive = try makeArchive(reports: "2.45.3")

        let outcome = try install(serving: archive.zip, pin: archive.sha256)

        XCTAssertEqual(outcome.result.status, 0, outcome.result.output)
        let bin = outcome.destination.appendingPathComponent("xcodegen/bin").path
        XCTAssertEqual(outcome.pathAdditions, [bin])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin + "/xcodegen"))
    }

    func testItDownloadsOverHTTPSAndFailsOnHTTPErrors() throws {
        let archive = try makeArchive(reports: "2.45.3")

        let outcome = try install(serving: archive.zip, pin: archive.sha256)

        XCTAssertEqual(outcome.curlCalls.count, 1, outcome.curlCalls.joined(separator: "\n"))
        XCTAssertTrue(outcome.curlCalls[0].contains("--fail"), "an HTML error page must not be saved as the zip")
        XCTAssertTrue(outcome.curlCalls[0].contains(" https://github.com/yonaskolb/XcodeGen/releases/download/"), outcome.curlCalls[0])
    }

    func testADownloadThatDoesNotMatchThePinnedChecksumIsRejectedAndNeverReachesThePath() throws {
        let archive = try makeArchive(reports: "2.45.3")

        let outcome = try install(serving: archive.zip)

        XCTAssertNotEqual(outcome.result.status, 0)
        XCTAssertTrue(outcome.result.output.contains("checksum"), outcome.result.output)
        XCTAssertEqual(outcome.pathAdditions, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.destination.appendingPathComponent("xcodegen").path),
                       "an archive that failed its check must not be unpacked")
    }

    func testABinaryThatIsNotThePinnedVersionIsRejected() throws {
        let archive = try makeArchive(reports: "9.9.9")

        let outcome = try install(serving: archive.zip, pin: archive.sha256)

        XCTAssertNotEqual(outcome.result.status, 0)
        XCTAssertTrue(outcome.result.output.contains("9.9.9"), outcome.result.output)
        XCTAssertEqual(outcome.pathAdditions, [])
    }

    func testAFailedDownloadFailsTheStep() throws {
        let outcome = try install(serving: nil, curlFails: true)

        XCTAssertNotEqual(outcome.result.status, 0)
        XCTAssertEqual(outcome.pathAdditions, [])
    }
}

// MARK: - Signing setup script

final class SigningSetupScriptTests: XCTestCase {
    private let answers = ["p12-password", "Developer ID Application: Test (TEAMID)", "dev@example.com", "TEAMID", "app-password"]

    /// What the GitHub API says when the script looks for the "release" environment.
    private enum Environment {
        case missing
        case exists
        case unavailable
    }

    private struct Setup {
        let checkout: URL
        let elsewhere: URL
        let github: FakeGitHub
        var script: URL { checkout.appendingPathComponent("scripts/setup-release-signing.sh") }
        var p12: URL { elsewhere.appendingPathComponent("key.p12") }

        var ghCalls: [String] { github.calls }
        var secretWrites: [String] { ghCalls.filter { $0.hasPrefix("gh secret set") } }
        var environmentWrites: [String] { ghCalls.filter { $0.contains("--method") } }
    }

    private func makeSetup(origin: String?, environment: Environment = .missing) throws -> Setup {
        let checkout = try Shell.makeTempDirectory(for: self)
        let elsewhere = try Shell.makeTempDirectory(for: self)

        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Repo.url("scripts/setup-release-signing.sh"),
                                         to: checkout.appendingPathComponent("scripts/setup-release-signing.sh"))
        _ = try Shell.run("/usr/bin/git", ["init", "-q", checkout.path])
        if let origin {
            _ = try Shell.run("/usr/bin/git", ["-C", checkout.path, "remote", "add", "origin", origin])
        }
        try "certificate".write(to: elsewhere.appendingPathComponent("key.p12"), atomically: true, encoding: .utf8)

        let lookup = "api repos/*/environments/release"
        let rules: [(arguments: String, answer: FakeGitHub.Answer)] = switch environment {
        case .missing: [(lookup, .notFound)]
        case .exists: []
        case .unavailable: [(lookup, .failure(code: 502, message: "Bad Gateway"))]
        }
        return Setup(checkout: checkout, elsewhere: elsewhere, github: try FakeGitHub(for: self, rules: rules))
    }

    private func run(_ setup: Setup, args: [String]? = nil, typing lines: [String]) throws -> Shell.Outcome {
        try Shell.runBash(setup.script,
                          args: args ?? ["key.p12"],
                          env: setup.github.environment,
                          cwd: setup.elsewhere,
                          stdin: lines.joined(separator: "\n") + "\n")
    }

    func testItWritesToTheRepoOfItsOwnCheckoutNoMatterWhereItIsRun() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, typing: ["y"] + answers)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("acme/widgets"), "The target repo must be shown: \(result.output)")
        XCTAssertEqual(setup.secretWrites.count, 6)
        for write in setup.secretWrites {
            XCTAssertTrue(write.contains("--repo acme/widgets"), write)
        }
        XCTAssertEqual(Set(setup.secretWrites.compactMap { $0.split(separator: " ").dropFirst(3).first.map(String.init) }),
                       ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY",
                        "APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"])
    }

    func testSignedModeWritesOnlyTheThreeCertificateSecretsAndAsksNothingAboutNotarization() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, args: ["--signed", "key.p12"], typing: ["y", "p12-password", "Meeting Assistant Self-Signed"])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(Set(setup.secretWrites.compactMap { $0.split(separator: " ").dropFirst(3).first.map(String.init) }),
                       ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"])
        XCTAssertEqual(setup.secretWrites.count, 3)
        XCTAssertTrue(setup.secretWrites.allSatisfy { $0.contains("--repo acme/widgets") && $0.contains("--env release") }, setup.secretWrites.joined(separator: "\n"))
        XCTAssertTrue(result.output.contains("three certificate secrets"), result.output)
    }

    func testSignedModeStillConfirmsFirstAndCreatesTheEnvironmentLimitedToMain() throws {
        let declined = try makeSetup(origin: "git@github.com:acme/widgets.git")
        _ = try run(declined, args: ["--signed", "key.p12"], typing: ["n", "p12-password", "Name"])
        XCTAssertTrue(declined.ghCalls.isEmpty, "nothing may be written without confirmation: \(declined.ghCalls)")

        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git", environment: .missing)
        _ = try run(setup, args: ["--signed", "key.p12"], typing: ["y", "p12-password", "Name"])
        let policy = try XCTUnwrap(setup.ghCalls.firstIndex { $0.contains("deployment-branch-policies") }, setup.ghCalls.joined(separator: "\n"))
        let firstSecret = try XCTUnwrap(setup.ghCalls.firstIndex { $0.hasPrefix("gh secret set") })
        XCTAssertLessThan(policy, firstSecret)
    }

    func testItUnderstandsHTTPSOriginsWithCredentialsAndTrailingSlashes() throws {
        for origin in ["https://github.com/acme/widgets", "https://github.com/acme/widgets/", "https://github.com/acme/widgets.git",
                       "https://x-access-token:abc@github.com/acme/widgets.git", "ssh://git@github.com/acme/widgets.git"] {
            let setup = try makeSetup(origin: origin)

            let result = try run(setup, typing: ["y"] + answers)

            XCTAssertEqual(result.status, 0, "\(origin): \(result.output)")
            XCTAssertTrue(setup.secretWrites.allSatisfy { $0.contains("--repo acme/widgets") }, origin)
        }
    }

    func testSecretsAreStoredInTheReleaseEnvironment() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        _ = try run(setup, typing: ["y"] + answers)

        XCTAssertEqual(setup.secretWrites.count, 6)
        XCTAssertTrue(setup.secretWrites.allSatisfy { $0.contains("--env release") }, setup.secretWrites.joined(separator: "\n"))
    }

    func testAMissingEnvironmentIsCreatedAndLimitedToTheMainBranchBeforeAnySecretIsWritten() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git", environment: .missing)

        let result = try run(setup, typing: ["y"] + answers)

        XCTAssertEqual(result.status, 0, result.output)
        let put = try XCTUnwrap(setup.ghCalls.firstIndex { $0.hasPrefix("gh api --method PUT repos/acme/widgets/environments/release") },
                                setup.ghCalls.joined(separator: "\n"))
        XCTAssertTrue(setup.ghCalls[put].contains("deployment_branch_policy[custom_branch_policies]=true"), setup.ghCalls[put])
        XCTAssertTrue(setup.ghCalls[put].contains("deployment_branch_policy[protected_branches]=false"), setup.ghCalls[put])
        let policy = try XCTUnwrap(setup.ghCalls.firstIndex {
            $0.hasPrefix("gh api --method POST repos/acme/widgets/environments/release/deployment-branch-policies")
        }, setup.ghCalls.joined(separator: "\n"))
        XCTAssertTrue(setup.ghCalls[policy].contains("name=main"), setup.ghCalls[policy])
        XCTAssertTrue(setup.ghCalls[policy].contains("type=branch"), setup.ghCalls[policy])
        let firstSecret = try XCTUnwrap(setup.ghCalls.firstIndex { $0.hasPrefix("gh secret set") })
        XCTAssertLessThan(put, policy, "the policy needs the environment to exist")
        XCTAssertLessThan(policy, firstSecret, "no secret may exist in an environment any branch can use")
    }

    func testAnExistingEnvironmentIsLeftAloneSoItsProtectionRulesSurvive() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git", environment: .exists)

        let result = try run(setup, typing: ["y"] + answers)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(setup.environmentWrites, [], "a bare PUT would reset its reviewers and branch policy")
        XCTAssertEqual(setup.secretWrites.count, 6)
        XCTAssertTrue(result.output.contains("already existed"), "it says it did not touch the rules: \(result.output)")
    }

    func testAnErrorLookingUpTheEnvironmentIsNotTakenForAMissingOne() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git", environment: .unavailable)

        let result = try run(setup, typing: ["y"] + answers)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(setup.environmentWrites, [], "a 502 says nothing about the environment: \(setup.ghCalls)")
        XCTAssertEqual(setup.secretWrites, [])
        XCTAssertTrue(result.output.contains("502"), result.output)
    }

    func testTheEnvironmentIsCheckedBeforeAnySecretIsTypedSoAFailureWastesNoTyping() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git", environment: .unavailable)

        let result = try run(setup, typing: ["y"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("502"), "it fails on the lookup, not on a missing answer: \(result.output)")
    }

    func testNothingIsWrittenUntilTheTargetIsConfirmed() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, typing: ["n"] + answers)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(setup.ghCalls.isEmpty, "gh must not be called without confirmation: \(setup.ghCalls)")
        XCTAssertTrue(result.output.contains("acme/widgets"))
    }

    func testAnEmptyAnswerDoesNotConfirm() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, typing: [""] + answers)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(setup.ghCalls.isEmpty)
    }

    func testTheRepoFlagOverridesTheOriginRemote() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, args: ["--repo", "someone/else", "key.p12"], typing: ["y"] + answers)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(setup.secretWrites.count, 6)
        XCTAssertTrue(setup.secretWrites.allSatisfy { $0.contains("--repo someone/else") })
    }

    func testAMalformedRepoFlagIsRejected() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, args: ["--repo", "not-a-repo", "key.p12"], typing: ["y"] + answers)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("OWNER/NAME"), result.output)
        XCTAssertTrue(setup.ghCalls.isEmpty)
    }

    func testANonGitHubOriginRequiresAnExplicitRepo() throws {
        let setup = try makeSetup(origin: "https://gitlab.example.com/acme/widgets.git")

        let result = try run(setup, typing: ["y"] + answers)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("--repo"), result.output)
        XCTAssertTrue(setup.ghCalls.isEmpty)
    }

    func testMissingOriginRequiresAnExplicitRepo() throws {
        let setup = try makeSetup(origin: nil)

        let result = try run(setup, typing: ["y"] + answers)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("--repo"), result.output)
        XCTAssertTrue(setup.ghCalls.isEmpty)
    }

    func testEverySecretWriteInTheScriptNamesTheRepo() throws {
        let script = try Repo.text("scripts/setup-release-signing.sh")

        let writes = script.split(separator: "\n").filter { $0.contains("gh secret set") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        XCTAssertFalse(writes.isEmpty)
        for write in writes {
            XCTAssertTrue(write.contains("--repo"), "\(write)")
        }
    }
}

// MARK: - Self-signed identity

final class SelfSignedIdentityScriptTests: XCTestCase {
    private let password = "test-password"

    private func make(into directory: URL, name: String? = nil, password: String? = "test-password") throws -> Shell.Outcome {
        var args = name.map { ["--name", $0] } ?? []
        args.append(directory.path)
        return try Shell.runScript("make-self-signed-identity.sh", args: args, env: password.map { ["P12_PASSWORD": $0] } ?? [:])
    }

    private func certificateText(in directory: URL) throws -> String {
        try Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", directory.appendingPathComponent("MeetingAssistantSelfSigned.cer").path, "-noout", "-text"]).output
    }

    func testItWritesAPasswordProtectedP12AndAPublicCertificateAndNothingElse() throws {
        let directory = try Shell.makeTempDirectory(for: self).appendingPathComponent("out")

        let result = try make(into: directory)

        XCTAssertEqual(result.status, 0, result.output)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["MeetingAssistantSelfSigned.cer", "MeetingAssistantSelfSigned.p12"], "scratch files must be cleaned up")
        let p12 = directory.appendingPathComponent("MeetingAssistantSelfSigned.p12").path
        XCTAssertEqual(try Shell.run("/usr/bin/openssl", ["pkcs12", "-in", p12, "-noout", "-passin", "pass:\(password)"]).status, 0, "the password opens it")
        XCTAssertNotEqual(try Shell.run("/usr/bin/openssl", ["pkcs12", "-in", p12, "-noout", "-passin", "pass:wrong"]).status, 0, "a wrong password does not")
        let permissions = try FileManager.default.attributesOfItem(atPath: p12)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "the private key is readable only by its owner")
    }

    func testTheCertificateIsACodeSigningCertificateValidForTenYears() throws {
        let directory = try Shell.makeTempDirectory(for: self).appendingPathComponent("out")
        XCTAssertEqual(try make(into: directory).status, 0)

        let text = try certificateText(in: directory)

        XCTAssertTrue(text.contains("Code Signing"), text)
        XCTAssertTrue(text.contains("Digital Signature"), text)
        XCTAssertTrue(text.contains("CN=Meeting Assistant Self-Signed") || text.contains("CN = Meeting Assistant Self-Signed"), text)
        XCTAssertTrue(text.contains("CA:FALSE"), "it must not be able to issue other certificates")
        let fingerprintCheck = try Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", directory.appendingPathComponent("MeetingAssistantSelfSigned.cer").path,
                                                                 "-noout", "-checkend", String(3650 * 86_400 - 2 * 86_400)])
        XCTAssertEqual(fingerprintCheck.status, 0, "still valid in just under ten years")
        let beyond = try Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", directory.appendingPathComponent("MeetingAssistantSelfSigned.cer").path,
                                                        "-noout", "-checkend", String(3660 * 86_400)])
        XCTAssertNotEqual(beyond.status, 0, "not valid forever")
    }

    func testItPrintsTheSHA1AndTheExactIdentityStringToUse() throws {
        let directory = try Shell.makeTempDirectory(for: self).appendingPathComponent("out")

        let result = try make(into: directory, name: "Acme Self-Signed")

        let sha1 = try XCTUnwrap(captures(#"^SHA-1:\s+([0-9A-F]{40})$"#, in: result.output).first?.first, result.output)
        XCTAssertTrue(result.output.contains("MACOS_SIGNING_IDENTITY:    Acme Self-Signed"), result.output)
        let fingerprint = try Shell.run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", directory.appendingPathComponent("MeetingAssistantSelfSigned.cer").path,
                                                            "-noout", "-fingerprint", "-sha1"]).output
        XCTAssertEqual(fingerprint.split(separator: "=").last.map { $0.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }, sha1)
    }

    func testItGeneratesAndShowsAPasswordOnlyWhenNoneWasGiven() throws {
        let given = try make(into: try Shell.makeTempDirectory(for: self).appendingPathComponent("a"))
        XCTAssertFalse(given.output.contains("MACOS_CERTIFICATE_PASSWORD"), "a password the user chose is not echoed back")

        let directory = try Shell.makeTempDirectory(for: self).appendingPathComponent("b")
        let generated = try make(into: directory, password: nil)
        let shown = try XCTUnwrap(captures(#"^MACOS_CERTIFICATE_PASSWORD: (\S+)"#, in: generated.output).first?.first, generated.output)
        XCTAssertGreaterThanOrEqual(shown.count, 16)
        XCTAssertEqual(try Shell.run("/usr/bin/openssl", ["pkcs12", "-in", directory.appendingPathComponent("MeetingAssistantSelfSigned.p12").path,
                                                          "-noout", "-passin", "pass:\(shown)"]).status, 0)
    }

    func testItNeverOverwritesAnExistingIdentity() throws {
        let directory = try Shell.makeTempDirectory(for: self).appendingPathComponent("out")
        XCTAssertEqual(try make(into: directory).status, 0)
        let p12 = directory.appendingPathComponent("MeetingAssistantSelfSigned.p12")
        let before = try Data(contentsOf: p12)

        let second = try make(into: directory)

        XCTAssertNotEqual(second.status, 0)
        XCTAssertTrue(second.output.contains("Refusing to overwrite"), second.output)
        XCTAssertEqual(try Data(contentsOf: p12), before)
    }

    func testItWritesNothingOutsideTheOutputDirectory() throws {
        let parent = try Shell.makeTempDirectory(for: self)
        let directory = parent.appendingPathComponent("out")

        XCTAssertEqual(try make(into: directory).status, 0)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["out"])
    }

    func testItRejectsANameThatCouldBreakTheCertificateConfiguration() throws {
        let directory = try Shell.makeTempDirectory(for: self).appendingPathComponent("out")

        let result = try make(into: directory, name: "Evil\n[codesign]")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing is created for a rejected name")
    }
}

/// The property the self-signed identity exists for. The script does the work and prints the requirements;
/// it runs in a throwaway directory with a throwaway keychain that is never on the search list.
final class StableIdentityTests: XCTestCase {
    private func verify(_ args: [String]) throws -> Shell.Outcome {
        try Shell.runScript("verify-stable-signing-identity.sh", args: args, env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    private func requirements(prefix: String, in output: String) -> [String] {
        captures("^\(prefix) build [AB]: +(.+)$", in: output).compactMap(\.first)
    }

    func testAdHocBuildsOfDifferentCodeGetDifferentRequirements() throws {
        let result = try verify(["--adhoc-only"])
        try XCTSkipIf(result.status == 77, "codesign is not available: \(result.output)")

        XCTAssertEqual(result.status, 0, result.output)
        let adHoc = requirements(prefix: "ad-hoc", in: result.output)
        XCTAssertEqual(adHoc.count, 2, result.output)
        XCTAssertTrue(adHoc.allSatisfy { $0.contains("cdhash") }, "an ad-hoc requirement is the code hash: \(adHoc)")
        XCTAssertEqual(Set(adHoc).count, 2, "so every build needs fresh permissions: \(adHoc)")
    }

    /// Needs codesign to accept a self-signed certificate, which macOS only does once the certificate is trusted.
    /// That takes an interactive approval, so this runs on the maintainer's Mac with MA_VERIFY_TRUST=1 and is
    /// skipped everywhere else; `scripts/verify-stable-signing-identity.sh --trust` is the same check by hand.
    func testTwoBuildsSignedWithTheSameSelfSignedIdentityShareOneRequirement() throws {
        let trust = ProcessInfo.processInfo.environment["MA_VERIFY_TRUST"] == "1"
        let result = try verify(trust ? ["--trust"] : [])
        try XCTSkipIf(result.status == 77, "the signed half cannot run here: \(result.output)")

        XCTAssertEqual(result.status, 0, result.output)
        let signed = requirements(prefix: "self-signed", in: result.output)
        XCTAssertEqual(signed.count, 2, result.output)
        XCTAssertEqual(Set(signed).count, 1, "one requirement means permissions survive an update: \(signed)")
        XCTAssertTrue(signed.allSatisfy { $0.contains("certificate leaf = H") && !$0.contains("cdhash") }, "\(signed)")
        let adHoc = requirements(prefix: "ad-hoc", in: result.output)
        XCTAssertEqual(Set(adHoc).count, 2, "ad-hoc, the same two builds differ: \(adHoc)")
    }

    func testTheCheckLeavesNoKeychainBehind() throws {
        let before = try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        let temp = FileManager.default.temporaryDirectory.path

        _ = try verify([])

        XCTAssertEqual(try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output, before, "the search list is untouched")
        XCTAssertFalse(before.contains(temp))
    }
}

// MARK: - Repository hygiene

final class RepositoryHygieneTests: XCTestCase {
    func testSigningMaterialIsGitignored() throws {
        let ignored = Set(try Repo.text(".gitignore").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })

        for pattern in ["*.p12", "*.cer", "*.p8"] {
            XCTAssertTrue(ignored.contains(pattern), "\(pattern) must be ignored so a certificate export cannot be committed")
        }
    }

    func testProjectDefaultsMatchTheVERSIONFile() throws {
        let version = try Repo.text("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try Repo.text("project.yml")

        let marketing = try XCTUnwrap(captures(#"MARKETING_VERSION:\s*"([^"]+)""#, in: project).first?.first)

        XCTAssertEqual("v\(marketing)", version, "Bump VERSION and project.yml together so local builds report the release version")
    }
}

// MARK: - Support

private enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}

private func captures(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

private struct Step {
    let text: String

    var name: String { first(#"^(?:      - |        )name:\s*(.+?)\s*$"#) ?? "" }
    var uses: String? { first(#"^(?:      - |        )uses:\s*(\S+)"#) }
    var condition: String? { first(#"^        if:\s*(.+?)\s*$"#) }

    /// Secrets passed through as values (`${{ secrets.X }}`); presence checks such as `secrets.X != ''` are not values.
    var secretValues: [String] { captures(#"\$\{\{\s*secrets\.([A-Z0-9_]+)\s*\}\}"#, in: text).compactMap(\.first) }

    private func first(_ pattern: String) -> String? { captures(pattern, in: text).first?.first }
}

private struct Workflow {
    let text: String
    /// Everything above the job's steps: triggers, permissions, environment, conditions and job-level env.
    let header: String
    let steps: [Step]

    init(_ file: String) throws {
        text = try Repo.text(".github/workflows/\(file)")
        let parts = text.components(separatedBy: "\n    steps:\n")
        guard parts.count == 2 else { throw WorkflowError.noSteps(file) }
        header = parts[0]
        var blocks: [[String]] = []
        for line in parts[1].components(separatedBy: "\n") {
            if line.hasPrefix("      - ") { blocks.append([line]) } else if !blocks.isEmpty { blocks[blocks.count - 1].append(line) }
        }
        steps = blocks.map { Step(text: $0.joined(separator: "\n")) }
    }

    func indexOfStep(_ name: String) throws -> Int {
        try XCTUnwrap(steps.firstIndex { $0.name == name }, "No step named \(name)")
    }

    func step(_ name: String) throws -> Step {
        steps[try indexOfStep(name)]
    }

    enum WorkflowError: Error { case noSteps(String) }
}

/// The GitHub CLI, the one boundary the release scripts talk to and the one that must never be reached from a
/// test. Every call is logged. Answers come from rules, first match wins: a glob over the arguments and what
/// the real `gh` does on failure (a message on stderr, status 1). A call no rule covers succeeds silently.
private struct FakeGitHub {
    enum Answer {
        case ok
        case notFound
        case failure(code: Int, message: String)

        fileprivate var line: String {
            switch self {
            case .ok: return "0|"
            case .notFound: return "1|gh: Not Found (HTTP 404)"
            case let .failure(code, message): return "1|gh: \(message) (HTTP \(code))"
            }
        }
    }

    let bin: URL
    private let log: URL
    private let rules: URL

    init(for test: XCTestCase, rules answers: [(arguments: String, answer: Answer)] = []) throws {
        bin = try Shell.makeTempDirectory(for: test)
        log = bin.appendingPathComponent("gh.log")
        rules = bin.appendingPathComponent("gh.rules")
        try answers.map { "\($0.arguments)|\($0.answer.line)\n" }.joined()
            .write(to: rules, atomically: true, encoding: .utf8)
        let gh = bin.appendingPathComponent("gh")
        try """
        #!/bin/bash
        echo "gh $*" >> "$GH_LOG"
        if [ "$1 $2" = "secret set" ]; then cat >/dev/null; fi
        while IFS='|' read -r pattern status message || [ -n "$pattern" ]; do
          [ -n "$pattern" ] || continue
          case "$*" in
            $pattern)
              [ -z "$message" ] || echo "$message" >&2
              exit "$status" ;;
          esac
        done < "$GH_RULES"
        exit 0
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    }

    /// The environment that puts this fake first on the PATH.
    var environment: [String: String] {
        ["PATH": "\(bin.path):/usr/bin:/bin", "GH_LOG": log.path, "GH_RULES": rules.path]
    }

    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

final class ReleaseSigningModeTests: XCTestCase {
    private static let signing = ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"]
    private static let notarization = ["APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"]

    private func decide(setting names: [String]) throws -> Shell.Outcome {
        var env: [String: String] = [:]
        for name in Self.signing + Self.notarization { env["HAVE_" + name] = names.contains(name) ? "true" : "false" }
        return try Shell.runScript("release-check-signing.sh", env: env)
    }

    func testNoSecretsMeansAnAdHocBuild() throws {
        let result = try decide(setting: [])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "ad-hoc")
    }

    func testTheThreeCertificateSecretsMeanASignedBuild() throws {
        let result = try decide(setting: Self.signing)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "signed")
    }

    func testAllSixSecretsMeanANotarizedBuild() throws {
        let result = try decide(setting: Self.signing + Self.notarization)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "notarized")
    }

    func testAnyPartialCertificateSetFailsNamingWhatIsMissing() throws {
        for count in 1...2 {
            let result = try decide(setting: Array(Self.signing.prefix(count)))

            XCTAssertNotEqual(result.status, 0, "\(count) of 3 certificate secrets must not pass")
            XCTAssertNil(result.outputs["mode"], "a failed check leaves no mode for later steps")
            XCTAssertTrue(result.output.contains(Self.signing[2]), result.output)
        }
    }

    func testNotarizationSecretsWithoutTheCertificateFail() throws {
        let result = try decide(setting: Self.notarization)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(result.outputs["mode"])
    }

    func testACertificateWithOnlySomeNotarizationSecretsFails() throws {
        let result = try decide(setting: Self.signing + ["APPLE_ID"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(result.outputs["mode"])
        XCTAssertTrue(result.output.contains("APPLE_TEAM_ID"), result.output)
    }
}

private enum Shell {
    struct Outcome {
        let status: Int32
        let output: String
        /// Lines the script wrote to $GITHUB_OUTPUT, as key/value pairs.
        let outputs: [String: String]
    }

    static func makeTempDirectory(for test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func runScript(_ name: String, args: [String] = [], env: [String: String] = [:]) throws -> Outcome {
        try runBash(Repo.url("scripts/\(name)"), args: args, env: env)
    }

    static func run(_ executable: String, _ args: [String], path: String = "/usr/bin:/bin") throws -> Outcome {
        try launch(executable, args, env: ["PATH": path], cwd: nil, stdin: "")
    }

    static func runBash(_ script: URL, args: [String] = [], env: [String: String] = [:], cwd: URL? = nil, stdin: String = "") throws -> Outcome {
        try launch("/bin/bash", [script.path] + args, env: env, cwd: cwd, stdin: stdin)
    }

    /// Runs with a clean environment: the runner's own GITHUB_OUTPUT, tokens and git config must never leak into a test.
    private static func launch(_ executable: String, _ args: [String], env: [String: String], cwd: URL?, stdin: String) throws -> Outcome {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseConfigTests-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outputFile = scratch.appendingPathComponent("github_output")
        let stdinFile = scratch.appendingPathComponent("stdin")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        try stdin.write(to: stdinFile, atomically: true, encoding: .utf8)

        var environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": scratch.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GITHUB_OUTPUT": outputFile.path,
        ]
        environment.merge(env) { _, new in new }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = try FileHandle(forReadingFrom: stdinFile)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let written = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        let outputs = Dictionary(written.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<separator]), String(line[line.index(after: separator)...]))
        }, uniquingKeysWith: { _, last in last })
        return Outcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), outputs: outputs)
    }
}
