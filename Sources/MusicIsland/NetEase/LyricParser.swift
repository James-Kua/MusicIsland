import Foundation

/// Parses LRC-format lyrics into timed `LyricLine`s and pairs each line with the
/// nearest available translation line.
enum LyricParser {
    static func parse(_ raw: String, translated: String) -> [LyricLine] {
        let originalLines = parse(raw)
        let translatedLines = parse(translated).filter { !$0.text.isEmpty }
        guard !translatedLines.isEmpty else { return originalLines }

        return originalLines.map { line in
            guard let translatedLine = nearestTranslation(for: line, in: translatedLines) else {
                return line
            }

            return LyricLine(
                time: line.time,
                text: line.text,
                translatedText: translatedLine.text
            )
        }
    }

    static func parse(_ raw: String) -> [LyricLine] {
        raw
            .components(separatedBy: .newlines)
            .flatMap(parseLine)
            .sorted { $0.time < $1.time }
    }

    private static func nearestTranslation(for line: LyricLine, in translatedLines: [LyricLine]) -> LyricLine? {
        let match = translatedLines.min {
            abs($0.time - line.time) < abs($1.time - line.time)
        }
        guard let match, abs(match.time - line.time) <= 0.35 else { return nil }
        return match
    }

    private static func parseLine(_ line: String) -> [LyricLine] {
        guard let regex = timestampRegex else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        guard let lastMatch = matches.last else { return [] }

        let textStart = lastMatch.range.location + lastMatch.range.length
        let text = String(line[line.index(line.startIndex, offsetBy: textStart)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return matches.compactMap { match in
            guard
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line),
                let minutes = Double(line[minuteRange]),
                let seconds = Double(line[secondRange])
            else { return nil }

            var fraction = 0.0
            if let fractionRange = Range(match.range(at: 3), in: line) {
                let rawFraction = String(line[fractionRange])
                let divisor = pow(10.0, Double(rawFraction.count))
                fraction = (Double(rawFraction) ?? 0) / divisor
            }

            return LyricLine(time: minutes * 60 + seconds + fraction, text: text, translatedText: nil)
        }
    }

    private static let timestampRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
    )
}
