import Foundation

// Port of dashboard.py's parsing layer. Same shapes, same fallbacks — the two
// implementations are meant to agree on what a session is.

let projectsDir: String = ProcessInfo.processInfo.environment["DEJAVU_PROJECTS_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

let weeks = 4
let windowSeconds = Double(weeks * 7 * 24 * 3600)

struct Session: Identifiable, Hashable {
    let id: String
    let path: String
    let title: String
    let project: String
    let branch: String?
    let first: Double
    let last: Double
    let count: Int
    let blob: String
    let files: [String]

    /// ponytail: ~4MB of lowercased duplicate so keystroke filtering is a plain
    /// substring scan instead of ICU case folding. Drop it for an index if the
    /// corpus ever outgrows memory.
    let blobLower: String
}

/// The session on the other end of a cross-session message.
struct Peer: Hashable {
    let name: String
    let mode: String?
}

struct Message: Identifiable, Hashable {
    let id: Int
    let role: String
    let text: String
    let ts: Double?
    /// Set when this arrived from another Claude session rather than the user.
    var from: Peer?
}

// --- cross-session messages --------------------------------------------------

private let crossSessionPrefix = "Another Claude session sent a message"

private func attribute(_ key: String, in attrs: String) -> String? {
    guard let start = attrs.range(of: "\(key)=\"") else { return nil }
    let rest = attrs[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

/// Unwrap a message relayed from another session, keeping only what the peer said.
///
/// The log holds a prologue line, a `<cross-session-message from=… from-name=…>`
/// tag, the body, and then a block of guidance for the receiving session about how
/// to treat peer requests. Only the body is conversation; the rest is machinery.
func parseCrossSession(_ text: String) -> (peer: Peer, body: String)? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix(crossSessionPrefix),
          let open = t.range(of: "<cross-session-message "),
          let tagEnd = t.range(of: ">", range: open.upperBound..<t.endIndex),
          let name = attribute("from-name", in: String(t[open.upperBound..<tagEnd.lowerBound]))
    else { return nil }

    let attrs = String(t[open.upperBound..<tagEnd.lowerBound])
    // A live or interrupted session can leave the tag unclosed; keep what there is.
    let close = t.range(of: "</cross-session-message>")
    let body = String(t[tagEnd.upperBound..<(close?.lowerBound ?? t.endIndex)])
    return (Peer(name: name, mode: attribute("from-mode", in: attrs)),
            body.trimmingCharacters(in: .whitespacesAndNewlines))
}

struct Transcript {
    let title: String
    let project: String
    let messages: [Message]
}

// --- parsing -----------------------------------------------------------------

/// Plain text from a message .content (string, or list of blocks).
func textOf(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let blocks = content as? [Any] {
        return blocks
            .compactMap { ($0 as? [String: Any])?["text"] as? String }
            .joined(separator: " ")
    }
    return ""
}

/// Absolute paths this message's tool calls touched (Read/Write/Edit/...).
func filesOf(_ content: Any?) -> [String] {
    guard let blocks = content as? [Any] else { return [] }
    var out: [String] = []
    for b in blocks {
        guard let d = b as? [String: Any],
              d["type"] as? String == "tool_use",
              let input = d["input"] as? [String: Any] else { continue }
        // ponytail: every file-touching tool names its target *_path; no per-tool table
        for (k, v) in input where k.hasSuffix("_path") {
            if let p = v as? String, !p.isEmpty { out.append(p) }
        }
    }
    return out
}

// Claude Code writes fractional seconds, but don't bet the parse on it.
private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// ISO-8601 (e.g. 2026-08-13T19:24:15.365Z) -> epoch seconds, or nil.
func epoch(_ ts: Any?) -> Double? {
    guard let s = ts as? String else { return nil }
    let d = isoFractional.date(from: s) ?? isoPlain.date(from: s)
    return d?.timeIntervalSince1970
}

/// A user message usable as a fallback title: real prose, not machinery.
func isRealUserText(_ text: String, isMeta: Bool) -> Bool {
    if isMeta { return false }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty || t.hasPrefix("<") { return false }
    if t.hasPrefix("Another Claude session sent a message") { return false }
    return true
}

/// Decoded JSONL lines. Invalid UTF-8 is replaced rather than fatal, and a
/// malformed line is skipped — a live session's last line is often half-written.
private func jsonLines(_ path: String) -> [[String: Any]] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap {
            guard let d = $0.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
            return o as? [String: Any]
        }
}

private func titled(_ custom: String?, _ fallback: String?) -> String {
    let t = custom ?? fallback ?? "(untitled session)"
    return String(t.prefix(200))
}

/// Parse one .jsonl session file into a Session (or nil if it holds no messages).
func parseSession(path: String) -> Session? {
    var customTitle: String?
    var fallbackTitle: String?
    var cwd: String?
    var branch: String?
    var firstTS: Double?
    var lastTS: Double?
    var count = 0
    var blobParts: [String] = []
    var files = Set<String>()
    var sawAssistantText = false

    for o in jsonLines(path) {
        let type = o["type"] as? String
        if type == "custom-title" {
            customTitle = (o["customTitle"] as? String) ?? customTitle
            continue
        }
        guard type == "user" || type == "assistant" else { continue }

        let msg = o["message"] as? [String: Any] ?? [:]
        let text = textOf(msg["content"])
        if !text.isEmpty { blobParts.append(text) }
        if type == "assistant", !text.isEmpty { sawAssistantText = true }
        files.formUnion(filesOf(msg["content"]))

        if let c = o["cwd"] as? String, !c.isEmpty { cwd = c }
        if let b = o["gitBranch"] as? String, !b.isEmpty { branch = b }
        if let ep = epoch(o["timestamp"]) {
            firstTS = firstTS.map { min($0, ep) } ?? ep
            lastTS = lastTS.map { max($0, ep) } ?? ep
        }
        count += 1

        if type == "user", fallbackTitle == nil,
           isRealUserText(text, isMeta: o["isMeta"] as? Bool ?? false) {
            fallbackTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    guard count > 0, let last = lastTS else { return nil }

    // Nothing but slash commands — `/model`, `/clear` — leaves a session with no
    // prose from you and no reply from Claude. That is not a conversation, so it
    // stays out of the list.
    //
    // Assistant output is what saves a command-launched session: `/opsx:explore`
    // and friends also produce no "real" user text, but they do real work. A
    // custom title is a second reprieve — naming a session is deliberate.
    guard fallbackTitle != nil || sawAssistantText || customTitle != nil else { return nil }

    let blob = blobParts.joined(separator: "\n")
    return Session(
        id: (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: ""),
        path: path,
        title: titled(customTitle, fallbackTitle),
        project: cwd ?? "(unknown)",
        branch: branch,
        first: firstTS ?? last,
        last: last,
        count: count,
        blob: blob,
        files: files.sorted(),
        blobLower: blob.lowercased()
    )
}

/// Parsed sessions active within the last 4 weeks, newest activity first.
func scanAll() -> [Session] {
    let fm = FileManager.default
    guard let walk = fm.enumerator(atPath: projectsDir) else { return [] }
    let cutoff = Date().timeIntervalSince1970 - windowSeconds

    var sessions: [Session] = []
    for case let rel as String in walk where rel.hasSuffix(".jsonl") {
        let path = (projectsDir as NSString).appendingPathComponent(rel)
        // cheap pre-filter: skip old files without parsing
        let attrs = try? fm.attributesOfItem(atPath: path)
        guard let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime >= cutoff else { continue }
        if let s = parseSession(path: path), s.last >= cutoff { sessions.append(s) }
    }
    return sessions.sorted { $0.last > $1.last }
}

/// Collapse consecutive messages from the same speaker into one turn.
///
/// A single assistant turn that used tools is written as several entries — one per
/// step. Once the tool calls are dropped and only the text kept, that turn arrives
/// as a run of short messages, each carrying its own "Claude" header. Rendering the
/// run as one turn removes the repeated labels; the parts stay separate paragraphs.
/// The turn keeps the id and timestamp of where it started.
func mergeRuns(_ messages: [Message]) -> [Message] {
    var out: [Message] = []
    for m in messages {
        // A relayed message is its own turn — it is not the user talking.
        if let last = out.last, last.role == m.role, last.from == m.from {
            out[out.count - 1] = Message(id: last.id, role: last.role,
                                         text: last.text + "\n\n" + m.text, ts: last.ts,
                                         from: last.from)
        } else {
            out.append(m)
        }
    }
    return out
}

/// Full ordered messages for one session.
///
/// The Python version globs by id and validates it against a UUID pattern to keep
/// an HTTP query from escaping PROJECTS_DIR. Here the path came from our own scan,
/// so there is no untrusted id to sanitize.
func readTranscript(path: String) -> Transcript {
    var customTitle: String?
    var fallbackTitle: String?
    var project: String?
    var messages: [Message] = []

    for o in jsonLines(path) {
        let type = o["type"] as? String
        if type == "custom-title" {
            customTitle = (o["customTitle"] as? String) ?? customTitle
            continue
        }
        guard type == "user" || type == "assistant" else { continue }

        let msg = o["message"] as? [String: Any] ?? [:]
        let text = textOf(msg["content"])
        if text.isEmpty { continue }
        if let c = o["cwd"] as? String, !c.isEmpty { project = c }

        let role = (msg["role"] as? String) ?? type ?? "user"
        if role == "user", fallbackTitle == nil,
           isRealUserText(text, isMeta: o["isMeta"] as? Bool ?? false) {
            fallbackTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The wrapper is stripped for display; the title check above still sees the
        // original, so a relayed message never becomes a session title.
        let unwrapped = parseCrossSession(text)
        messages.append(Message(id: messages.count, role: role,
                                text: unwrapped?.body ?? text,
                                ts: epoch(o["timestamp"]), from: unwrapped?.peer))
    }
    return Transcript(title: titled(customTitle, fallbackTitle),
                      project: project ?? "(unknown)", messages: mergeRuns(messages))
}

// --- observable state --------------------------------------------------------

@Observable
final class Store {
    /// Everything scanned: the full 4-week window, newest first.
    private(set) var sessions: [Session] = []
    var loading = false

    /// DEJAVU_QUERY seeds the box at launch, so a given search state can be opened
    /// and looked at without driving the UI. (didSet doesn't fire in init; the
    /// refresh that follows recomputes anyway.)
    var query = ProcessInfo.processInfo.environment["DEJAVU_QUERY"] ?? "" {
        didSet { recompute() }
    }
    var scope: Scope = .h48
    /// A day picked off the activity strip (yyyy-MM-dd), or nil.
    var selectedDay: String?

    /// Sessions matching the query, before the scope narrows them. Stored rather
    /// than computed: scanning 4MB of text on every view update would show.
    private(set) var matched: [Session] = []
    /// Always spans the whole window, so a spike outside the current scope stays
    /// visible while you browse a tighter one.
    private(set) var days: [DayBucket] = []

    @MainActor
    func refresh() async {
        loading = true
        sessions = await Task.detached(priority: .userInitiated) { scanAll() }.value
        recompute()
        loading = false
    }

    private func recompute() {
        if let term = fileTerm(query) {
            matched = sessions.filter { !matchingFiles($0, term).isEmpty }
        } else if !query.isEmpty {
            let q = query.lowercased()
            matched = sessions.filter { $0.blobLower.contains(q) }
        } else {
            matched = sessions
        }
        days = dayHistogram(matched)
        // A day that survived the last query may hold nothing now.
        if let d = selectedDay, !days.contains(where: { $0.day == d && $0.sessions > 0 }) {
            selectedDay = nil
        }
    }

    /// What the list shows: matches narrowed to the selected day, or to the scope.
    var visible: [Session] {
        if let day = selectedDay {
            return matched.filter { dayKey($0.last) == day }
        }
        let cutoff = Date().timeIntervalSince1970 - scope.seconds
        return matched.filter { $0.last >= cutoff }
    }

    var completions: [String] {
        guard let term = fileTerm(query), !term.isEmpty else { return [] }
        let hits = completeFiles(visible, term)
        // Picking a completion puts that exact path in the box, which still matches
        // itself — offering it back is noise. Same for a path typed out in full.
        return hits == [term] ? [] : hits
    }

    /// Which session a relayed message came from, if it can be pinned down.
    ///
    /// The tag's `from` is a unix socket path (`uds:/tmp/cc-socks/36299.sock`) that
    /// dies with the process, so the only durable handle is the peer's name — and
    /// names are not unique: three sessions here are titled "sa-federated-design".
    /// Prefer one that was running when the message arrived, then the one active
    /// nearest to it. Ambiguity resolves to a best guess, never to a wrong-looking
    /// certainty, so callers should treat this as a jump, not a citation.
    func sender(_ peer: Peer, at ts: Double?) -> Session? {
        let named = sessions.filter { $0.title == peer.name }
        guard named.count > 1, let ts else { return named.first }
        return named.first { $0.first <= ts && ts <= $0.last }
            ?? named.min { abs($0.last - ts) < abs($1.last - ts) }
    }

    /// The command that picks a conversation back up in a terminal.
    func resumeCommand(_ s: Session) -> String {
        "cd \(s.project.replacingOccurrences(of: " ", with: #"\ "#)) && claude --resume \(s.id)"
    }
}
