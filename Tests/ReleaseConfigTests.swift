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

        let sign = try release.step("Sign with Developer ID")
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

    func testThirdPartyActionsArePinnedToACommitWithAVersionComment() throws {
        for file in ["build.yml", "release.yml"] {
            let workflow = try Workflow(file)
            for step in workflow.steps {
                guard let uses = step.uses, !uses.hasPrefix("actions/"), !uses.hasPrefix("./") else { continue }
                XCTAssertNotNil(uses.range(of: #"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$"#, options: .regularExpression),
                                "\(file): \(uses) must be pinned to a full commit SHA")
                XCTAssertNotNil(step.text.range(of: #"uses:\s*\S+@[0-9a-f]{40}\s+# v\d"#, options: .regularExpression),
                                "\(file): \(uses) needs a version comment so the pin can be reviewed")
            }
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

        XCTAssertTrue(try release.step("Sign with Developer ID").condition?.contains("steps.signing.outputs.mode == 'developer-id'") == true)
        XCTAssertTrue(try release.step("Notarize").condition?.contains("steps.signing.outputs.mode == 'developer-id'") == true)
        let adHoc = try release.step("Ad-hoc sign")
        XCTAssertTrue(adHoc.condition?.contains("steps.signing.outputs.mode == 'ad-hoc'") == true)
        XCTAssertFalse(adHoc.text.contains("env.MACOS_CERTIFICATE_P12"))
    }

    func testReleaseNotesDescribeTheSigningModeAndNotarizationOutcomeActuallyUsed() throws {
        let notes = try Workflow("release.yml").step("Write release notes")

        XCTAssertTrue(notes.text.contains("steps.signing.outputs.mode"))
        XCTAssertTrue(notes.text.contains("steps.notarize.outputs.done"))
        XCTAssertTrue(notes.text.contains("scripts/release-notes.sh"))
    }

    func testReleaseNeverRebuildsAnExistingTag() throws {
        let release = try Workflow("release.yml")

        for name in ["Check signing secrets", "Build (Release)", "Sign with Developer ID", "Notarize", "Publish release"] {
            XCTAssertTrue(try release.step(name).condition?.contains("steps.existing.outputs.exists != 'true'") == true, name)
        }
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

    func testEverySigningAndNotarizationSecretMeansSignAndNotarize() throws {
        let result = try checkSigning(present: allSecrets)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "developer-id")
    }

    func testNoSecretsMeansAnAdHocBuild() throws {
        let result = try checkSigning(present: [])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.outputs["mode"], "ad-hoc")
    }

    func testCertificateWithoutNotarizationSecretsFailsNamingTheMissingOnes() throws {
        let result = try checkSigning(present: ["MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertNil(result.outputs["mode"])
        for missing in ["APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD"] {
            XCTAssertTrue(result.output.contains(missing), "\(missing) should be named: \(result.output)")
        }
        XCTAssertFalse(result.output.contains("MACOS_CERTIFICATE_P12"), "Only the missing secrets should be named")
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
        let result = try notes(mode: "developer-id", notarized: "true")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Signed and notarized"))
        XCTAssertFalse(result.output.localizedCaseInsensitiveContains("ad-hoc"))
        XCTAssertFalse(result.output.contains("xattr"))
    }

    func testDeveloperIDBuildsThatSkippedNotarizationAreNotCalledAdHoc() throws {
        let result = try notes(mode: "developer-id", notarized: "")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Developer ID"))
        XCTAssertTrue(result.output.contains("not notarized"))
        XCTAssertFalse(result.output.localizedCaseInsensitiveContains("ad-hoc"))
        XCTAssertTrue(result.output.contains("xattr -dr com.apple.quarantine"), "Users still need the Gatekeeper workaround")
    }

    func testAdHocReleasesCarryTheLaunchInstructions() throws {
        let result = try notes(mode: "ad-hoc", notarized: "")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Ad-hoc signed"))
        XCTAssertTrue(result.output.contains("xattr -dr com.apple.quarantine MeetingAssistant.app"))
        XCTAssertFalse(result.output.contains("Developer ID"))
    }

    func testAnAdHocBuildCanNeverBeDescribedAsNotarized() throws {
        XCTAssertEqual(try notes(mode: "ad-hoc", notarized: "").status, 0, "A valid combination is the control for the rejections below")
        XCTAssertNotEqual(try notes(mode: "ad-hoc", notarized: "true").status, 0)
        XCTAssertNotEqual(try notes(mode: "mystery", notarized: "").status, 0)
    }

    func testTheScriptsTheWorkflowsCallAreExecutable() throws {
        for name in ["release-resolve-version.sh", "release-check-signing.sh", "release-notes.sh", "setup-release-signing.sh"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Repo.url("scripts/\(name)").path), name)
        }
    }
}

// MARK: - Signing setup script

final class SigningSetupScriptTests: XCTestCase {
    private let answers = ["p12-password", "Developer ID Application: Test (TEAMID)", "dev@example.com", "TEAMID", "app-password"]

    private struct Setup {
        let checkout: URL
        let elsewhere: URL
        let log: URL
        let bin: URL
        var script: URL { checkout.appendingPathComponent("scripts/setup-release-signing.sh") }
        var p12: URL { elsewhere.appendingPathComponent("key.p12") }

        var ghCalls: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        var secretWrites: [String] { ghCalls.filter { $0.hasPrefix("gh secret set") } }
    }

    private func makeSetup(origin: String?) throws -> Setup {
        let checkout = try Shell.makeTempDirectory(for: self)
        let elsewhere = try Shell.makeTempDirectory(for: self)
        let bin = try Shell.makeTempDirectory(for: self)
        let log = bin.appendingPathComponent("gh.log")

        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Repo.url("scripts/setup-release-signing.sh"),
                                         to: checkout.appendingPathComponent("scripts/setup-release-signing.sh"))
        _ = try Shell.run("/usr/bin/git", ["init", "-q", checkout.path])
        if let origin {
            _ = try Shell.run("/usr/bin/git", ["-C", checkout.path, "remote", "add", "origin", origin])
        }
        try "certificate".write(to: elsewhere.appendingPathComponent("key.p12"), atomically: true, encoding: .utf8)

        let gh = bin.appendingPathComponent("gh")
        try """
        #!/bin/bash
        echo "gh $*" >> "$GH_LOG"
        if [ "$1 $2" = "secret set" ]; then cat >/dev/null; fi
        if [ "$1" = "api" ] && [ "$2" != "--method" ] && [ -z "${GH_ENV_EXISTS:-}" ]; then exit 1; fi
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        return Setup(checkout: checkout, elsewhere: elsewhere, log: log, bin: bin)
    }

    private func run(_ setup: Setup, args: [String]? = nil, environmentExists: Bool = false, typing lines: [String]) throws -> Shell.Outcome {
        var env = ["PATH": "\(setup.bin.path):/usr/bin:/bin", "GH_LOG": setup.log.path]
        if environmentExists { env["GH_ENV_EXISTS"] = "1" }
        return try Shell.runBash(setup.script,
                          args: args ?? ["key.p12"],
                          env: env,
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

        XCTAssertTrue(setup.ghCalls.contains("gh api --method PUT repos/acme/widgets/environments/release"), "A missing environment is created")
        XCTAssertEqual(setup.secretWrites.count, 6)
        XCTAssertTrue(setup.secretWrites.allSatisfy { $0.contains("--env release") }, setup.secretWrites.joined(separator: "\n"))
    }

    func testAnExistingEnvironmentIsLeftAloneSoItsProtectionRulesSurvive() throws {
        let setup = try makeSetup(origin: "git@github.com:acme/widgets.git")

        let result = try run(setup, environmentExists: true, typing: ["y"] + answers)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(setup.ghCalls.contains { $0.contains("--method PUT") }, setup.ghCalls.joined(separator: "\n"))
        XCTAssertEqual(setup.secretWrites.count, 6)
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
