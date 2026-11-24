import Foundation
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum FetchState: Equatable {
        case idle
        case loading
        case loaded(VideoInfo)
        case failed(String)
    }

    /// The search field: keywords to search for, or a link.
    @Published var urlText = ""
    /// Info for the selected result (shown in the right pane).
    @Published var fetchState: FetchState = .idle

    // MARK: Search results

    enum SearchState: Equatable { case idle, searching, done, failed(String) }

    @Published var searchState: SearchState = .idle
    @Published var results: [SearchResult] = []
    @Published var selectedResultID: String?
    /// Set when the results are the tracks of a playlist or album.
    @Published var playlist: PlaylistInfo?
    /// A playlist the current single video belongs to (`watch?v=…&list=…`),
    /// offered as "Show playlist".
    @Published var playlistOffer: String?
    /// Playlist tracks the user unticked; everything else is downloaded by
    /// "Download all". Cleared whenever the results change.
    @Published var uncheckedIDs: Set<String> = []
    private var searchTask: Task<Void, Never>?
    private var searchRunner: ProcessRunner?
    @Published var quality: Quality = .best {
        didSet {
            if quality.isAudio { searchArtworkIfNeeded() }
            // The preview follows Audio/Video; switching ends it.
            if quality.isAudio != oldValue.isAudio { stopPreview() }
            // A change made by the user does two things: it becomes the
            // standing choice for tracks opened next (Audio or Video, MP3 or
            // M4A), and it is remembered for this particular track, so coming
            // back to it shows exactly what was picked.
            guard !settingQualityAutomatically, quality != oldValue else { return }
            if quality.isAudio {
                prefersAudio = true
                audioFormat = quality
            } else {
                prefersAudio = false
            }
            saveFormatChoice()
            if let id = selectedResultID, case .loaded = fetchState {
                trackEdits[id, default: TrackEdit()].quality = quality
            }
        }
    }
    private var settingQualityAutomatically = false

    // MARK: Standing format choice

    /// Audio or Video, as last chosen. Stays put when another track is opened.
    private var prefersAudio = UserDefaults.standard.string(forKey: SettingsKeys.formatKind) != "video"
    /// MP3 or M4A, as last chosen.
    private var audioFormat: Quality = UserDefaults.standard.string(forKey: SettingsKeys.audioFormat) == "m4a" ? .audioOnly : .mp3
    /// Debug launches that open a link for a screenshot don't overwrite the saved choice.
    private let savesFormatChoice = UserDefaults.standard.string(forKey: "openLink") == nil

    private func saveFormatChoice() {
        guard savesFormatChoice else { return }
        UserDefaults.standard.set(prefersAudio ? "audio" : "video", forKey: SettingsKeys.formatKind)
        UserDefaults.standard.set(audioFormat == .audioOnly ? "m4a" : "mp3", forKey: SettingsKeys.audioFormat)
    }

    /// The format for tracks without a choice of their own: the audio format
    /// last used, or for Video simply the best each track offers.
    private var standingQuality: Quality { prefersAudio ? audioFormat : .best }

    /// Fits a wanted format to what this track actually offers.
    private func resolve(_ wanted: Quality, for info: VideoInfo) -> Quality {
        if wanted.isAudio {
            if info.audioOptions.contains(wanted) { return wanted }
            return info.audioOptions.first ?? info.defaultQuality
        }
        if info.videoOptions.contains(wanted), wanted != .best { return wanted }
        // "Best", or a resolution this track doesn't have: the highest one
        // that doesn't exceed it, else the track's best.
        if case .height(let limit) = wanted,
           let fitting = info.videoOptions.first(where: { if case .height(let h) = $0 { return h <= limit }; return false }) {
            return fitting
        }
        return info.defaultQuality
    }

    /// The format a track opens with: its own choice if it has one, else the
    /// standing choice.
    private func preferredQuality(for info: VideoInfo) -> Quality {
        let own = selectedResultID.flatMap { trackEdits[$0]?.quality }
        return resolve(own ?? standingQuality, for: info)
    }

    private func applyPreferredQuality(for info: VideoInfo) {
        settingQualityAutomatically = true
        quality = preferredQuality(for: info)      // also starts the album-art lookup for audio
        settingQualityAutomatically = false
    }

    /// Switches between the Audio and Video groups of the format control.
    func setAudioMode(_ audio: Bool) {
        guard case .loaded(let info) = fetchState, audio != quality.isAudio else { return }
        quality = resolve(audio ? audioFormat : .best, for: info)
    }

    // MARK: Preview

    /// Plays the selected track from the site, as audio or video depending
    /// on the Audio/Video choice. Views observe it directly.
    let preview = PreviewPlayer()
    /// Play was pressed before the track's details (and stream links) arrived.
    private var previewAwaitingDetails = false
    /// The links were already refreshed once for the current attempt.
    private var previewRefreshed = false
    private var previewWait: Task<Void, Never>?

    /// The play button: starts the preview, or pauses/resumes it.
    func togglePreview() {
        guard case .loaded(let info) = fetchState else { return }
        let video = !quality.isAudio
        if preview.isActive(for: info.id, video: video) {
            switch preview.state {
            case .playing, .paused: preview.togglePause(); return
            case .loading: stopPreview(); return
            default: break
            }
        }
        previewRefreshed = false
        startPreview(info)
    }

    func stopPreview() {
        previewAwaitingDetails = false
        previewWait?.cancel()
        previewWait = nil
        if preview.state != .idle { preview.stop() }
    }

    private func startPreview(_ info: VideoInfo) {
        let video = !quality.isAudio
        previewAwaitingDetails = false
        // The direct stream starts fastest. If the site isn't serving it yet
        // (or there is none), the segmented one plays right away instead.
        let direct = video ? info.previewVideoURL : info.previewAudioURL
        let ready = (info.previewAvailableAt ?? .distantPast).timeIntervalSinceNow < -0.5
        if let url = (ready ? direct : nil) ?? info.previewHLSURL ?? direct {
            if !ready, info.previewHLSURL == nil, let at = info.previewAvailableAt {
                // Only the direct stream exists: wait the few seconds it needs.
                preview.prepare(trackID: info.id, video: video, duration: info.duration)
                previewWait = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, at.timeIntervalSinceNow + 0.6) * 1e9))
                    guard !Task.isCancelled, let self,
                          self.preview.trackID == info.id, self.preview.state == .loading else { return }
                    self.startPreview(info)
                }
                return
            }
            preview.play(url, trackID: info.id, video: video, duration: info.duration) { [weak self] in
                self?.previewFailed(info)
            }
        } else if isRefiningInfo {
            // Shown from its list row; `refine` starts it when the details arrive.
            previewAwaitingDetails = true
            preview.prepare(trackID: info.id, video: video, duration: info.duration)
        } else {
            preview.prepare(trackID: info.id, video: video, duration: info.duration)
            preview.fail(detailsError != nil
                         ? "Can't preview: the track's details couldn't be loaded."
                         : "This track can't be previewed here. Downloading still works.")
        }
    }

    /// The stream didn't open. Its links expire after a few hours, so get
    /// fresh ones once before giving up.
    private func previewFailed(_ info: VideoInfo) {
        let message = "Couldn't play the preview. Downloading still works."
        guard !previewRefreshed else { preview.fail(message); return }
        previewRefreshed = true
        let url = info.url
        Task {
            let fresh = try? await YTDLP.fetchInfo(url: url, runner: ProcessRunner())
            if let fresh { infoCache[url] = fresh }
            // Still the track on screen, and the user hasn't stopped it?
            guard lastFetchedURL == url, preview.trackID == info.id, preview.state == .loading else { return }
            guard let fresh else { preview.fail(message); return }
            if case .loaded = fetchState { fetchState = .loaded(fresh) }
            startPreview(fresh)
        }
    }

    /// The format a row will download with, when it has one of its own.
    func ownFormatLabel(for result: SearchResult) -> String? {
        guard let q = trackEdits[result.id]?.quality else { return nil }
        return q.isAudio ? "Audio \(q.shortLabel)" : "Video \(q.shortLabel)"
    }
    @Published var downloads: [DownloadItem] = []
    /// Forwards each download's changes, so views that summarise the list
    /// ("Clear finished") refresh when a download finishes.
    private var downloadObservers: [UUID: AnyCancellable] = [:]

    private func observe(_ item: DownloadItem) {
        downloadObservers[item.id] = item.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            // A slot may have opened for the next queued item.
            Task { @MainActor in self?.pumpBatchQueue() }
        }
    }

    // MARK: Download all

    /// How many "Download all" items run at once.
    private let batchLimit = 3

    /// Format for one track of a batch: its own choice if it has one, else
    /// the standing choice (for Video, the best that track offers).
    private func batchQuality(for entry: SearchResult) -> Quality {
        trackEdits[entry.id]?.quality ?? standingQuality
    }

    /// The ticked playlist tracks, in order.
    var checkedResults: [SearchResult] { results.filter { !uncheckedIDs.contains($0.id) } }

    func isChecked(_ result: SearchResult) -> Bool { !uncheckedIDs.contains(result.id) }

    func setChecked(_ checked: Bool, for result: SearchResult) {
        if checked { uncheckedIDs.remove(result.id) } else { uncheckedIDs.insert(result.id) }
        if checked { schedulePrefetch() }
    }

    /// Ticks every track, or unticks them all.
    func setAllChecked(_ checked: Bool) {
        uncheckedIDs = checked ? [] : Set(results.map(\.id))
        if checked { schedulePrefetch() }
    }

    /// Queues the ticked tracks with the format chosen on the right. Album
    /// tracks keep their original numbers ("07 - …", 7/32) even when only
    /// some are downloaded.
    func downloadAll() {
        let chosen = checkedResults
        guard let playlist, !chosen.isEmpty else { return }
        // Each track uses, in order: its own edits, the "for all tracks"
        // cover, then its automatic official cover and tags.
        let items = chosen.map { entry in
            DownloadItem(entry: entry, quality: batchQuality(for: entry), batch: DownloadItem.Batch(
                trackNumber: playlist.isAlbum ? entry.index : nil,
                trackCount: playlist.isAlbum ? playlist.count : nil,
                albumCover: playlist.coverCandidate,
                albumTitle: playlist.title,
                cover: coverForAll,
                edit: trackEdits[entry.id],
                knownInfo: infoCache[entry.url]))
        }
        downloads.insert(contentsOf: items, at: 0)
        items.forEach(observe)
        pumpBatchQueue()
    }

    /// Starts queued items, in list order, while fewer than `batchLimit` run.
    private func pumpBatchQueue() {
        var running = downloads.filter { $0.batch != nil && $0.status.isActive && $0.status != .queued }.count
        for item in downloads where item.status == .queued {
            guard running < batchLimit else { break }
            item.start()
            running += 1
        }
    }

    // MARK: Album art (MP3/M4A)

    enum ArtworkSearchState: Equatable { case idle, searching, done, failed(String) }

    @Published var artworkQuery = ""
    @Published var artworkCandidates: [ArtworkCandidate] = []
    /// nil = no cover art.
    @Published var selectedArtwork: ArtworkCandidate? {
        didSet { fillTagsFromArtwork() }
    }

    // MARK: Tags (all formats; album art is audio-only)

    @Published var tags = MP3Tags() {
        didSet {
            // Typing in the tag fields is remembered for this track. Changes
            // the app makes itself (loading a track, following a cover) aren't.
            guard !applyingAutomaticTags, tags != oldValue, let id = selectedResultID,
                  case .loaded = fetchState else { return }
            trackEdits[id, default: TrackEdit()].tags = tags
        }
    }
    private var applyingAutomaticTags = false

    // MARK: Per-track edits

    /// Covers and tags the user changed, by result id. Cleared when the
    /// results list changes.
    @Published private(set) var trackEdits: [String: TrackEdit] = [:]
    /// Cover for every track that has none of its own ("Use for all tracks").
    @Published private(set) var coverForAll: CoverChoice = .official

    /// The user chose a cover for the selected track (nil = "No cover").
    func pickArtwork(_ candidate: ArtworkCandidate?) {
        selectedArtwork = candidate
        guard let id = selectedResultID else { return }
        var edit = trackEdits[id] ?? TrackEdit()
        edit.hasArtwork = true
        edit.artwork = candidate
        trackEdits[id] = edit
    }

    /// Makes the selected track's cover the cover of every track in the list.
    /// Choosing the official album cover returns to "each track's own".
    func useSelectedCoverForAll() {
        if let selected = selectedArtwork {
            coverForAll = selected.source == .album ? .official : .custom(selected)
        } else {
            coverForAll = .none
        }
        // It replaces covers picked for single tracks.
        for id in trackEdits.keys {
            trackEdits[id]?.hasArtwork = false
            trackEdits[id]?.artwork = nil
            if trackEdits[id]?.isEmpty == true { trackEdits[id] = nil }
        }
    }

    /// Whether the selected track's cover is already the one for all tracks.
    var selectedCoverIsForAll: Bool {
        switch coverForAll {
        case .official: return selectedArtwork?.source == .album
        case .custom(let cover): return selectedArtwork == cover
        case .none: return selectedArtwork == nil
        }
    }

    /// Forgets the changes made to one track.
    func discardEdits(for result: SearchResult) {
        trackEdits[result.id] = nil
        if result.id == selectedResultID, case .loaded(let info) = fetchState {
            resetArtwork(for: info)
            applyPreferredQuality(for: info)
        }
    }

    /// The cover a row should show: the track's own pick, else the one for all.
    func coverOverride(for result: SearchResult) -> (isSet: Bool, artwork: ArtworkCandidate?) {
        if let edit = trackEdits[result.id], edit.hasArtwork { return (true, edit.artwork) }
        switch coverForAll {
        case .official: return (false, nil)
        case .custom(let cover): return (true, cover)
        case .none: return (true, nil)
        }
    }
    /// Album/year/genre values the app filled in itself. A field still equal to
    /// its auto value (or empty) follows the selected cover; once the user
    /// types something else it's left alone.
    private var autoTags = MP3Tags()
    /// The guess made from the video itself, restored when the cover is
    /// switched back to the thumbnail or "No cover".
    private var guessedTags = MP3Tags()

    private func fillTagsFromArtwork() {
        applyingAutomaticTags = true
        defer { applyingAutomaticTags = false }
        let a = selectedArtwork?.source == .iTunes ? selectedArtwork : nil
        func follow(_ field: WritableKeyPath<MP3Tags, String>, _ value: String?) {
            guard tags[keyPath: field].isEmpty || tags[keyPath: field] == autoTags[keyPath: field] else { return }
            let new = value ?? guessedTags[keyPath: field]
            tags[keyPath: field] = new
            autoTags[keyPath: field] = new
        }
        follow(\.album, a?.album)
        follow(\.year, a?.year)
        follow(\.genre, a?.genre)
    }
    @Published var artworkSearchState: ArtworkSearchState = .idle
    /// Show search results ahead of the album cover (after a manual search).
    @Published var artworkResultsFirst = false
    /// The last finished search and how many covers it found, for the status line.
    @Published var lastArtworkSearch: (query: String, count: Int)?
    private var artworkTask: Task<Void, Never>?

    private var fetchTask: Task<Void, Never>?
    private var fetchRunner: ProcessRunner?
    private var lastFetchedURL: String?

    #if DEBUG
    /// Debug builds only: `-openLink <url> [-openFormat mp3|m4a|video]` loads a
    /// link at launch, so UI states can be checked without clicking.
    init() {
        let defaults = UserDefaults.standard
        guard let link = defaults.string(forKey: "openLink") else { return }
        let format = defaults.string(forKey: "openFormat")
        Task { @MainActor in
            open(link: link)
            // Wait for the search (if any) and the selected result's info.
            for _ in 0..<600 {
                if case .loaded = fetchState { break }
                if case .failed = fetchState { break }
                if case .failed = searchState { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            switch format {
            case "mp3": quality = .mp3
            case "m4a": quality = .audioOnly
            case let h? where Int(h) != nil: quality = .height(Int(h)!)   // "360", "1080", "2160"…
            default: break
            }
            if defaults.bool(forKey: "autoDownload") || defaults.string(forKey: "uncheck") != nil
                || defaults.string(forKey: "artQuery") != nil || defaults.string(forKey: "checkOnly") != nil
                || defaults.bool(forKey: "debugEdit") {
                while artworkSearchState == .searching { try? await Task.sleep(nanoseconds: 100_000_000) }
                if let list = defaults.string(forKey: "uncheck") {
                    let indexes = Set(list.split(separator: ",").compactMap { Int($0) })
                    for r in results where indexes.contains(r.index ?? -1) { setChecked(false, for: r) }
                }
                if defaults.bool(forKey: "debugEdit"), results.count > 2 {
                    // Edit track 3's title and cover, then go back to track 1.
                    @MainActor func settle() async {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        for _ in 0..<600 { if case .loaded = fetchState { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
                        while artworkSearchState == .searching || artworkSearchState == .idle { try? await Task.sleep(nanoseconds: 100_000_000) }
                    }
                    select(results[2]); await settle()
                    tags.title = "내가 고친 제목"
                    artworkQuery = "Glenn Gould Goldberg Variations"
                    searchArtwork(userInitiated: true); await settle()
                    select(results[0]); await settle()
                }
                if let list = defaults.string(forKey: "checkOnly") {
                    let indexes = Set(list.split(separator: ",").compactMap { Int($0) })
                    setAllChecked(false)
                    for r in results where indexes.contains(r.index ?? -1) { setChecked(true, for: r) }
                }
                if let query = defaults.string(forKey: "artQuery") {
                    artworkQuery = query
                    searchArtwork(userInitiated: true)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    while artworkSearchState == .searching { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                if defaults.bool(forKey: "autoDownloadAll") { downloadAll() }
                else if defaults.bool(forKey: "autoDownload") { startDownload() }
                // `-autoCancelInProcessing YES` presses Cancel on the first download
                // that reaches its conversion step, to check what is left behind.
                // `-autoCancelInDownloading YES` does the same part-way through the
                // download itself. `-autoCancelDelayMs` sets the pause before the press.
                let inProcessing = defaults.bool(forKey: "autoCancelInProcessing")
                let inDownloading = defaults.bool(forKey: "autoCancelInDownloading")
                if inProcessing || inDownloading {
                    let pause = UInt64(defaults.object(forKey: "autoCancelDelayMs") as? Int ?? 300) * 1_000_000
                    for _ in 0..<6000 {
                        if let item = downloads.first(where: {
                            if inProcessing, case .processing = $0.status { return true }
                            if inDownloading, $0.status == .downloading, ($0.progress ?? 0) > 0.3 { return true }
                            return false
                        }) {
                            try? await Task.sleep(nanoseconds: pause)
                            NSLog("autoCancel: pressing Cancel at %@ %@", String(describing: item.status), String(describing: item.progress))
                            item.cancel()
                            NSLog("autoCancel: now %@", String(describing: item.status))
                            break
                        }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
            }
        }
    }
    #endif

    var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValidURL: Bool {
        guard let u = URL(string: trimmedURL), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && u.host != nil
    }

    /// Loads a link that was dropped on the window or pasted outside a text field.
    func open(link: String) {
        urlText = link.trimmingCharacters(in: .whitespacesAndNewlines)
        submit()
    }

    func clearLink() {
        urlText = ""
        cancelSearch()
        cancelFetch()
        stopPreview()
        results = []
        uncheckedIDs = []
        trackEdits = [:]
        cancelPrefetch()
        coverForAll = .official
        selectedResultID = nil
        playlist = nil
        playlistOffer = nil
        searchState = .idle
        fetchState = .idle
        lastFetchedURL = nil
    }

    func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            open(link: s)
        }
    }

    /// Called when the text changes: a link loads right away, keywords wait
    /// for Return.
    func urlTextChanged() {
        if isValidURL, trimmedURL != lastFetchedURL {
            submit()
        } else if trimmedURL.isEmpty {
            clearLink()
        }
    }

    /// Return in the search field: load a link, or search for keywords.
    func submit() {
        guard !trimmedURL.isEmpty else { return }
        if isValidURL {
            cancelSearch()
            results = []
            uncheckedIDs = []
            trackEdits = [:]
            cancelPrefetch()
            coverForAll = .official
            selectedResultID = nil
            playlist = nil
            playlistOffer = nil
            searchState = .idle
            switch Self.playlistKind(of: trimmedURL) {
            case .playlist:
                loadPlaylist(url: trimmedURL)
            case .videoInPlaylist(let playlistURL):
                playlistOffer = playlistURL
                load(url: trimmedURL)
            case .none:
                load(url: trimmedURL)
            }
        } else {
            search(trimmedURL)
        }
    }

    enum PlaylistKind: Equatable {
        case none
        /// A playlist or album link.
        case playlist
        /// A single video opened from a playlist; carries the playlist's link.
        case videoInPlaylist(String)
    }

    /// Reads the link's `list=` and `v=` parameters.
    static func playlistKind(of link: String) -> PlaylistKind {
        guard let comps = URLComponents(string: link),
              let list = comps.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty
        else { return .none }
        let hasVideo = comps.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false
        guard hasVideo else { return .playlist }
        var p = URLComponents()
        p.scheme = "https"
        p.host = comps.host ?? "www.youtube.com"
        p.path = "/playlist"
        p.queryItems = [URLQueryItem(name: "list", value: list)]
        return .videoInPlaylist(p.string ?? link)
    }

    /// Swaps the single video for its whole playlist.
    func showOfferedPlaylist() {
        guard let url = playlistOffer else { return }
        cancelFetch()
        results = []
        uncheckedIDs = []
        trackEdits = [:]
        cancelPrefetch()
        coverForAll = .official
        selectedResultID = nil
        playlistOffer = nil
        fetchState = .idle
        lastFetchedURL = nil
        loadPlaylist(url: url)
    }

    /// Lists the tracks first (fast); each track's details load when it's
    /// selected or downloaded.
    private func loadPlaylist(url: String) {
        cancelSearch()
        searchState = .searching
        let runner = ProcessRunner()
        searchRunner = runner
        searchTask = Task {
            do {
                guard let (info, rows) = try await YTDLP.playlist(url: url, runner: runner) else {
                    guard !Task.isCancelled else { return }
                    // Not a playlist after all: treat it as a single video.
                    searchState = .idle
                    load(url: url)
                    return
                }
                guard !Task.isCancelled else { return }
                playlist = info
                results = rows
                // An album starts with every track ticked (you usually want
                // all of it). A playlist of mixed songs starts with none, so
                // the Download button can't fetch hundreds by accident.
                uncheckedIDs = info.isAlbum ? [] : Set(rows.map(\.id))
                trackEdits = [:]
                cancelPrefetch()
                coverForAll = .official
                searchState = .done
                if let first = rows.first { select(first) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    private func search(_ query: String) {
        cancelSearch()
        cancelFetch()
        results = []
        uncheckedIDs = []
        trackEdits = [:]
        cancelPrefetch()
        coverForAll = .official
        selectedResultID = nil
        playlist = nil
        playlistOffer = nil
        fetchState = .idle
        lastFetchedURL = nil
        searchState = .searching
        let runner = ProcessRunner()
        searchRunner = runner
        searchTask = Task {
            do {
                let found = try await YTDLP.search(query, runner: runner)
                guard !Task.isCancelled else { return }
                results = found
                uncheckedIDs = []
                trackEdits = [:]
                cancelPrefetch()
                coverForAll = .official
                searchState = .done
                // Open the top match so the right side isn't empty.
                if let first = found.first { select(first) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchRunner?.terminate()
        searchTask = nil
        searchRunner = nil
    }

    /// Picks a row in the results list and loads its formats and tags.
    func select(_ result: SearchResult) {
        guard selectedResultID != result.id || fetchState == .idle else { return }
        selectedResultID = result.id
        load(url: result.url, provisional: result)
        schedulePrefetch()
    }

    // MARK: Prefetching nearby tracks

    /// How many detail lookups run in the background at once. Kept low so a
    /// long list doesn't turn into a burst of requests.
    private let prefetchLimit = 2
    /// How many tracks after the selected one are fetched ahead.
    private let prefetchAhead = 3
    /// At most this many ticked tracks wait to be prefetched.
    private let prefetchTickedCap = 10
    private var prefetchQueue: [String] = []
    private var prefetchRunners: [String: ProcessRunner] = [:]

    /// Queues the details of the tracks the user is likely to open next:
    /// the few after the selected one, the one before it, then ticked tracks.
    /// They land in `infoCache`, so opening them is instant.
    private func schedulePrefetch() {
        guard let index = results.firstIndex(where: { $0.id == selectedResultID }) else { return }
        var wanted: [String] = []
        for offset in 1...prefetchAhead where index + offset < results.count {
            wanted.append(results[index + offset].url)
        }
        if index > 0 { wanted.append(results[index - 1].url) }
        if playlist != nil {
            // Ticked tracks are about to be downloaded; nearest first.
            let ticked = results.enumerated()
                .filter { !uncheckedIDs.contains($0.element.id) }
                .sorted { abs($0.offset - index) < abs($1.offset - index) }
                .prefix(prefetchTickedCap)
                .map(\.element.url)
            wanted.append(contentsOf: ticked)
        }
        var seen = Set<String>()
        prefetchQueue = wanted.filter { url in
            seen.insert(url).inserted && infoCache[url] == nil && prefetchRunners[url] == nil && url != lastFetchedURL
        }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetchRunners.count < prefetchLimit, !prefetchQueue.isEmpty {
            let url = prefetchQueue.removeFirst()
            guard infoCache[url] == nil, prefetchRunners[url] == nil else { continue }
            let runner = ProcessRunner()
            prefetchRunners[url] = runner
            Task {
                let info = try? await YTDLP.fetchInfo(url: url, runner: runner)
                // Ignore results from a list that has since been replaced.
                guard prefetchRunners[url] === runner else { return }
                prefetchRunners[url] = nil
                if let info { infoCache[url] = info }
                // The user opened this track while it was on its way.
                if lastFetchedURL == url, isRefiningInfo, fetchTask == nil {
                    if let info {
                        isRefiningInfo = false
                        refine(with: info)
                    } else if let row = results.first(where: { $0.url == url }) {
                        load(url: url, provisional: row)     // try once more, directly
                    }
                }
                pumpPrefetch()
            }
        }
    }

    /// Stops background lookups (the results list is being replaced).
    private func cancelPrefetch() {
        prefetchQueue = []
        let runners = prefetchRunners
        prefetchRunners = [:]
        runners.values.forEach { $0.terminate() }
    }

    /// Loads the current link or selected result again (after an error).
    func fetch() {
        if let url = lastFetchedURL { load(url: url) } else { submit() }
    }

    /// Track info already fetched this session, by link. Selecting a track a
    /// second time (and "Download all") reuses it instead of asking again,
    /// which takes several seconds per track.
    private var infoCache: [String: VideoInfo] = [:]

    func cachedInfo(for url: String) -> VideoInfo? { infoCache[url] }

    /// True while the selected track is shown from its list row and its full
    /// details (official tags, cover, video resolutions) are still on the way.
    @Published private(set) var isRefiningInfo = false
    /// Why the full details couldn't be fetched; the track stays usable.
    @Published private(set) var detailsError: String?

    /// - Parameter provisional: the list row for this link. When given, the
    ///   track appears at once from what the row already says, and the full
    ///   details replace it when they arrive a few seconds later.
    private func load(url: String, provisional: SearchResult? = nil) {
        cancelFetch()
        if lastFetchedURL != url { stopPreview() }
        lastFetchedURL = url
        detailsError = nil
        if let cached = infoCache[url] {
            show(cached)
            return
        }
        if let provisional {
            isRefiningInfo = true
            show(VideoInfo(entry: provisional))
            // Already being fetched ahead of time: wait for that instead of
            // asking twice. `pumpPrefetch` applies it when it arrives.
            if prefetchRunners[url] != nil { return }
        } else {
            fetchState = .loading
        }
        let runner = ProcessRunner()
        fetchRunner = runner
        fetchTask = Task {
            do {
                let info = try await YTDLP.fetchInfo(url: url, runner: runner)
                infoCache[url] = info
                guard !Task.isCancelled, lastFetchedURL == url else { return }
                if provisional != nil {
                    isRefiningInfo = false
                    refine(with: info)
                } else {
                    show(info)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, lastFetchedURL == url else { return }
                if provisional != nil {
                    // Keep what's on screen; downloading will try again itself.
                    isRefiningInfo = false
                    detailsError = error.localizedDescription
                    if previewAwaitingDetails {
                        previewAwaitingDetails = false
                        preview.fail("Can't preview: the track's details couldn't be loaded.")
                    }
                } else {
                    fetchState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Swaps the stand-in for the real details without disturbing what the
    /// user already did: their tag edits, cover pick and format stay.
    private func refine(with info: VideoInfo) {
        fetchState = .loaded(info)
        resetArtwork(for: info)          // official tags and cover; edits are restored
        // Anything the user switched while waiting is already the standing
        // choice. For Video the real resolution list is known only now.
        applyPreferredQuality(for: info)
        if previewAwaitingDetails { startPreview(info) }
    }

    /// Puts a track's info on screen: tags, covers and format.
    private func show(_ info: VideoInfo) {
        // A pasted link becomes the one row in the results list.
        if results.isEmpty {
            let row = SearchResult(info: info)
            results = [row]
            uncheckedIDs = []
            trackEdits = [:]
            cancelPrefetch()
            coverForAll = .official
            selectedResultID = row.id
            searchState = .done
        }
        fetchState = .loaded(info)
        resetArtwork(for: info)
        // Audio/Video and the format stay as the user last set them; Video
        // lands on the best resolution this track offers.
        applyPreferredQuality(for: info)
    }

    func cancelFetch() {
        fetchTask?.cancel()
        fetchRunner?.terminate()
        fetchTask = nil
        fetchRunner = nil
        isRefiningInfo = false
    }

    private func resetArtwork(for info: VideoInfo) {
        artworkTask?.cancel()
        var guess = MP3Tags.guess(from: info)
        // Album tracks carry their position and fall back to the album's title.
        if let playlist, playlist.isAlbum,
           let index = results.first(where: { $0.id == selectedResultID })?.index {
            guess.trackNumber = index
            guess.trackCount = playlist.count
            if guess.album.isEmpty { guess.album = playlist.title }
        }
        applyingAutomaticTags = true
        tags = guess
        applyingAutomaticTags = false
        autoTags = tags
        guessedTags = tags
        // Album and year that came from the site's own music metadata are
        // facts about this track: picking a different cover must not replace
        // them (it would also move the file to another album folder). A value
        // that can never match keeps `fillTagsFromArtwork` from touching them.
        if info.track != nil {
            if !guess.album.isEmpty { autoTags.album = "\u{1}fixed" }
            if !guess.year.isEmpty { autoTags.year = "\u{1}fixed" }
        }
        artworkQuery = tags.searchTerm
        artworkCandidates = baseArtwork(for: info)
        selectedArtwork = artworkCandidates.first
        artworkSearchState = .idle
        artworkResultsFirst = false
        lastArtworkSearch = nil
        restoreEdits(trackNumber: guess.trackNumber, trackCount: guess.trackCount)
    }

    /// Puts back what the user changed for this track earlier (or the cover
    /// chosen for all tracks).
    private func restoreEdits(trackNumber: Int?, trackCount: Int?) {
        let edit = selectedResultID.flatMap { trackEdits[$0] }
        if var edited = edit?.tags {
            edited.trackNumber = trackNumber
            edited.trackCount = trackCount
            applyingAutomaticTags = true
            tags = edited
            applyingAutomaticTags = false
        }
        var chosen: (isSet: Bool, artwork: ArtworkCandidate?) = (false, nil)
        if let edit, edit.hasArtwork {
            chosen = (true, edit.artwork)
        } else {
            switch coverForAll {
            case .official: break
            case .custom(let cover): chosen = (true, cover)
            case .none: chosen = (true, nil)
            }
        }
        guard chosen.isSet else { return }
        if let cover = chosen.artwork, !artworkCandidates.contains(cover) { artworkCandidates.append(cover) }
        selectedArtwork = chosen.artwork
    }

    /// True when the selected track's cover was chosen by the user (for it
    /// or for all tracks), so an automatic search must not replace it.
    private var selectedCoverIsUserChoice: Bool {
        if let id = selectedResultID, trackEdits[id]?.hasArtwork == true { return true }
        return coverForAll != .official
    }

    /// Covers that don't need a search: the official album cover (first, so
    /// it's the default) and the video thumbnail. The track's own square
    /// cover is preferred; the playlist's is the fallback.
    private func baseArtwork(for info: VideoInfo) -> [ArtworkCandidate] {
        [ArtworkCandidate.albumCover(of: info) ?? playlist?.coverCandidate,
         ArtworkCandidate.thumbnail(of: info)].compactMap { $0 }
    }

    /// Searches once per video, the first time MP3 is picked.
    func searchArtworkIfNeeded() {
        guard artworkSearchState == .idle else { return }
        // Seen this track before: show the covers found then.
        // (An automatic search is reused only for the same words: once the
        // full details arrive the artist and title may read differently.)
        if let id = selectedResultID, let cached = artworkCache[id], case .loaded(let info) = fetchState,
           cached.manual || cached.query == artworkQuery {
            artworkQuery = cached.query
            showArtworkResults(cached.results, for: cached.query, info: info, userInitiated: false)
        } else {
            searchArtwork()
        }
    }

    /// Album-art search results per track (the last search made for it).
    private var artworkCache: [String: (query: String, results: [ArtworkCandidate], manual: Bool)] = [:]

    private func showArtworkResults(_ results: [ArtworkCandidate], for term: String, info: VideoInfo, userInitiated: Bool) {
        let base = baseArtwork(for: info)
        let keepCurrent = (selectedArtwork?.source == .album || selectedCoverIsUserChoice) && !userInitiated
        var all = base + results
        // A cover picked earlier may come from a different search.
        if keepCurrent, let current = selectedArtwork, !all.contains(current) { all.append(current) }
        artworkCandidates = all
        artworkResultsFirst = userInitiated && !results.isEmpty
        lastArtworkSearch = (term, results.count)
        // Pre-select the best match — unless the album's own cover is
        // already chosen, which beats a search guess.
        if userInitiated {
            // Searching by hand and getting results is a choice.
            if let first = results.first { pickArtwork(first) }
        } else if !keepCurrent {
            selectedArtwork = results.first ?? base.first
        }
        artworkSearchState = .done
    }

    /// - Parameter userInitiated: true when the user typed a search. Their
    ///   results then go first and the top one is selected, even over the
    ///   official album cover — they searched because they want another one.
    func searchArtwork(userInitiated: Bool = false) {
        guard case .loaded(let info) = fetchState else { return }
        artworkTask?.cancel()
        let term = artworkQuery
        let trackID = selectedResultID
        artworkSearchState = .searching
        artworkTask = Task {
            do {
                let results = try await ArtworkSearch.search(term)
                if let trackID { artworkCache[trackID] = (term, results, userInitiated) }
                guard !Task.isCancelled, trackID == selectedResultID else { return }
                showArtworkResults(results, for: term, info: info, userInitiated: userInitiated)
            } catch {
                guard !Task.isCancelled else { return }
                artworkSearchState = .failed(error.localizedDescription)
            }
        }
    }

    func startDownload() {
        guard case .loaded(let info) = fetchState else { return }
        // Pressed before the full details arrived: let the download look
        // them up itself, so the file still gets the official tags and cover.
        // Anything the user already changed for this track is kept.
        if isRefiningInfo || detailsError != nil,
           let row = results.first(where: { $0.id == selectedResultID }) {
            let isAlbum = playlist?.isAlbum ?? false
            let item = DownloadItem(entry: row, quality: quality.isAudio ? quality : batchQuality(for: row), batch: DownloadItem.Batch(
                trackNumber: isAlbum ? row.index : nil,
                trackCount: isAlbum ? playlist?.count : nil,
                albumCover: playlist?.coverCandidate,
                albumTitle: playlist?.title,
                cover: coverForAll,
                edit: trackEdits[row.id]))
            downloads.insert(item, at: 0)
            observe(item)
            pumpBatchQueue()
            return
        }
        let item = DownloadItem(info: info, quality: quality,
                                artwork: quality.isAudio ? selectedArtwork : nil,
                                tags: tags)
        downloads.insert(item, at: 0)
        observe(item)
        item.start()
    }

    /// Runs a failed or cancelled download again with the same choices.
    func retry(_ item: DownloadItem) {
        guard let index = downloads.firstIndex(where: { $0.id == item.id }) else { return }
        let again = item.duplicate()
        downloadObservers[item.id] = nil
        downloads[index] = again
        observe(again)
        if again.batch != nil { pumpBatchQueue() } else { again.start() }
    }

    func remove(_ item: DownloadItem) {
        item.cancel()
        downloadObservers[item.id] = nil
        downloads.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        for item in downloads where !item.status.isActive { downloadObservers[item.id] = nil }
        downloads.removeAll { !$0.status.isActive }
    }
}
