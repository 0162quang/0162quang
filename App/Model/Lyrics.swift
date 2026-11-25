import Foundation

/// Lời bài hát: hỗ trợ .lrc (có mốc thời gian) và văn bản thường.
struct Lyrics {
    struct Line: Identifiable {
        let id = UUID()
        let time: Double?
        let text: String
    }
    var lines: [Line]

    var isTimed: Bool { lines.contains { $0.time != nil } }

    static func parse(_ raw: String) -> Lyrics {
        let re = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        var out: [Line] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString
            let matches = re?.matches(in: line, range: NSRange(location: 0, length: ns.length)) ?? []
            if matches.isEmpty {
                if line.hasPrefix("[") && line.hasSuffix("]") && line.contains(":") { continue }   // thẻ [ar:...], [ti:...]
                out.append(Line(time: nil, text: line))
                continue
            }
            let last = matches[matches.count - 1].range
            let text = ns.substring(from: last.location + last.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append(Line(time: mm * 60 + ss + frac, text: text))
            }
        }
        if out.contains(where: { $0.time != nil }) {
            out = out.filter { $0.time != nil }.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        }
        return Lyrics(lines: out)
    }

    /// Chỉ số dòng đang hát tại thời điểm t (giây); nil nếu chưa tới dòng đầu hoặc lời không có mốc.
    func index(at t: Double) -> Int? {
        guard isTimed else { return nil }
        var r: Int?
        for (i, l) in lines.enumerated() {
            if let lt = l.time, lt <= t { r = i } else { break }
        }
        return r
    }
}
