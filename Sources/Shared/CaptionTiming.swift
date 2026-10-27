import Foundation

/// Where the video is among its captions while no sentence is being spoken.
struct Lull: Equatable {
    /// The caption it is next to.
    let captionID: Int
    /// After that caption, the last one spoken; before it when the video has
    /// not reached its first.
    let isAfter: Bool
    /// How far into the video, in whole seconds as the list shows it.
    let seconds: Int
}

/// Which caption the video is on, and how a sentence is played back: the
/// same answers for a Chrome tab on the Mac and a bundle on the phone.
enum CaptionTiming {
    /// Seeking lands this far before the sentence, so its first word isn't
    /// clipped: the VAD only notices speech once it is under way.
    static let seekLead = 0.5
    /// Playing a sentence runs this far past its end, which is an estimate
    /// and shouldn't cut the last word.
    static let seekTail = 0.3

    /// The caption being spoken at `seconds` of the page's video: the one
    /// whose stretch holds it, else the last one that started before it,
    /// within a breath.
    static func current(in captions: [Caption], at seconds: Double, tabID: Int, url: String) -> Int? {
        var before: Caption?
        for caption in captions {
            guard let moment = caption.moment, moment.tabID == tabID, moment.url == url,
                  moment.seconds <= seconds
            else { continue }
            if let end = moment.end, seconds <= end { return caption.id }
            if before?.moment.map({ $0.seconds <= moment.seconds }) ?? true { before = caption }
        }
        guard let before, let moment = before.moment, seconds - (moment.end ?? moment.seconds) < 2 else { return nil }
        return before.id
    }

    /// Where `seconds` of the page's video is among its captions when no
    /// sentence is being spoken: after the last one that started before it,
    /// however long ago, else before the first one after it.
    static func lull(in captions: [Caption], at seconds: Double, tabID: Int, url: String) -> Lull? {
        var before: Caption?
        var after: Caption?
        for caption in captions {
            guard let moment = caption.moment, moment.tabID == tabID, moment.url == url else { continue }
            if moment.seconds <= seconds {
                if before?.moment.map({ $0.seconds <= moment.seconds }) ?? true { before = caption }
            } else if after?.moment.map({ moment.seconds < $0.seconds }) ?? true {
                after = caption
            }
        }
        guard let beside = before ?? after else { return nil }
        return Lull(captionID: beside.id, isAfter: before != nil, seconds: Int(max(seconds, 0)))
    }
}
