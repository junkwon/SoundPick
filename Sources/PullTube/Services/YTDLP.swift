import Foundation

enum Vendored {
    static var directory: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Vendored", isDirectory: true)
    }
    /// The folder-style yt-dlp build: the executable sits next to its
    /// `_internal` support files, so it starts in ~0.3 s instead of ~5 s.
    /// A newer copy installed by YTDLPUpdater wins over the one in the app.
    static var ytdlp: URL { YTDLPLocation.override ?? bundledYTDLP }
    static var bundledYTDLP: URL { directory.appendingPathComponent("yt-dlp-dist/yt-dlp_macos") }
    static var ffmpeg: URL { directory.appendingPathComponent("ffmpeg") }
    static var deno: URL { directory.appendingPathComponent("deno") }
}

enum SettingsKeys {
    static let useBrowserCookies = "useBrowserCookies"
    static let cookieBrowser = "cookieBrowser"
    static let downloadFolder = "downloadFolder"
    static let reencodeToHEVC = "reencodeToHEVC"
    static let organizeByArtist = "organizeByArtist"
    /// The download format last chosen: "audio"/"video" and "mp3"/"m4a".
    static let formatKind = "formatKind"
    static let audioFormat = "audioFormat"

    static var defaultDownloadFolder: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"
    }
}

struct YTDLPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// Pulls the most useful line out of yt-dlp's stderr.
    static func from(stderr: String, status: Int32) -> YTDLPError {
        let lines = stderr.split(separator: "\n").map(String.init)
        var msg = lines.last(where: { $0.hasPrefix("ERROR:") })
            .map { String($0.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces) }
            ?? lines.last
            ?? "yt-dlp exited with status \(status)"
        let cookiesOn = UserDefaults.standard.bool(forKey: SettingsKeys.useBrowserCookies)
        // The chosen browser has no readable cookie store (not installed,
        // never opened, or blocked by macOS privacy protection).
        if cookiesOn, msg.localizedCaseInsensitiveContains("cookie") {
            let browser = (UserDefaults.standard.string(forKey: SettingsKeys.cookieBrowser) ?? "safari").capitalized
            return YTDLPError(message: "Couldn't read \(browser)'s cookies.\n\nChoose a browser you're signed in with, or turn off “Use browser cookies”, in Settings (⌘,).\n\nDetails: \(msg)")
        }
        if !cookiesOn, msg.contains("403") || msg.localizedCaseInsensitiveContains("sign in to confirm") {
            msg += "\n\nTip: turn on “Use browser cookies” in Settings (⌘,)."
        }
        return YTDLPError(message: msg)
    }
}

enum YTDLP {
    /// Arguments and environment shared by every invocation.
    static func commonSetup() async -> (arguments: [String], environment: [String: String]) {
        var args = commonArguments()
        var env: [String: String] = [:]
        // Trust the same root certificates macOS does (incl. organisation
        // TLS-inspection CAs) instead of yt-dlp's bundled certifi list.
        if let ca = await SystemCertificates.bundle() {
            args += ["--compat-options", "no-certifi"]
            env["SSL_CERT_FILE"] = ca.path
        }
        return (args, env)
    }

    private static func commonArguments() -> [String] {
        var args = ["--no-colors", "--no-playlist", "--ffmpeg-location", Vendored.ffmpeg.path]
        if FileManager.default.isExecutableFile(atPath: Vendored.deno.path) {
            args += ["--js-runtimes", "deno:\(Vendored.deno.path)"]
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: SettingsKeys.useBrowserCookies) {
            let browser = defaults.string(forKey: SettingsKeys.cookieBrowser) ?? "safari"
            args += ["--cookies-from-browser", browser]
        }
        return args
    }

    /// Keyword search on YouTube. Fast: returns titles and thumbnails only;
    /// formats are fetched when a result is selected.
    static func search(_ query: String, limit: Int = 12, runner: ProcessRunner = ProcessRunner()) async throws -> [SearchResult] {
        let common = await commonSetup()
        let result = try await runner.run(
            executable: Vendored.ytdlp,
            arguments: common.arguments + ["--flat-playlist", "-J", "--no-warnings", "--", "ytsearch\(limit):\(query)"],
            environment: common.environment,
            collectStdout: true
        )
        if result.wasTerminated { throw CancellationError() }
        guard result.status == 0 else {
            throw YTDLPError.from(stderr: result.stderr, status: result.status)
        }
        let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        let entries = json?["entries"] as? [[String: Any]] ?? []
        return entries.compactMap(SearchResult.init(json:))
    }

    /// Lists a playlist's tracks without fetching each one (a few seconds
    /// even for long albums). Returns nil when the link isn't a playlist.
    static func playlist(url: String, runner: ProcessRunner = ProcessRunner()) async throws -> (PlaylistInfo, [SearchResult])? {
        let common = await commonSetup()
        let result = try await runner.run(
            executable: Vendored.ytdlp,
            arguments: common.arguments + ["--flat-playlist", "-J", "--no-warnings", "--", url],
            environment: common.environment,
            collectStdout: true
        )
        if result.wasTerminated { throw CancellationError() }
        guard result.status == 0 else {
            throw YTDLPError.from(stderr: result.stderr, status: result.status)
        }
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else { return nil }
        return PlaylistInfo.parse(json, url: url)
    }

    static func fetchInfo(url: String, runner: ProcessRunner = ProcessRunner()) async throws -> VideoInfo {
        let common = await commonSetup()
        let result = try await runner.run(
            executable: Vendored.ytdlp,
            arguments: common.arguments + ["-J", "--no-warnings", "--", url],
            environment: common.environment,
            collectStdout: true
        )
        if result.wasTerminated { throw CancellationError() }
        guard result.status == 0 else {
            throw YTDLPError.from(stderr: result.stderr, status: result.status)
        }
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw YTDLPError(message: "Couldn't read video information.")
        }
        return VideoInfo(url: url, json: json)
    }
}
