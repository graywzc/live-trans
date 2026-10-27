import Foundation

enum Jisho {
    /// Jisho takes the search as a path component. It copes with more than a
    /// dictionary form: a conjugated verb, or a phrase it splits into words.
    static func searchURL(for text: String) -> URL? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard !query.isEmpty, let path = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://jisho.org/search/\(path)")
    }
}
