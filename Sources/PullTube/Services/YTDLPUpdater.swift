import Foundation
import CryptoKit

/// Where the yt-dlp to run lives: the copy inside the app, or a newer one
/// the updater has installed. Read from any thread.
enum YTDLPLocation {
    private static let lock = NSLock()
    private static var installed: URL?

    static var override: URL? {
        get { lock.lock(); defer { lock.unlock() }; return installed }
        set { lock.lock(); installed = newValue; lock.unlock() }
    }
}

/// Keeps yt-dlp current without rebuilding the app.
///
/// YouTube changes often enough that a yt-dlp a few weeks old stops working.
/// Once a day (and on request from Settings) this asks yt-dlp's GitHub
/// releases for the latest version; a newer one is downloaded, checked
/// against the release's published SHA-256, test-run, and installed under
/// `~/Library/Application Support/SoundPick/yt-dlp/<version>/`. The copy
/// inside the app is never touched and remains the fallback.
@MainActor
final class YTDLPUpdater: ObservableObject {
    static let shared = YTDLPUpdater()

    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        case upToDate
        case updated(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Version of the yt-dlp in use (nil until read at launch).
    @Published private(set) var version: String?
    /// True when the copy in use is one the updater installed.
    @Published private(set) var usingInstalled = false

    private static let releases = "https://github.com/yt-dlp/yt-dlp/releases"
    private static let asset = "yt-dlp_macos.zip"
    private static let executableName = "yt-dlp_macos"
    private static let lastCheckKey = "ytdlpLastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var started = false
    private var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// `~/Library/Application Support/SoundPick/yt-dlp`
    /// (debug builds: `-ytdlpUpdateFolder <path>` for tests).
    private var root: URL {
        #if DEBUG
        if let test = UserDefaults.standard.string(forKey: "ytdlpUpdateFolder") {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SoundPick/yt-dlp", isDirectory: true)
    }

    // MARK: Launch

    /// Picks the copy to use, then checks for an update if a day has passed.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await resolveActiveCopy()
            let defaults = UserDefaults.standard
            var due = Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) >= Self.checkInterval
            #if DEBUG
            if defaults.bool(forKey: "ytdlpCheckNow") { due = true }
            #endif
            if due { await check() }
        }
    }

    /// Uses the newest installed copy if it is newer than the one in the app,
    /// and removes installed copies that are no longer needed.
    private func resolveActiveCopy() async {
        let fm = FileManager.default
        var bundled = await Self.reportedVersion(of: Vendored.bundledYTDLP)
        #if DEBUG
        // `-ytdlpPretendVersion 2020.01.01` makes the bundled copy look old.
        if let pretend = UserDefaults.standard.string(forKey: "ytdlpPretendVersion") { bundled = pretend }
        #endif

        let candidates = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { Self.components($0) != nil }
            .filter { fm.isExecutableFile(atPath: executable(for: $0).path) }
            .sorted { Self.isNewer($0, than: $1) }

        var keep: String?
        if let best = candidates.first, bundled.map({ Self.isNewer(best, than: $0) }) ?? true {
            keep = best
            YTDLPLocation.override = executable(for: best)
            version = best
            usingInstalled = true
        } else {
            YTDLPLocation.override = nil
            version = bundled
            usingInstalled = false
        }
        // Old copies, and leftovers of an interrupted update. Nothing is
        // running yet at launch, so none of them can be in use.
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != keep {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func executable(for version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true).appendingPathComponent(Self.executableName)
    }

    // MARK: Update

    /// Looks for a newer yt-dlp and installs it. Safe to call at any time:
    /// downloads in progress keep the copy they started with.
    func check() async {
        guard !isBusy else { return }
        state = .checking
        do {
            let latest = try await Self.latestVersion()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            if let current = version, !Self.isNewer(latest, than: current) {
                state = .upToDate
            } else {
                try await install(latest)
            }
        } catch {
            state = .failed((error as? YTDLPError)?.message ?? error.localizedDescription)
        }
    }

    private func install(_ latest: String) async throws {
        let fm = FileManager.default
        state = .downloading(version: latest)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.appendingPathComponent(".update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. The archive, and the checksum the release publishes for it.
        let base = "\(Self.releases)/download/\(latest)"
        let sums = try await Self.fetch("\(base)/SHA2-256SUMS")
        guard let expected = String(decoding: sums, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
            .first(where: { $0.count == 2 && $0[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == Self.asset })?
            .first.map({ String($0).lowercased() })
        else { throw YTDLPError(message: "The release has no checksum for \(Self.asset).") }

        let zip = work.appendingPathComponent(Self.asset)
        try await Self.download("\(base)/\(Self.asset)", to: zip)
        let actual = try await Task.detached { try Self.sha256(of: zip) }.value
        guard actual == expected else {
            throw YTDLPError(message: "The download didn't match its checksum, so it was discarded.")
        }

        // 2. Unpack and make sure it runs and is the version it claims to be.
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, unpacked.path])
        guard ditto.status == 0 else { throw YTDLPError(message: "Couldn't unpack the update.") }
        let binary = unpacked.appendingPathComponent(Self.executableName)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        guard let reported = await Self.reportedVersion(of: binary), reported == latest else {
            throw YTDLPError(message: "The downloaded yt-dlp didn't run, so it was discarded.")
        }

        // 3. Into place. The previous copy stays until the next launch, for
        //    any download still using it.
        let destination = root.appendingPathComponent(latest, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: unpacked, to: destination)
        YTDLPLocation.override = executable(for: latest)
        version = latest
        usingInstalled = true
        state = .updated(latest)
    }

    // MARK: Helpers

    /// "2026.11.23" from the tag GitHub redirects `/releases/latest` to.
    nonisolated private static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "\(releases)/latest")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let tag = response.url?.lastPathComponent, components(tag) != nil else {
            throw YTDLPError(message: "Couldn't read the latest yt-dlp version.")
        }
        return tag
    }

    nonisolated private static func fetch(_ address: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: address)!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw YTDLPError(message: "Couldn't download the update (HTTP \(http.statusCode)).")
        }
        return data
    }

    /// Straight to a file, off the main thread.
    nonisolated private static func download(_ address: String, to file: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: address)!)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw YTDLPError(message: "Couldn't download the update (HTTP \(http.statusCode)).")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What `--version` prints, or nil if the file doesn't run.
    nonisolated private static func reportedVersion(of executable: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let out = try? await ProcessRunner().run(executable: executable, arguments: ["--version"], collectStdout: true),
              out.status == 0 else { return nil }
        let text = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return components(text) == nil ? nil : text
    }

    /// yt-dlp versions are dates, "2026.11.23", sometimes with a fourth part.
    nonisolated private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard (3...4).contains(parts.count), !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    nonisolated private static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = components(a) else { return false }
        guard let y = components(b) else { return true }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }
}
