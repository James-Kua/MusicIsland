import Foundation

extension String {
    /// Whether the string contains at least one readable character — a letter
    /// (any script, including CJK) or a digit. Lyric lines that are only dashes,
    /// musical notes, or other punctuation (used by NetEase for instrumental or
    /// gap sections) return `false`, so they can be hidden instead of shown as a
    /// stray "long dash".
    var hasReadableContent: Bool {
        rangeOfCharacter(from: .letters) != nil || rangeOfCharacter(from: .decimalDigits) != nil
    }
}
