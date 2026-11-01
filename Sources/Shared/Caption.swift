import Foundation

struct Caption: Identifiable, Equatable {
    let id: Int
    let japanese: String
    let ruby: [RubyToken]
    let english: String
    /// Where the sentence starts in the video it was heard from.
    var moment: VideoMoment?
    /// What each recognizer heard, the caption's own first, when others
    /// heard it too.
    var versions: [CaptionVersion] = []

    /// The caption as the recognizer `name` heard it; as it is for a name
    /// it does not have.
    func heard(by name: String?) -> Caption {
        guard let version = versions.first(where: { $0.name == name }) else { return self }
        return Caption(id: id, japanese: version.japanese, ruby: version.ruby, english: version.english, moment: moment)
    }
}

/// One recognizer's text of a caption, with its translation.
struct CaptionVersion: Equatable {
    let name: String
    let japanese: String
    let ruby: [RubyToken]
    let english: String
}

/// A stretch of a video: where a sentence was said.
///
/// On the Mac the video is a Chrome tab's; on the phone it is a bundle's,
/// which stands in for the tab and the page.
struct VideoMoment: Equatable {
    let tabID: Int
    /// The page, so a tab that has moved on to the next video isn't sought.
    let url: String
    let seconds: Double
    /// Where the sentence ends, so playing it can stop there.
    var end: Double?
    /// Video seconds per second heard.
    var rate: Double = 1
    /// Whether the video was playing when this was read.
    var playing = false
    /// How long the video is, when it has an end.
    var duration: Double?

    /// This moment `heard` seconds of listening later.
    func advanced(by heard: TimeInterval) -> VideoMoment {
        VideoMoment(tabID: tabID, url: url, seconds: seconds + heard * rate, rate: rate)
    }
}
