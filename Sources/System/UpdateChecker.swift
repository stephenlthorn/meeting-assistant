import Foundation

/// A release tag such as `v0.10.0`, compared number by number so that 0.10.0 is newer than 0.9.9.
/// Exactly three numbers, like the tags the release workflow publishes; anything else is not a
/// version this app can reason about, and is refused rather than guessed at.
struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var tag: String { "v\(major).\(minor).\(patch)" }
}

struct AvailableUpdate: Equatable {
    /// The new version as a tag, for example `v0.5.0`.
    let version: String
    /// The release notes as plain, trimmed text; empty when the release has none.
    let notes: String
    /// The release's `.app.zip` asset link, which GitHub counts as a download.
    let downloadURL: URL
    let releasePage: URL
}

enum UpdateCheckResult: Equatable {
    case upToDate(version: String)
    case available(AvailableUpdate)
    /// What went wrong and what to do about it, worded for the person who clicked.
    case failed(message: String)

    /// The headline the result window leads with.
    var headline: String {
        switch self {
        case let .upToDate(version): return "You're up to date (\(version))"
        case let .available(update): return "\(update.version) is available"
        case .failed: return "Couldn't check for updates"
        }
    }
}

/// Looks for a newer release. Nothing calls this except the user choosing Check for Updates:
/// there is no schedule and no background check.
protocol UpdateChecking {
    func check() async -> UpdateCheckResult
}

/// Asks GitHub for the latest release and compares its tag to the running version. The request is
/// unauthenticated and carries nothing about the user or their calls.
struct UpdateChecker: UpdateChecking {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/stephenlthorn/meeting-assistant/releases/latest")!
    static let downloadURL = URL(string: "https://github.com/stephenlthorn/meeting-assistant/releases/latest/download/MeetingAssistant.app.zip")!
    static let releaseNotesLimit = 1_500

    private let session: URLSession
    private let currentVersion: String

    init(session: URLSession = UpdateChecker.makeSession(),
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.session = session
        self.currentVersion = currentVersion
    }

    /// No cookies, no cache and a short timeout: this is one small request the user is waiting on.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func check() async -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else {
            return .failed(message: "This copy of Meeting Assistant has no readable version number, so it cannot tell whether a newer one exists.")
        }
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MeetingAssistant-UpdateCheck", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failed(message: Self.message(for: error))
        }
        guard let http = response as? HTTPURLResponse else { return .failed(message: Self.unreadableReply) }
        switch http.statusCode {
        case 200: break
        case 403, 429: return .failed(message: "GitHub is limiting requests from your network right now. Try again in a little while.")
        case 404: return .failed(message: "GitHub has no published release of Meeting Assistant yet.")
        case 500...599: return .failed(message: "GitHub had a server error (\(http.statusCode)). Try again in a moment.")
        default: return .failed(message: "GitHub returned HTTP \(http.statusCode). Try again later.")
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = SemanticVersion(release.tagName) else {
            return .failed(message: Self.unreadableReply)
        }
        guard latest > current else { return .upToDate(version: current.tag) }
        return .available(AvailableUpdate(
            version: latest.tag,
            notes: Self.plainNotes(release.body ?? ""),
            downloadURL: Self.downloadURL,
            releasePage: Self.releasePage(for: latest)))
    }

    /// Built from the validated tag, never taken from the reply, so the link can only go to this repository.
    static func releasePage(for version: SemanticVersion) -> URL {
        AppLinks.sourceCode.appendingPathComponent("releases/tag/\(version.tag)")
    }

    static func plainNotes(_ body: String) -> String {
        let text = body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > releaseNotesLimit else { return text }
        return String(text.prefix(releaseNotesLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static let unreadableReply = "GitHub sent a reply Meeting Assistant could not read. Try again later, or open the release page."

    private static func message(for error: Error) -> String {
        guard let urlError = error as? URLError else { return "The update check failed (\(error.localizedDescription))." }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .timedOut:
            return "Can't reach GitHub. Check your internet connection and try again."
        default:
            return "The update check failed (\(urlError.localizedDescription))."
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let body: String?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
        }
    }
}
