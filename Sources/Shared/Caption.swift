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
    /// The recognizer whose text the caption is: of k2, nemo and qwen, the
    /// one the other two agreed with most. Nil from a host that names
    /// none, where it is k2's.
    var heardBy: String?

    /// The name the caption's own text is shown by.
    var ownRecognizer: String { heardBy ?? Caption.defaultRecognizer }
    static let defaultRecognizer = "k2"

    /// The version shown by itself, given what a person picked: theirs;
    /// none, every version, when they took the host's choice back
    /// (`Pick.allName`); else, with others beside it, the one the host
    /// chose, a pick made for them they can take back.
    func shownPick(_ pick: Pick?, hasOthers: Bool) -> String? {
        if let pick { return pick.name == Pick.allName ? nil : pick.name }
        return hasOthers ? heardBy : nil
    }

    /// What a person's pick of `name` is kept as: nothing when it is the
    /// host's choice, which shows anyway; taking a pick back (nil) of a
    /// caption the host chose for shows every version.
    func pickToKeep(_ pick: Pick?) -> Pick? {
        guard let pick else { return heardBy == nil ? nil : .recognizer(Pick.allName) }
        return pick == .recognizer(heardBy ?? "") ? nil : pick
    }

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
