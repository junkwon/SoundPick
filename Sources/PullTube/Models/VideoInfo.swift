import Foundation

struct VideoInfo: Equatable {
    let url: String
    let id: String
    let title: String
    let uploader: String?
    let thumbnail: URL?
    let duration: Double?
    let site: String?
    /// Distinct video heights available, descending.
    let heights: [Int]
    let hasAudio: Bool
    /// Music metadata when the site provides it (e.g. YouTube Music / "Topic" channels).
    let track: String?
    let artist: String?
    let album: String?
    let releaseYear: Int?
    /// The site's categories ("Music", "Film & Animation", …). Empty when the
    /// site gives none, or for a list-row stand-in.
    let categories: [String]
    /// False only when the site says what this is and it isn't music.
    var mayBeMusic: Bool {
        categories.isEmpty || categories.contains { $0.caseInsensitiveCompare("Music") == .orderedSame }
    }
    /// Square album art, when the site provides it (YouTube Music tracks do),
    /// at 1200px where the image host allows resizing.
    let squareCover: URL?
    /// Streams the preview plays straight from the site, without downloading:
    /// an AAC audio stream, and a small MP4 that carries picture and sound.
    /// Nil for a list-row stand-in (no formats yet). They expire after a few hours.
    let previewAudioURL: URL?
    let previewVideoURL: URL?
    /// Segmented (HLS) stream with picture and sound. Slower to start, but it
    /// opens at once, while the two above may not: see `previewAvailableAt`.
    let previewHLSURL: URL?
    /// When the direct streams start working. Videos that carry an ad refuse
    /// them (HTTP 403) for the first few seconds after the details are fetched.
    let previewAvailableAt: Date?

    init(url: String, json: [String: Any]) {
        self.url = url
        id = json["id"] as? String ?? UUID().uuidString
        title = json["title"] as? String ?? "Untitled"
        track = json["track"] as? String
        // The first credited artist ("Yunchan Lim"), not the joined list
        // ("Yunchan Lim, Johann Sebastian Bach") — it names the artist folder.
        artist = (json["artists"] as? [String])?.first ?? (json["artist"] as? String)
        album = json["album"] as? String
        releaseYear = (json["release_year"] as? NSNumber)?.intValue
        categories = json["categories"] as? [String] ?? []
        squareCover = Self.squareCover(in: json["thumbnails"] as? [[String: Any]] ?? [])
        uploader = (json["uploader"] ?? json["channel"] ?? json["creator"]) as? String
        thumbnail = (json["thumbnail"] as? String).flatMap(URL.init(string:))
        duration = (json["duration"] as? NSNumber)?.doubleValue
        // yt-dlp's extractor names aren't display names ("Youtube").
        let extractor = json["extractor_key"] as? String
        site = extractor == "Youtube" ? "YouTube" : extractor

        let formats = json["formats"] as? [[String: Any]] ?? []
        var hs = Set<Int>()
        var audio = false
        for f in formats {
            let vcodec = f["vcodec"] as? String
            let acodec = f["acodec"] as? String
            if vcodec != "none", let h = (f["height"] as? NSNumber)?.intValue, h > 0 { hs.insert(h) }
            if let acodec, acodec != "none" { audio = true }
        }
        if hs.isEmpty, let h = (json["height"] as? NSNumber)?.intValue { hs.insert(h) }
        heights = hs.sorted(by: >)
        hasAudio = audio || formats.isEmpty

        let streams = Self.previewStreams(in: formats, json: json)
        previewAudioURL = streams.audio
        previewVideoURL = streams.video
        previewHLSURL = streams.hls
        previewAvailableAt = streams.availableAt
    }

    /// Picks what AVPlayer can open directly: plain HTTPS files in AAC / H.264.
    private static func previewStreams(in formats: [[String: Any]], json: [String: Any]) -> (audio: URL?, video: URL?, hls: URL?, availableAt: Date?) {
        func url(_ f: [String: Any]) -> URL? { (f["url"] as? String).flatMap(URL.init(string:)) }
        func number(_ f: [String: Any], _ key: String) -> Double { (f[key] as? NSNumber)?.doubleValue ?? 0 }
        let direct = formats.filter { f in
            let proto = f["protocol"] as? String ?? ""
            return proto == "https" || proto == "http"
        }
        // Audio: AAC without picture; the original language track, best bitrate.
        let audio = direct.filter { f in
            (f["vcodec"] as? String) == "none"
                && (f["acodec"] as? String ?? "").hasPrefix("mp4a")
                && !((f["format_note"] as? String ?? "").localizedCaseInsensitiveContains("drc"))
        }.max { a, b in
            (number(a, "language_preference"), number(a, "abr")) < (number(b, "language_preference"), number(b, "abr"))
        }
        // Video: one file with both picture and sound, the largest up to 480p
        // (on YouTube that is the 360p MP4), else the smallest there is.
        let muxed = direct.filter { f in
            let v = f["vcodec"] as? String ?? "none", a = f["acodec"] as? String ?? "none"
            return v != "none" && a != "none" && (v.hasPrefix("avc1") || v.hasPrefix("h264") || (f["ext"] as? String) == "mp4")
        }
        let small = muxed.filter { number($0, "height") <= 480 }
        let video = small.max { number($0, "height") < number($1, "height") }
            ?? muxed.min { number($0, "height") < number($1, "height") }
        // Sites that only stream in segments: their HLS playlist, if any.
        let hls = formats.lazy.compactMap { ($0["manifest_url"] as? String) }
            .first { $0.contains(".m3u8") }.flatMap(URL.init(string:))
        let videoURL = video.flatMap(url)
        let availableAt = [audio, video].compactMap { $0.map { number($0, "available_at") } }.max()
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return (audio.flatMap(url) ?? videoURL, videoURL, hls, availableAt)
    }

    /// The largest square thumbnail. Google's image host encodes the size in
    /// the URL ("=w544-h544-…"), so it can be asked for 1200px instead.
    private static func squareCover(in thumbnails: [[String: Any]]) -> URL? {
        let squares = thumbnails.compactMap { t -> (String, Int)? in
            guard let url = t["url"] as? String,
                  let w = (t["width"] as? NSNumber)?.intValue,
                  let h = (t["height"] as? NSNumber)?.intValue, w == h, w >= 200 else { return nil }
            return (url, w)
        }
        guard var best = squares.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        if best.contains("googleusercontent.com") {
            best = best.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w1200-h1200", options: .regularExpression)
        }
        return URL(string: best)
    }

    var maxHeight: Int? { heights.first }

    /// Quality choices offered for this video, best first.
    var qualityOptions: [Quality] {
        let tiers = [4320, 2160, 1440, 1080, 720, 480, 360]
        var options: [Quality] = [.best]
        if let maxH = maxHeight {
            // A tier is available if some format reaches at least ~90% of it
            // (e.g. 2026px-tall vertical crops still count as "4K").
            options += tiers.filter { tier in heights.contains { $0 >= tier * 9 / 10 } && tier <= max(maxH, 360) }
                .map(Quality.height)
        }
        if hasAudio { options += [.audioOnly, .mp3] }
        return options
    }

    /// Video choices for the segmented control, best first ("Best" when the
    /// site doesn't report resolutions).
    var videoOptions: [Quality] {
        let heights = qualityOptions.filter { if case .height = $0 { return true } else { return false } }
        return heights.isEmpty ? [.best] : heights
    }

    /// Audio-only choices.
    var audioOptions: [Quality] { hasAudio ? [.mp3, .audioOnly] : [] }

    /// The preselected option: the highest concrete resolution (4K when available).
    var defaultQuality: Quality {
        qualityOptions.first { if case .height = $0 { return true } else { return false } } ?? .best
    }

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let s = Int(duration.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum Quality: Hashable, Identifiable {
    case best
    case height(Int)
    case audioOnly
    case mp3

    var id: String { label }

    /// Compact label for segmented controls and download rows.
    var shortLabel: String {
        switch self {
        case .best: return "Best"
        case .audioOnly: return "M4A"
        case .mp3: return "MP3"
        case .height(let h):
            switch h {
            case 4320: return "8K"
            case 2160: return "4K"
            default: return "\(h)p"
            }
        }
    }

    var fileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .audioOnly: return "m4a"
        default: return "mp4"
        }
    }

    /// Audio-only downloads skip the video/QuickTime conversion step.
    var isAudio: Bool { self == .audioOnly || self == .mp3 }

    var label: String {
        switch self {
        case .best: return "Best available"
        case .audioOnly: return "Audio only (M4A)"
        case .mp3: return "Audio only (MP3)"
        case .height(let h):
            switch h {
            case 4320: return "8K (4320p)"
            case 2160: return "4K (2160p)"
            case 1440: return "1440p"
            default: return "\(h)p"
            }
        }
    }

    var arguments: [String] {
        switch self {
        // Prefer AAC (mp4a) audio so no re-encode is needed; anything else
        // gets converted to AAC afterwards by AudioConverter.
        case .best:
            return ["-f", "bv*+ba[acodec^=mp4a]/bv*+ba/b", "--merge-output-format", "mp4"]
        case .height(let h):
            return ["-f", "bv*[height<=\(h)]+ba[acodec^=mp4a]/bv*[height<=\(h)]+ba/b[height<=\(h)]/bv*+ba/b",
                    "-S", "res:\(h)",
                    "--merge-output-format", "mp4"]
        case .audioOnly:
            return ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
        case .mp3:
            // Best source audio → LAME VBR V0 (~245 kbps). Tags and cover art
            // are written afterwards from the user's input (OutputFinalizer).
            return ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
    }
}
