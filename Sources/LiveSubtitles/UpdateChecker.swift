//
//  UpdateChecker.swift
//  LiveSubtitles
//
//  Asks GitHub for the latest release and, on request, installs it.
//
//  This is the app's only network access besides the one-time model download: a plain
//  GET of the public releases API. No identifiers, no telemetry, and it can be switched
//  off in Settings.
//
//  Installation is deliberately explicit rather than silent. The running bundle carries
//  a Screen Recording grant, so replacing it unattended is a good way to end up with an
//  app that will not launch and no idea why. Instead: download, verify, then hand the
//  swap to a small script that waits for this process to exit, keeps a backup, and rolls
//  back if the swap fails.
//

import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let zipURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let defaults: UserDefaults
    private static let lastCheckKey = "lastUpdateCheck"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var availableRelease: Release? {
        if case .available(let release) = status { return release }
        return nil
    }

    // MARK: - Checking

    /// Checks at most once a day, so launching repeatedly does not hammer the API.
    func checkIfDue(enabled: Bool) {
        guard enabled else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 24 else { return }
        Task { await check() }
    }

    func check() async {
        if case .installing = status { return }
        status = .checking

        do {
            var request = URLRequest(url: AppInfo.latestReleaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("LiveSubtitles/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
            // 404 simply means no release has been published yet.
            guard http.statusCode != 404 else {
                status = .upToDate
                return
            }
            guard http.statusCode == 200 else {
                throw UpdateError.http(http.statusCode)
            }

            let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
            defaults.set(Date(), forKey: Self.lastCheckKey)

            let version = payload.tag_name.hasPrefix("v")
                ? String(payload.tag_name.dropFirst())
                : payload.tag_name

            guard Version.isNewer(version, than: AppInfo.version) else {
                status = .upToDate
                return
            }

            status = .available(Release(
                version: version,
                notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                pageURL: URL(string: payload.html_url) ?? AppInfo.releasesPageURL,
                zipURL: payload.assets
                    .first { $0.name.lowercased().hasSuffix(".zip") }
                    .flatMap { URL(string: $0.browser_download_url) }
            ))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installing

    func install(_ release: Release) async {
        status = .installing(release)
        do {
            guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                throw UpdateError.notInstalled
            }
            guard let zipURL = release.zipURL else {
                throw UpdateError.noAsset
            }

            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("LiveSubtitles-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let archive = try await download(zipURL, into: work)
            let staged = try unzip(archive, into: work)
            try verify(staged, expecting: release.version)
            try startSwapHelper(staged: staged, target: URL(fileURLWithPath: Bundle.main.bundlePath))

            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, into directory: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.network
        }
        let destination = directory.appendingPathComponent("LiveSubtitles.zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func unzip(_ archive: URL, into directory: URL) throws -> URL {
        let extracted = directory.appendingPathComponent("extracted")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, extracted.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.unzip }

        let contents = try FileManager.default.contentsOfDirectory(at: extracted,
                                                                   includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unzip
        }
        return app
    }

    /// Refuse to install a bundle that is not the version we asked for, or that fails its
    /// own signature check.
    private func verify(_ app: URL, expecting version: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let found = parsed["CFBundleShortVersionString"] as? String else {
            throw UpdateError.malformed
        }
        guard found == version else {
            throw UpdateError.versionMismatch(expected: version, found: found)
        }

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--strict", app.path]
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else { throw UpdateError.signature }
    }

    /// Hands the swap to a detached script: this process has to exit before its own
    /// bundle can be replaced.
    private func startSwapHelper(staged: URL, target: URL) throws {
        let script = """
        #!/bin/bash
        # LiveSubtitles update helper: $1 pid, $2 staged app, $3 installed app
        set -u
        exec >>/tmp/livesubtitles-update.log 2>&1
        echo "=== $(date) pid=$1 staged=$2 target=$3"

        for _ in $(seq 1 240); do
          kill -0 "$1" 2>/dev/null || break
          sleep 0.5
        done

        BACKUP="$3.old"
        rm -rf "$BACKUP"
        if ! mv "$3" "$BACKUP"; then
          echo "cannot move the installed app aside"
          exit 1
        fi

        if mv "$2" "$3"; then
          xattr -dr com.apple.quarantine "$3" 2>/dev/null || true
          rm -rf "$BACKUP"
          echo "installed, relaunching"
          open "$3"
        else
          echo "install failed, rolling back"
          mv "$BACKUP" "$3" 2>/dev/null || true
          exit 1
        fi
        """

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livesubtitles-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: scriptURL.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptURL.path,
                            String(ProcessInfo.processInfo.processIdentifier),
                            staged.path,
                            target.path]
        try helper.run()
    }

    // MARK: - GitHub payload

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]
    }

    enum UpdateError: LocalizedError {
        case network
        case http(Int)
        case noAsset
        case notInstalled
        case unzip
        case malformed
        case versionMismatch(expected: String, found: String)
        case signature

        var errorDescription: String? {
            switch self {
            case .network:
                return "Could not reach GitHub."
            case .http(let code):
                return "GitHub returned HTTP \(code)."
            case .noAsset:
                return "The latest release has no downloadable zip attached."
            case .notInstalled:
                return "Live Subtitles is running from outside /Applications, so it cannot replace itself. Download the release and install it manually."
            case .unzip:
                return "The downloaded update could not be unpacked."
            case .malformed:
                return "The downloaded app bundle is missing its Info.plist."
            case .versionMismatch(let expected, let found):
                return "The download reports version \(found), but \(expected) was expected. Nothing was installed."
            case .signature:
                return "The downloaded app failed its code signature check. Nothing was installed."
            }
        }
    }
}
