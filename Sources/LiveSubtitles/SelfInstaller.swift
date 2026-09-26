//
//  SelfInstaller.swift
//  LiveSubtitles
//
//  A copy that came from a download installs itself into /Applications on first launch.
//
//  This is not a nicety. A quarantined app launched from Downloads - or straight out of
//  the disk image - gets run by macOS from a fresh random directory each time
//  ("App Translocation"). The app then looks like a different app on every launch, so the
//  Screen Recording grant can never be remembered and the permission prompt returns
//  forever, however many times the box in System Settings is ticked.
//
//  Moving to /Applications and clearing the quarantine flag fixes that at the root, and
//  leaves exactly one canonical copy - the same one a developer builds with `make install`.
//

import AppKit
import Foundation

@MainActor
enum SelfInstaller {
    static let destination = URL(fileURLWithPath: "/Applications/LiveSubtitles.app")

    /// Already running from the install location.
    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// This copy was downloaded rather than installed, so it should move itself.
    ///
    /// Only downloads qualify: a development build run from `build/` is not quarantined
    /// and is deliberately left alone, as is anything the user chose to keep elsewhere.
    static var isDownloadedCopy: Bool {
        guard !isInstalled else { return false }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") { return true }
        return hasQuarantineFlag
    }

    private static var hasQuarantineFlag: Bool {
        getxattr(Bundle.main.bundlePath, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }

    enum InstallError: LocalizedError {
        case copyFailed(String)
        case verifyFailed

        var errorDescription: String? {
            switch self {
            case .copyFailed(let detail):
                return "Could not copy into /Applications: \(detail)"
            case .verifyFailed:
                return "The copy in /Applications did not verify as the same app."
            }
        }
    }

    /// Copies this bundle into /Applications, replaces whatever was there, and clears the
    /// quarantine flag so the installed copy launches normally.
    static func install() throws {
        let source = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let staging = URL(fileURLWithPath: "/Applications/.LiveSubtitles-installing.app")

        try? fileManager.removeItem(at: staging)
        try run("/usr/bin/ditto", [source.path, staging.path])
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])

        // Refuse to install something that is not our app.
        let plist = staging.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              parsed["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            try? fileManager.removeItem(at: staging)
            throw InstallError.verifyFailed
        }

        // Any older instance running from /Applications would fight the new one.
        try? run("/usr/bin/pkill", ["-f", "/Applications/LiveSubtitles.app/Contents/MacOS"])

        let backup = URL(fileURLWithPath: "/Applications/.LiveSubtitles-previous.app")
        try? fileManager.removeItem(at: backup)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.moveItem(at: backup, to: destination)   // put it back
            try? fileManager.removeItem(at: staging)
            throw InstallError.copyFailed(error.localizedDescription)
        }
        try? fileManager.removeItem(at: backup)
    }

    /// Starts the installed copy once this process is gone.
    static func relaunchInstalled() {
        let script = """
        #!/bin/bash
        for _ in $(seq 1 240); do
          kill -0 "$1" 2>/dev/null || break
          sleep 0.25
        done
        open "/Applications/LiveSubtitles.app"
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("livesubtitles-relaunch.sh")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? process.run()
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw InstallError.copyFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
    }
}
