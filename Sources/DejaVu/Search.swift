import Foundation
import SwiftUI

// Port of dashboard.py's query layer: plain-text search, `file:` search with
// completions, scope windows, and the daily activity histogram.

let filePrefix = "file:"
let maxCompletions = 20
let maxDayProjects = 4

enum Scope: String, CaseIterable, Identifiable {
    case h48 = "48h"
    case d7 = "7d"
    case all = "All"

    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .h48: 48 * 3600
        case .d7: 7 * 24 * 3600
        case .all: windowSeconds
        }
    }
}

/// A letter, a digit, or an underscore. Asked of the regex engine rather than
/// spelled out, so "word character" has one definition here and no ASCII table of
/// our own. It is the same one `rg -w` and every editor's "whole word" box use.
func isWordChar(_ c: Character?) -> Bool {
    guard let c else { return false }
    return String(c).range(of: "\\w", options: .regularExpression) != nil
}

/// A typed query resolved into what to match and how.
///
/// One value for four consumers: the list filter, the path filter, the snippet and
/// the highlight. They agreed before only because all four happened to spell
/// "case-insensitive substring" the same way. A second rule makes that luck, and a
/// row that matched with nothing highlighted is the shape of the bug, so the rule
/// lives here and they ask for it rather than each deciding again.
struct Match {
    /// As typed, minus the quotes.
    let term: String
    /// Folded once here rather than per session inside the filter.
    let lower: String
    /// The query was quoted: the term counts only where it stands as a whole word.
    let whole: Bool

    /// nil means no query at all: an empty box, or a quotation with nothing inside
    /// it. Same rule `fileTerm` follows for a bare `file:` prefix.
    init?(_ term: String, whole: Bool = false) {
        guard !term.isEmpty else { return nil }
        self.term = term
        self.lower = term.lowercased()
        self.whole = whole
    }

    /// Does an occurrence stand on its own?
    ///
    /// Generic over Character collections because `String` is one and
    /// `AttributedString.CharacterView` is another, which is what keeps the text
    /// search and the highlight on a single rule. It has to be a predicate rather
    /// than a pattern: `AttributedString.range(of:options:)` *silently ignores*
    /// `.regularExpression`, so a regex highlight paints nothing and reports
    /// nothing.
    ///
    /// A side is guarded only where the term's own edge there is a word character,
    /// so `"$PATH"` and `"foo(bar)"` still find themselves. That is also why this
    /// is not `\b`: `\b` asserts a *transition*, and `\b\$PATH\b` can never match
    /// `$PATH`, because there is no word character before the `$` to transition from.
    func bounded<C: BidirectionalCollection>(_ chars: C, _ hit: Range<C.Index>) -> Bool
        where C.Element == Character {
        guard whole else { return true }
        let before = hit.lowerBound > chars.startIndex
            ? chars[chars.index(before: hit.lowerBound)] : nil
        let after = hit.upperBound < chars.endIndex ? chars[hit.upperBound] : nil
        return !(isWordChar(term.first) && isWordChar(before))
            && !(isWordChar(term.last) && isWordChar(after))
    }

    /// The first occurrence that counts, or nil.
    ///
    /// A rejected occurrence advances the cursor one character past its start, the
    /// way a regex engine's own scan does, rather than past the whole match:
    /// skipping it could hide a valid occurrence overlapping a rejected one.
    func range(in text: String) -> Range<String.Index>? {
        var cursor = text.startIndex
        while let hit = text.range(of: term, options: .caseInsensitive,
                                   range: cursor..<text.endIndex) {
            if bounded(text, hit) { return hit }
            cursor = text.index(after: hit.lowerBound)
        }
        return nil
    }

    /// Does this conversation match? The substring test comes first: a whole-word
    /// hit is always also a substring hit, so the cheap test can only reject what
    /// the walk would, and an unquoted query, which is every query typed before
    /// this existed, never pays for the walk at all. This runs over the whole
    /// window on every keystroke, which is what `blobLower` is precomputed for.
    func hits(_ s: Session) -> Bool {
        s.blobLower.contains(lower) && (!whole || range(in: s.blob) != nil)
    }
}

/// What a typed query means: quoted, it matches whole words; bare, any occurrence.
///
/// Quoting is decided by the first character, the way `fileTerm` decides on a
/// prefix. No tokenising, so `log "level"` is one quoted-from-the-start query and
/// an unterminated quote is simply a quoted search of what is there so far. The box
/// recomputes on every keystroke, so there is no half-typed state to report.
func matcher(_ q: String) -> Match? {
    guard q.hasPrefix("\"") else { return Match(q) }
    var inside = q.dropFirst()
    if inside.hasSuffix("\"") { inside = inside.dropLast() }
    return Match(String(inside), whole: true)
}

/// The path fragment of a `file:` query, or nil for an ordinary search.
func fileTerm(_ q: String) -> String? {
    guard q.lowercased().hasPrefix(filePrefix) else { return nil }
    return String(q.dropFirst(filePrefix.count)).trimmingCharacters(in: .whitespaces)
}

func matchingFiles(_ s: Session, _ m: Match?) -> [String] {
    guard let m else { return s.files }
    return s.files.filter { m.range(in: $0) != nil }
}

/// Paths to offer as autocomplete: closest match to the fragment first.
func completeFiles(_ sessions: [Session], _ m: Match) -> [String] {
    let hits = Set(sessions.flatMap { matchingFiles($0, m) })
    // basename matches beat directory matches; shorter paths beat deeper ones
    return hits.sorted { a, b in
        let aBase = m.range(in: (a as NSString).lastPathComponent) != nil
        let bBase = m.range(in: (b as NSString).lastPathComponent) != nil
        if aBase != bBase { return aBase }
        if a.count != b.count { return a.count < b.count }
        return a < b
    }
    .prefix(maxCompletions)
    .map { $0 }
}

/// Text around the first match, with ellipses where it was cut.
///
/// Searches the original string rather than a lowercased copy: case folding can
/// change a string's length, which would slide the slice off the match.
func snippet(_ blob: String, _ m: Match, width: Int = 160) -> String? {
    guard let hit = m.range(in: blob) else { return nil }
    let pad = width / 2
    let start = blob.index(hit.lowerBound, offsetBy: -pad, limitedBy: blob.startIndex)
        ?? blob.startIndex
    let end = blob.index(hit.upperBound, offsetBy: pad, limitedBy: blob.endIndex)
        ?? blob.endIndex
    let body = blob[start..<end]
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return (start > blob.startIndex ? "…" : "") + body + (end < blob.endIndex ? "…" : "")
}

/// Paint every occurrence that counts, not just the first. Used by both the
/// transcript and the list rows, so a hit looks the same wherever you see it. A
/// quoted query paints only whole words, so what is marked is what matched.
func highlighting(_ attributed: AttributedString, _ m: Match?) -> AttributedString {
    guard let m else { return attributed }
    var out = attributed
    var cursor = out.startIndex
    while cursor < out.endIndex,
          let hit = out[cursor...].range(of: m.term, options: .caseInsensitive) {
        if m.bounded(out.characters, hit) {
            out[hit].backgroundColor = .yellow.opacity(0.35)
            cursor = hit.upperBound
        } else {
            // One character on, not past the match: see `Match.range(in:)`.
            cursor = out.characters.index(after: hit.lowerBound)
        }
    }
    return out
}

func highlighted(_ s: String, _ m: Match?) -> AttributedString {
    highlighting(AttributedString(s), m)
}

// --- repos -------------------------------------------------------------------

/// Each working directory mapped to the repo it belongs to: the shallowest other
/// directory in the set that contains it, or itself.
///
/// One repo turns up as many working directories: a git worktree under
/// `.claude/worktrees/`, a source subdirectory you happened to be in, an openspec
/// change dir. All of them sit under the repo on disk, so plain path text groups
/// them, and unlike walking up to a `.git` it stays right for a directory that has
/// since moved and works for a folder that was never a repo at all.
///
/// ponytail: quadratic over *distinct* directories, 34 of them here, once per
/// scan. A sorted-prefix walk only if that ever reaches thousands.
func repos(_ cwds: some Sequence<String>) -> [String: String] {
    let all = Set(cwds)
    // Shallowest wins, so /x/repo, /x/repo/a and /x/repo/a/b are one repo rather
    // than two. The trailing slash is what keeps /x/repo-two out of /x/repo.
    return Dictionary(uniqueKeysWithValues: all.map { cwd in
        (cwd, all.filter { cwd.hasPrefix($0 + "/") }.min { $0.count < $1.count } ?? cwd)
    })
}

/// Every repo these conversations belong to with how many it holds, largest first,
/// alongside the working-directory map they were grouped by.
///
/// `keeping` is listed even when it holds nothing: the window slides, so the repo
/// someone picked can empty out under them, and it has to stay clickable.
func repoTally(_ sessions: [Session], keeping picked: String? = nil)
    -> (map: [String: String], counts: [(repo: String, count: Int)]) {
    let map = repos(sessions.map(\.project))
    var counts: [String: Int] = [:]
    for s in sessions { counts[map[s.project] ?? s.project, default: 0] += 1 }
    if let picked, counts[picked] == nil { counts[picked] = 0 }
    return (map, counts
        .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        .map { (repo: $0.key, count: $0.value) })
}

/// A path as it reads in the UI: the last component, which is what anyone calls
/// the repo. The full path lives in the tooltip.
func repoLabel(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

// --- activity strip ----------------------------------------------------------

struct DayBucket: Identifiable {
    let day: String            // yyyy-MM-dd, local time
    var messages = 0
    var sessions = 0
    var projects: [(name: String, messages: Int)] = []

    var id: String { day }
}

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func dayKey(_ epochSeconds: Double) -> String {
    dayFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
}

/// Daily message volume across the whole window, oldest day first.
///
/// A conversation lands on the day it was last active, the same instant the
/// list sorts and labels it by, so the strip and the list agree.
func dayHistogram(_ sessions: [Session], days: Int = weeks * 7) -> [DayBucket] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let span = (0..<days).reversed().map {
        dayFormatter.string(from: cal.date(byAdding: .day, value: -$0, to: today)!)
    }

    var buckets = [String: DayBucket]()
    var projectTotals = [String: [String: Int]]()
    for day in span { buckets[day] = DayBucket(day: day) }

    for s in sessions {
        let key = dayKey(s.last)
        // older than the window, or (rarely) a clock-skewed future stamp
        guard buckets[key] != nil else { continue }
        buckets[key]!.messages += s.count
        buckets[key]!.sessions += 1
        projectTotals[key, default: [:]][s.project, default: 0] += s.count
    }

    return span.map { day in
        var b = buckets[day]!
        b.projects = (projectTotals[day] ?? [:])
            .sorted { $0.value > $1.value }
            .prefix(maxDayProjects)
            .map { (name: $0.key, messages: $0.value) }
        return b
    }
}
