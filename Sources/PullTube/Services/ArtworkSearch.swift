import Foundation

/// One album-art choice shown in the MP3 picker.
struct ArtworkCandidate: Identifiable, Hashable {
    enum Source: Hashable { case videoThumbnail, iTunes, album }

    let id: String
    let source: Source
    /// Full-size image that gets embedded.
    let imageURL: URL
    /// Small image for the picker.
    let previewURL: URL
    let title: String
    let subtitle: String?
    /// Album details from iTunes, used to fill empty tag fields.
    var album: String? = nil
    var year: String? = nil
    var genre: String? = nil

    /// The track's own official cover (YouTube Music).
    static func albumCover(of info: VideoInfo) -> ArtworkCandidate? {
        guard let url = info.squareCover else { return nil }
        return ArtworkCandidate(id: "album:\(info.id)", source: .album, imageURL: url, previewURL: url,
                                title: "Album cover", subtitle: info.album ?? info.uploader)
    }

    static func thumbnail(of info: VideoInfo) -> ArtworkCandidate? {
        guard let url = info.thumbnail else { return nil }
        return ArtworkCandidate(id: "thumb:\(info.id)", source: .videoThumbnail,
                                imageURL: url, previewURL: url,
                                title: "Video thumbnail", subtitle: info.uploader)
    }
}

/// Looks up album covers in the iTunes Search API (free, no API key).
enum ArtworkSearch {
    /// A best-guess "artist song" query from the video's metadata.
    static func searchTerm(for info: VideoInfo) -> String {
        MP3Tags.guess(from: info).searchTerm
    }

    /// Searches the user's iTunes store plus the US and Japanese stores (both
    /// carry K-pop and accept Hangul queries; the Korean store has no song
    /// catalogue at all), then interleaves the results so each store's best
    /// match is near the front.
    static func search(_ term: String) async throws -> [ArtworkCandidate] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var stores: [String] = []
        if let region = Locale.current.region?.identifier, region != "KR" { stores.append(region) }
        for s in ["US", "JP"] where !stores.contains(s) { stores.append(s) }

        let perStore: [[[String: Any]]] = try await withThrowingTaskGroup(of: (Int, [[String: Any]]).self) { group in
            for (i, store) in stores.enumerated() {
                group.addTask { (i, try await searchStore(query, country: store)) }
            }
            var out = Array(repeating: [[String: Any]](), count: stores.count)
            var firstError: Error?
            while let next = await group.nextResult() {
                switch next {
                case .success(let (i, results)): out[i] = results
                case .failure(let error): firstError = firstError ?? error
                }
            }
            // Only fail if every store failed.
            if out.allSatisfy(\.isEmpty), let firstError { throw firstError }
            return out
        }

        var interleaved: [[String: Any]] = []
        for rank in 0..<(perStore.map(\.count).max() ?? 0) {
            for list in perStore where rank < list.count { interleaved.append(list[rank]) }
        }

        var seen = Set<String>()
        var candidates: [ArtworkCandidate] = []
        for r in interleaved {
            let collection = (r["collectionId"] as? NSNumber)?.stringValue
            guard let art = r["artworkUrl100"] as? String,
                  // The same album appears once per track and per store; show each cover once.
                  seen.insert(collection ?? art).inserted,
                  let full = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")),
                  let preview = URL(string: art.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
            else { continue }
            let track = r["trackName"] as? String ?? ""
            let artist = r["artistName"] as? String
            let album = r["collectionName"] as? String
            candidates.append(ArtworkCandidate(
                id: "itunes:\(art)", source: .iTunes,
                imageURL: full, previewURL: preview,
                title: album ?? track,
                subtitle: artist,
                album: album,
                year: (r["releaseDate"] as? String).map { String($0.prefix(4)) },
                genre: r["primaryGenreName"] as? String
            ))
            if candidates.count == 12 { break }
        }
        return candidates
    }

    private static func searchStore(_ query: String, country: String) async throws -> [[String: Any]] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
            // English genre names instead of e.g. "ポップ" from the JP store.
            URLQueryItem(name: "lang", value: "en_us"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw YTDLPError(message: "Album art search failed (HTTP \(http.statusCode)).")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }
}
