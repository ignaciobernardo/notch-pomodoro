import Foundation

/// Appends sessions to a Markdown file, one `## día` section per day with a table
/// and a running "total foco" line. The file is only touched when a session ends.
///
///     ## domingo 15 de noviembre 2026
///
///     | inicio | fin | tipo | tiempo | tarea |
///     | --- | --- | --- | --- | --- |
///     | 10:02 | 10:27 | foco | 25:00 | landing |
///
///     total foco: 25 min · 1 pomodoro
struct MarkdownLog {
    let url: URL

    static let header = "| inicio | fin | tipo | tiempo | tarea |"
    static let sep = "| --- | --- | --- | --- | --- |"
    static let totalPrefix = "total foco:"

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.dateFormat = "EEEE d 'de' MMMM yyyy"
        return f
    }()

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func add(start: Date, end: Date, phase: Phase, seconds: Int, cut: Bool, task: String) {
        let kind = phase.label + (cut ? " cortado" : "")
        let row = "| \(Self.hm.string(from: start)) | \(Self.hm.string(from: end)) | \(kind) | \(clock(seconds)) | \(clean(task)) |"
        let title = "## " + Self.day.string(from: start)

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# pomodoros\n"
        var lines = text.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }

        if let i = lines.firstIndex(of: title) {
            var j = i + 1
            while j < lines.count, !lines[j].hasPrefix("## ") { j += 1 }
            let body = Array(lines[(i + 1)..<j])
            var rows = body.filter(Self.isRow)
            var notes = body.filter { !$0.hasPrefix("|") && !$0.hasPrefix(Self.totalPrefix) }
            while let f = notes.first, f.trimmingCharacters(in: .whitespaces).isEmpty { notes.removeFirst() }
            while let l = notes.last, l.trimmingCharacters(in: .whitespaces).isEmpty { notes.removeLast() }
            rows.append(row)
            var section = Self.section(title: title, rows: rows)
            if !notes.isEmpty { section += [""] + notes }
            if j < lines.count { section.append("") }
            lines.replaceSubrange(i..<j, with: section)
        } else {
            lines += [""] + Self.section(title: title, rows: [row])
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("pomodoro: no pude escribir %@: %@", url.path, String(describing: error))
        }
    }

    private static func section(title: String, rows: [String]) -> [String] {
        [title, "", header, sep] + rows + ["", totalLine(rows)]
    }

    private static func isRow(_ l: String) -> Bool {
        l.hasPrefix("|") && l != header && !l.hasPrefix("| ---")
    }

    private static func totalLine(_ rows: [String]) -> String {
        var secs = 0
        var full = 0
        for r in rows {
            let cols = r.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 5, cols[3].hasPrefix("foco") else { continue }
            let t = cols[4].split(separator: ":").compactMap { Int($0) }
            if t.count == 2 { secs += t[0] * 60 + t[1] }
            if cols[3] == "foco" { full += 1 }
        }
        let m = secs / 60
        let time = m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
        return "\(totalPrefix) \(time) · \(full) \(full == 1 ? "pomodoro" : "pomodoros")"
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
