import Foundation

/// One lyric line. `time` is set for synced (.lrc) lyrics; nil for plain text.
struct LyricsLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    let time: TimeInterval?
    let text: String
}

enum LyricsParser {
    /// Parse `.lrc` (synced — `[mm:ss.xx] text`, possibly multiple stamps per
    /// line) or plain text. Returns lines in time order; plain text keeps file
    /// order with nil times.
    static func parse(_ raw: String) -> [LyricsLine] {
        var out: [LyricsLine] = []
        var sawTimestamp = false
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let stamps = timestamps(in: line)
            if stamps.isEmpty {
                let text = line.trimmingCharacters(in: .whitespaces)
                // Skip `.lrc` metadata tags like [ar:..], [ti:..], [by:..].
                if text.isEmpty || (text.hasPrefix("[") && text.hasSuffix("]")) { continue }
                out.append(LyricsLine(time: nil, text: text))
            } else {
                sawTimestamp = true
                let text = textAfterStamps(line).trimmingCharacters(in: .whitespaces)
                for t in stamps { out.append(LyricsLine(time: t, text: text)) }
            }
        }
        if sawTimestamp {
            out.sort { ($0.time ?? 0) < ($1.time ?? 0) }
        }
        return out
    }

    /// Extract `[mm:ss.xx]` / `[mm:ss]` timestamps from the start of a line.
    private static func timestamps(in line: String) -> [TimeInterval] {
        var result: [TimeInterval] = []
        var rest = Substring(line)
        while rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inside = rest[rest.index(after: rest.startIndex)..<close]
            if let t = parseStamp(String(inside)) { result.append(t) }
            else { break }   // not a timestamp (e.g. metadata tag) → stop
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    private static func textAfterStamps(_ line: String) -> String {
        var rest = Substring(line)
        while rest.first == "[", let close = rest.firstIndex(of: "]"),
              parseStamp(String(rest[rest.index(after: rest.startIndex)..<close])) != nil {
            rest = rest[rest.index(after: close)...]
        }
        return String(rest)
    }

    /// "mm:ss.xx" / "mm:ss" → seconds. nil if not a timestamp.
    private static func parseStamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }
        guard let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
