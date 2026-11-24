import Foundation

/// What the user changed for one track in the results list. Kept while the
/// list is showing, so the changes survive selecting other tracks and are
/// used by "Download all".
struct TrackEdit: Equatable {
    /// Tags as edited; nil when the tags weren't touched.
    var tags: MP3Tags?
    /// True when a cover was picked for this track. `artwork` is then that
    /// cover (nil meaning "No cover").
    var hasArtwork = false
    var artwork: ArtworkCandidate?
    /// The format picked for this track (Audio MP3, Video 1080p, …);
    /// nil when it follows the standing choice.
    var quality: Quality?

    var isEmpty: Bool { tags == nil && !hasArtwork && quality == nil }
}

/// The cover used for tracks that don't have one of their own.
enum CoverChoice: Equatable {
    /// Each track's own official cover (the default).
    case official
    /// One cover the user picked for every track.
    case custom(ArtworkCandidate)
    /// "No cover" for every track.
    case none
}
