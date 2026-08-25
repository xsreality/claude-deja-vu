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

/// The path fragment of a `file:` query, or nil for an ordinary search.
func fileTerm(_ q: String) -> String? {
    guard q.lowercased().hasPrefix(filePrefix) else { return nil }
    return String(q.dropFirst(filePrefix.count)).trimmingCharacters(in: .whitespaces)
}

func matchingFiles(_ s: Session, _ term: String) -> [String] {
    let t = term.lowercased()
    return t.isEmpty ? s.files : s.files.filter { $0.lowercased().contains(t) }
}

/// Paths to offer as autocomplete: closest match to the fragment first.
func completeFiles(_ sessions: [Session], _ term: String) -> [String] {
    let hits = Set(sessions.flatMap { matchingFiles($0, term) })
    let t = term.lowercased()
    // basename matches beat directory matches; shorter paths beat deeper ones
    return hits.sorted { a, b in
        let aBase = !((a as NSString).lastPathComponent.lowercased().contains(t))
        let bBase = !((b as NSString).lastPathComponent.lowercased().contains(t))
        if aBase != bBase { return !aBase }
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
func snippet(_ blob: String, term: String, width: Int = 160) -> String? {
    guard let hit = blob.range(of: term, options: .caseInsensitive) else { return nil }
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

/// Paint every occurrence of `term`, not just the first — used by both the
/// transcript and the list rows, so a hit looks the same wherever you see it.
func highlighting(_ attributed: AttributedString, _ term: String?) -> AttributedString {
    guard let term, !term.isEmpty else { return attributed }
    var out = attributed
    var cursor = out.startIndex
    while cursor < out.endIndex,
          let hit = out[cursor...].range(of: term, options: .caseInsensitive) {
        out[hit].backgroundColor = .yellow.opacity(0.35)
        cursor = hit.upperBound
    }
    return out
}

func highlighted(_ s: String, _ term: String?) -> AttributedString {
    highlighting(AttributedString(s), term)
}

// --- repos -------------------------------------------------------------------

/// Each working directory mapped to the repo it belongs to: the shallowest other
/// directory in the set that contains it, or itself.
///
/// One repo turns up as many working directories — a git worktree under
/// `.claude/worktrees/`, a source subdirectory you happened to be in, an openspec
/// change dir. All of them sit under the repo on disk, so plain path text groups
/// them, and unlike walking up to a `.git` it stays right for a directory that has
/// since moved and works for a folder that was never a repo at all.
///
/// ponytail: quadratic over *distinct* directories — 34 of them here, once per
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
/// A conversation lands on the day it was last active — the same instant the
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
