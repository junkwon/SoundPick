import Foundation

/// One row in the results list: a video found by keyword search, or the
/// single video behind a pasted link.
struct SearchResult: Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    let channel: String?
    let duration: Double?
    let thumbnail: URL?
    /// 1-based position when the row comes from a playlist or album.
    var index: Int? = nil

    /// From a yt-dlp `--flat-playlist` search entry.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let url = (json["url"] ?? json["webpage_url"]) as? String else { return nil }
        self.id = id
        self.url = url
        title = json["title"] as? String ?? "Untitled"
        channel = (json["channel"] ?? json["uploader"]) as? String
        duration = (json["duration"] as? NSNumber)?.doubleValue
        thumbnail = ((json["thumbnails"] as? [[String: Any]])?.last?["url"] as? String).flatMap(URL.init(string:))
    }

    /// For a link that was pasted directly.
    init(info: VideoInfo) {
        id = info.id
        url = info.url
        title = info.title
        channel = info.uploader
        duration = info.duration
        thumbnail = info.thumbnail
    }

    var subtitle: String {
        [channel, duration.flatMap(Self.clock)].compactMap { $0 }.joined(separator: " · ")
    }

    private static func clock(_ seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A playlist or YouTube Music album whose tracks fill the results list.
struct PlaylistInfo: Equatable {
    let url: String
    let title: String
    let count: Int
    let cover: URL?
    /// A real album (one release) rather than a playlist of mixed songs.
    /// Albums get track numbers, an album folder and a shared cover;
    /// playlists don't, because their tracks come from different albums.
    let isAlbum: Bool

    /// The album's own cover as an album-art choice.
    var coverCandidate: ArtworkCandidate? {
        guard isAlbum, let cover else { return nil }
        return ArtworkCandidate(id: "album:\(url)", source: .album, imageURL: cover, previewURL: cover,
                                title: "Album cover", subtitle: title)
    }

    /// YouTube Music album links have list IDs starting "OLAK5uy_". Curated
    /// and personal playlists ("RDCLAK5uy_…", "PL…") also have square covers,
    /// so the cover's shape can't tell them apart.
    static func isAlbumLink(_ link: String) -> Bool {
        let list = URLComponents(string: link)?.queryItems?.first { $0.name == "list" }?.value ?? ""
        return list.hasPrefix("OLAK5uy_")
    }

    /// From a yt-dlp `--flat-playlist -J` result; nil when it isn't a playlist.
    static func parse(_ json: [String: Any], url: String) -> (PlaylistInfo, [SearchResult])? {
        guard json["_type"] as? String == "playlist",
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        var rows = entries.compactMap(SearchResult.init(json:))
        for i in rows.indices { rows[i].index = i + 1 }

        // Largest thumbnail; square means it's album art.
        let thumbs = (json["thumbnails"] as? [[String: Any]] ?? []).compactMap { t -> (URL, Int, Int)? in
            guard let u = (t["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (u, (t["width"] as? NSNumber)?.intValue ?? 0, (t["height"] as? NSNumber)?.intValue ?? 0)
        }
        // The unsigned "maxresdefault" entry yt-dlp lists for albums returns
        // 404; only signed URLs (with a query) actually load.
        let best = thumbs.filter { $0.0.query != nil }.max { $0.1 < $1.1 } ?? thumbs.max { $0.1 < $1.1 }
        var title = json["title"] as? String ?? "Playlist"
        if title.hasPrefix("Album - ") { title.removeFirst("Album - ".count) }
        let info = PlaylistInfo(url: url, title: title, count: rows.count, cover: best?.0,
                                isAlbum: isAlbumLink(url))
        return (info, rows)
    }
}

extension VideoInfo {
    /// A stand-in built from a list row (title, channel, length, thumbnail),
    /// used until the track's full details arrive. It has no format list, so
    /// Video offers "Best" only; MP3/M4A work as usual.
    init(entry: SearchResult) {
        var json: [String: Any] = ["id": entry.id, "title": entry.title]
        if let channel = entry.channel { json["uploader"] = channel }
        if let thumb = entry.thumbnail { json["thumbnail"] = thumb.absoluteString }
        if let duration = entry.duration { json["duration"] = duration }
        self.init(url: entry.url, json: json)
    }
}
