import Foundation

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum Status: Equatable {
        /// Waiting for a free slot in a "Download all" batch.
        case queued
        case starting
        case downloading
        case processing(String)
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .queued, .starting, .downloading, .processing: return true
            default: return false
            }
        }
    }

    /// What a "Download all" item knows before its own info is fetched.
    struct Batch {
        let trackNumber: Int?
        let trackCount: Int?
        /// Shared album cover; nil for ordinary playlists (each track then
        /// uses its own thumbnail).
        let albumCover: ArtworkCandidate?
        let albumTitle: String?
        /// The cover for the whole list ("Use for all tracks").
        var cover: CoverChoice = .official
        /// Changes the user made to this particular track; they win over
        /// everything automatic.
        var edit: TrackEdit? = nil
        /// The track's full info if it was already looked up (the user
        /// selected it earlier), so it isn't fetched a second time.
        var knownInfo: VideoInfo? = nil
    }

    let id = UUID()
    /// For batch items this starts as the brief playlist entry and is
    /// replaced by the full info right before downloading.
    private(set) var info: VideoInfo
    let quality: Quality
    let batch: Batch?
    @Published var status: Status = .starting
    @Published var progress: Double?
    @Published var detail: String = ""
    @Published var outputFile: URL?
    /// Something the user should know about a finished download
    /// (e.g. saved without album art).
    @Published var note: String?

    /// "Artist - Title" as it will be saved; falls back to the video title.
    var displayTitle: String {
        if let file = outputFile, status == .finished { return file.deletingPathExtension().lastPathComponent }
        return tags.flatMap(OutputFinalizer.fileBaseName(for:)) ?? info.title
    }

    /// Chosen cover for audio, otherwise the video thumbnail.
    var thumbnailURL: URL? { artwork?.previewURL ?? info.thumbnail }

    /// True while ffmpeg re-encodes (shown with a different bar colour).
    var isConverting: Bool {
        if case .processing = status { return progress != nil }
        return false
    }

    /// Cover chosen in the picker (MP3/M4A only); nil means no cover art.
    private(set) var artwork: ArtworkCandidate?
    /// Tags entered in the editor; also decide the "Artist - Title" file name.
    private(set) var tags: MP3Tags?

    private var runner: ProcessRunner?

    init(info: VideoInfo, quality: Quality, artwork: ArtworkCandidate? = nil, tags: MP3Tags? = nil) {
        self.info = info
        self.quality = quality
        self.artwork = artwork
        self.tags = tags
        self.batch = nil
    }

    /// A "Download all" item: waits in the queue, then looks up its own
    /// tags and formats when its turn comes.
    init(entry: SearchResult, quality: Quality, batch: Batch) {
        self.info = VideoInfo(entry: entry)
        self.quality = quality
        self.batch = batch
        if quality.isAudio {
            if let edit = batch.edit, edit.hasArtwork {
                self.artwork = edit.artwork
            } else {
                switch batch.cover {
                case .official: self.artwork = batch.albumCover
                case .custom(let picked): self.artwork = picked
                case .none: self.artwork = nil
                }
            }
        }
        self.tags = batch.edit?.tags
        self.status = .queued
    }

    /// A fresh copy for "Try again".
    func duplicate() -> DownloadItem {
        if let batch {
            return DownloadItem(entry: SearchResult(info: info), quality: quality, batch: batch)
        }
        return DownloadItem(info: info, quality: quality, artwork: artwork, tags: tags)
    }

    /// Batch items: fetch this track's full info for real titles, tags and formats.
    private func prepareBatchItem(_ batch: Batch) async throws {
        status = .starting
        let full: VideoInfo
        if let known = batch.knownInfo {
            full = known
        } else {
            detail = "Getting track info…"
            let infoRunner = ProcessRunner()
            runner = infoRunner
            full = try await YTDLP.fetchInfo(url: info.url, runner: infoRunner)
        }
        info = full
        // Tags the user edited for this track win; otherwise read them from
        // the track's own info.
        var t = batch.edit?.tags ?? MP3Tags.guess(from: full)
        if t.album.isEmpty, batch.edit?.tags == nil, batch.trackNumber != nil, let album = batch.albumTitle {
            t.album = album
        }
        t.trackNumber = batch.trackNumber
        t.trackCount = batch.trackCount
        tags = t
        if quality.isAudio, let edit = batch.edit, edit.hasArtwork {
            artwork = edit.artwork
        } else if quality.isAudio {
            switch batch.cover {
            case .official:
                if let official = ArtworkCandidate.albumCover(of: full) ?? batch.albumCover {
                    artwork = official
                } else if let found = (try? await ArtworkSearch.search(t.searchTerm))?.first {
                    // No official cover (an ordinary video): use the best
                    // album-art match and its album details, the same as the
                    // right pane does when the track is selected.
                    artwork = found
                    if t.album.isEmpty { t.album = found.album ?? "" }
                    if t.year.isEmpty { t.year = found.year ?? "" }
                    if t.genre.isEmpty { t.genre = found.genre ?? "" }
                    tags = t
                } else {
                    artwork = ArtworkCandidate.thumbnail(of: full)
                }
            case .custom(let picked):
                artwork = picked
            case .none:
                artwork = nil
            }
        }
        detail = ""
    }

    /// Writes tags and cover. A cover failure doesn't fail the download —
    /// the returned note explains what went wrong.
    private func finalizeOutput(_ file: URL, into folder: String) async throws -> String? {
        let runner = ProcessRunner()
        self.runner = runner
        status = .processing(quality.isAudio ? "Writing tags and album art…" : "Writing tags…")
        progress = nil
        detail = ""
        let tags = tags ?? MP3Tags.guess(from: info)
        let note = try await OutputFinalizer.finalize(
            file, tags: tags, artwork: artwork, sourceURL: info.url, runner: runner)
        // Only now, complete and tagged, does the file leave its work folder:
        // cancelling any earlier step leaves nothing in the download folder.
        try Task.checkCancellation()
        let file = try OutputFinalizer.move(
            file, into: URL(fileURLWithPath: folder, isDirectory: true),
            baseName: file.deletingPathExtension().lastPathComponent)
        outputFile = file
        // "[Artist/]Artist - Title.<ext>". If moving fails the file stays where it is.
        do {
            outputFile = try OutputFinalizer.place(file, tags: tags)
        } catch {
            return [note, "couldn't move or rename the file (\(error.localizedDescription))"]
                .compactMap { $0 }.joined(separator: "; ")
        }
        return note
    }

    private static let workFolderPrefix = ".soundpick-download-"
    private static var cleanedFolders = Set<String>()

    /// Removes work folders left by a run that crashed or was force-quit.
    /// Done once per download folder, before this run's first download makes
    /// its own, so it can never touch a folder that is in use.
    private static func removeStaleWorkFolders(in folder: String) {
        guard cleanedFolders.insert(folder).inserted else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix(workFolderPrefix) {
            try? fm.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
        }
    }

    func start() {
        // Leave the queue right away so it isn't started twice.
        if status == .queued { status = .starting }
        let runner = ProcessRunner()
        self.runner = runner
        let folder = UserDefaults.standard.string(forKey: SettingsKeys.downloadFolder)
            ?? SettingsKeys.defaultDownloadFolder
        // Each download works in its own hidden folder inside the download
        // folder (same disk, so the final move is instant). yt-dlp treats a
        // file with the expected name as "already downloaded", so a cut-off
        // file left by an interrupted run must never share a folder with a
        // new one; and nothing half-done ever shows up in the download folder.
        Self.removeStaleWorkFolders(in: folder)
        let workFolder = URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(Self.workFolderPrefix + UUID().uuidString, isDirectory: true)
        let template = workFolder.appendingPathComponent("%(title).180B [%(id)s].%(ext)s").path

        Task {
            defer { try? FileManager.default.removeItem(at: workFolder) }
            do {
                try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
                if let batch {
                    try await prepareBatchItem(batch)
                    self.runner = runner
                } else {
                    status = .starting
                }
                let common = await YTDLP.commonSetup()
                let args = common.arguments + quality.arguments + [
                    // --print makes yt-dlp quiet, which hides the "[ExtractAudio]" /
                    // "[Merger]" lines the row's status is read from; --no-quiet
                    // brings them back.
                    "--no-quiet",
                    "--newline", "--progress",
                    "--progress-template", "download:PT|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
                    "--print", "after_move:FILE|%(filepath)s",
                    "-o", template,
                    "--", info.url,
                ]
                let result = try await runner.run(
                    executable: Vendored.ytdlp, arguments: args, environment: common.environment
                ) { line in
                    Task { @MainActor in self.handle(line: line) }
                }
                // Let queued line handlers land before deciding the final state.
                await Task.yield()
                if result.wasTerminated {
                    status = .cancelled
                } else if result.status == 0 {
                    var note: String?
                    if !quality.isAudio, let file = outputFile {
                        try await makeQuickTimeFriendly(file)
                    }
                    if let file = outputFile {
                        note = try await finalizeOutput(file, into: folder)
                    }
                    self.note = note
                    status = .finished
                    progress = 1
                    detail = finishedSummary()
                } else {
                    status = .failed(YTDLPError.from(stderr: result.stderr, status: result.status).message)
                }
            } catch is CancellationError {
                status = .cancelled
            } catch {
                status = .failed(error.localizedDescription)
            }
            self.runner = nil
        }
    }

    /// Re-encodes non-AAC audio, and AV1/VP9 video to HEVC if enabled in Settings.
    private func makeQuickTimeFriendly(_ file: URL) async throws {
        let probe = try await MediaConverter.probe(file)
        guard MediaConverter.needsConversion(probe) else { return }
        let runner = ProcessRunner()
        self.runner = runner
        let videoToo = MediaConverter.hevcEnabled && probe.videoNeedsHEVC
        status = .processing(videoToo ? "Re-encoding video to HEVC…" : "Converting audio to AAC…")
        progress = 0
        detail = ""
        try await MediaConverter.convert(file, probe: probe, duration: info.duration, runner: runner) { fraction in
            Task { @MainActor in self.progress = fraction }
        }
    }

    /// "MP3 · 8.4 MB · 아이유/" for a finished row.
    private func finishedSummary() -> String {
        var bits = [quality.isAudio ? quality.shortLabel : "\(quality.shortLabel) video"]
        if let file = outputFile {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                bits.append(Self.bytes(Double(size)))
            }
            let downloadFolder = UserDefaults.standard.string(forKey: SettingsKeys.downloadFolder)
                ?? SettingsKeys.defaultDownloadFolder
            let parent = file.deletingLastPathComponent()
            if parent.standardizedFileURL.path != URL(fileURLWithPath: downloadFolder).standardizedFileURL.path {
                bits.append(parent.lastPathComponent + "/")
            }
        }
        return bits.joined(separator: " · ")
    }

    func cancel() {
        // Still waiting in the queue: nothing is running yet.
        if status == .queued { status = .cancelled; return }
        runner?.terminate()
    }

    private func handle(line: String) {
        guard status.isActive, status != .queued else { return }
        if line.hasPrefix("PT|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { return }
            let done = Double(parts[1])
            let total = Double(parts[2]) ?? Double(parts[3])
            if let done, let total, total > 0 { progress = min(done / total, 1) }
            var bits: [String] = []
            if let done { bits.append(Self.bytes(done) + (total.map { " of " + Self.bytes($0) } ?? "")) }
            if let speed = Double(parts[4]) { bits.append(Self.bytes(speed) + "/s") }
            if let eta = Double(parts[5]) { bits.append(Self.eta(Int(eta)) + " left") }
            detail = bits.joined(separator: " · ")
            status = .downloading
        } else if line.hasPrefix("FILE|") {
            outputFile = URL(fileURLWithPath: String(line.dropFirst(5)))
        } else if line.hasPrefix("[Merger]") {
            status = .processing("Merging audio and video…"); progress = nil; detail = ""
        } else if line.hasPrefix("[ExtractAudio]") {
            status = .processing("Extracting audio…"); progress = nil; detail = ""
        } else if line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[FixupM3u8]") || line.hasPrefix("[Fixup") {
            status = .processing("Post-processing…"); progress = nil; detail = ""
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static func bytes(_ v: Double) -> String { byteFormatter.string(fromByteCount: Int64(v)) }

    private static func eta(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }
}
