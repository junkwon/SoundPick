import Foundation

/// ID3 tags the user can edit before an MP3 download.
struct MP3Tags: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var year = ""
    var genre = ""
    /// Set for album tracks: position and album length. Turns on the album
    /// layout ("Artist/Album/01 - Title") and writes the track-number tag.
    var trackNumber: Int? = nil
    var trackCount: Int? = nil

    /// "artist title", used as the album-art search query.
    var searchTerm: String {
        [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Best guess from the video's metadata and title.
    static func guess(from info: VideoInfo) -> MP3Tags {
        var tags = MP3Tags()

        // Music sites (YouTube Music, "Topic" channels) give real metadata.
        if let track = info.track, !track.isEmpty {
            tags.title = track
            tags.artist = info.artist ?? cleanChannel(info.uploader)
            tags.album = info.album ?? ""
            tags.year = info.releaseYear.map(String.init) ?? ""
            return tags
        }

        let title = cleanTitle(info.title)

        // "Artist - Song"
        if let r = title.range(of: #"\s[-–—]\s"#, options: .regularExpression) {
            tags.artist = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            tags.title = stripQuotes(String(title[r.upperBound...]))
            return tags
        }

        // "Artist 'Song'" (common for K-pop)
        if let r = title.range(of: #"['"‘“]([^'"’”]+)['"’”]"#, options: .regularExpression) {
            let before = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            tags.title = stripQuotes(String(title[r]))
            tags.artist = before.isEmpty ? cleanChannel(info.uploader) : before
            return tags
        }

        // Plain song title: the channel is probably the artist.
        tags.title = title
        tags.artist = cleanChannel(info.uploader)
        return tags
    }

    /// Drops bracketed extras and "Official MV"-style noise from a video title.
    static func cleanTitle(_ raw: String) -> String {
        var t = raw
        // (Official Video), [MV], 【Lyrics】, 「…」 …
        t = t.replacingOccurrences(of: #"[\(\[【「『][^\)\]】」』]*[\)\]】」』]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"(?i)\b(official\s+(music\s+)?(video|audio|mv)|m/v|mv|lyrics?\s+video|visualizer)\b"#,
            with: " ", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -|/·"))
    }

    private static func cleanChannel(_ channel: String?) -> String {
        var c = channel ?? ""
        for noise in [" - Topic", "VEVO", " Official", "Official "] {
            c = c.replacingOccurrences(of: noise, with: "", options: .caseInsensitive)
        }
        return c.trimmingCharacters(in: .whitespaces)
    }

    private static func stripQuotes(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "'\"‘’“” ").union(.whitespaces))
    }
}
