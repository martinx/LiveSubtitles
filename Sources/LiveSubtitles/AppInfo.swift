//
//  AppInfo.swift
//  LiveSubtitles
//
//  Single source of truth for the app's identity: name, version, author and the
//  GitHub coordinates used by the About window, the welcome screen and the updater.
//

import Foundation

enum AppInfo {
    static let name = "Live Subtitles"
    static let tagline = "Real-time English subtitles for anything playing on your Mac."

    static let summary = """
    Live Subtitles listens to whatever your Mac is playing and draws the words on \
    screen as they are spoken — the episode you are watching, a video call, or a file \
    with no subtitles.

    Recognition runs entirely on this Mac's Neural Engine. No audio leaves the \
    machine, there is no account and no subscription. The only network access is the \
    one-time download of the speech model, plus the version check below if you leave \
    it switched on.
    """

    static let author = "Martin Xu"
    static let authorEmail = "martin.xus@gmail.com"

    // Where releases live. Changing the owner or repository name here is all that is
    // needed for the update check and every link in the UI to follow.
    static let githubOwner = "martinx"
    static let githubRepository = "LiveSubtitles"

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepository)")!
    }
    static var releasesURL: URL {
        repositoryURL.appendingPathComponent("releases")
    }
    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepository)/releases/latest")!
    }

    static var releasesPageURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepository)/releases/latest")!
    }

    /// True when macOS is running this copy from its random, read-only "App Translocation"
    /// directory, which it does for a quarantined app it cannot verify in place.
    ///
    /// Every launch then happens at a different path, so the app looks like a different app
    /// each time and the Screen Recording grant can never stick - which is why the
    /// permission prompt keeps coming back even though the tick box is already on. The cure
    /// is to move the app to /Applications and open it from there.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var versionDescription: String {
        "Version \(version) (\(buildNumber))"
    }

    static var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        return "© \(year) \(author)"
    }
}
