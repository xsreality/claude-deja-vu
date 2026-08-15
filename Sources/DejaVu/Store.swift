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
    /// Names of other sessions that relayed a message into this one.
    let peers: [String]

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
    // A Substring, not a trimmed copy: this runs on every message of every session
    // during a scan, and almost none of them match.
    let t = text.drop { $0.isWhitespace }
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

/// What a conversation cost and what it did, totalled over one transcript.
///
/// Free to collect: the detail pane already reads every line of the file. None of
/// this is gathered during a scan, where it would be 300 files' worth of work for
/// numbers only one session ever shows.
struct Stats {
    /// Every model that answered, in the order they first appear. Sessions do mix
    /// them — a model switch mid-conversation is one file with two names in it.
    var models: [String] = []
    /// Everything sent, cached or not: what the conversation cost to keep going.
    var input = 0
    var output = 0
    var thinking = 0
    /// Tool calls by name, most used first.
    var tools: [(name: String, count: Int)] = []
    /// Wall clock from the first message to the last.
    var span: Double = 0

    var toolCalls: Int { tools.reduce(0) { $0 + $1.count } }
}

struct Transcript {
    let title: String
    let project: String
    let messages: [Message]
    var stats = Stats()
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
    var peers = Set<String>()

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
        if let peer = parseCrossSession(text)?.peer { peers.insert(peer.name) }
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
        peers: peers.sorted(),
        blobLower: blob.lowercased()
    )
}

/// What a previous scan made of one file. `session` is nil for a file that parsed
/// to nothing — worth remembering, so it isn't re-parsed on every pass.
struct ScannedFile {
    let mtime: Double
    let session: Session?
}

/// Parsed sessions active within the last 4 weeks, newest activity first, plus
/// what to hand back as `cache` next time.
///
/// Reusing unchanged files matters once the watcher is running: a live
/// conversation appends every few seconds, and a full parse of the window takes
/// about as long as the gap between writes. With the cache a rescan re-reads only
/// the file that actually changed.
func scanAll(cache: [String: ScannedFile] = [:]) -> (sessions: [Session], cache: [String: ScannedFile]) {
    let fm = FileManager.default
    guard let walk = fm.enumerator(atPath: projectsDir) else { return ([], [:]) }
    let cutoff = Date().timeIntervalSince1970 - windowSeconds

    var sessions: [Session] = []
    var scanned: [String: ScannedFile] = [:]
    for case let rel as String in walk where rel.hasSuffix(".jsonl") {
        let path = (projectsDir as NSString).appendingPathComponent(rel)
        // cheap pre-filter: skip old files without parsing
        let attrs = try? fm.attributesOfItem(atPath: path)
        guard let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime >= cutoff else { continue }
        let hit = cache[path].flatMap { $0.mtime == mtime ? $0 : nil }
            ?? ScannedFile(mtime: mtime, session: parseSession(path: path))
        scanned[path] = hit
        if let s = hit.session, s.last >= cutoff { sessions.append(s) }
    }
    return (sessions.sorted { $0.last > $1.last }, scanned)
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
    var stats = Stats()
    var toolCounts: [String: Int] = [:]
    var first: Double?
    var last: Double?

    for o in jsonLines(path) {
        let type = o["type"] as? String
        if type == "custom-title" {
            customTitle = (o["customTitle"] as? String) ?? customTitle
            continue
        }
        guard type == "user" || type == "assistant" else { continue }

        let msg = o["message"] as? [String: Any] ?? [:]

        // Before the empty-text check below: a turn that only called tools carries
        // no text at all, and those are exactly the ones with tools to count.
        if let model = msg["model"] as? String, !stats.models.contains(model) {
            stats.models.append(model)
        }
        if let usage = msg["usage"] as? [String: Any] {
            // Cache reads are the bulk of it, and they are still tokens that went
            // to the model — one "in" number, broken out in the tooltip.
            for key in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                stats.input += usage[key] as? Int ?? 0
            }
            stats.output += usage["output_tokens"] as? Int ?? 0
            stats.thinking += (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]
                as? Int ?? 0
        }
        for b in msg["content"] as? [Any] ?? [] {
            guard let d = b as? [String: Any], d["type"] as? String == "tool_use",
                  let name = d["name"] as? String else { continue }
            toolCounts[name, default: 0] += 1
        }
        if let ep = epoch(o["timestamp"]) {
            first = first.map { min($0, ep) } ?? ep
            last = last.map { max($0, ep) } ?? ep
        }

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
    stats.tools = toolCounts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        .map { (name: $0.key, count: $0.value) }
    stats.span = (last ?? 0) - (first ?? 0)
    return Transcript(title: titled(customTitle, fallbackTitle),
                      project: project ?? "(unknown)", messages: mergeRuns(messages),
                      stats: stats)
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
    /// A topic chip picked from the cross-reference results, or nil.
    var cluster: String?

    /// Summaries and topics from the last `claude -p` run, if there was one.
    private(set) var insights: Insights? = loadInsights() {
        didSet { labels = insights?.labelsByID ?? [:] }
    }
    /// Topic labels per session id, inverted once rather than per rendered row.
    private var labels: [String: [String]] = [:]
    var analyzing = false
    /// What the last cross-reference run had to say, shown next to the button.
    var status: String?

    /// Sessions matching the query, before the scope narrows them. Stored rather
    /// than computed: scanning 4MB of text on every view update would show.
    private(set) var matched: [Session] = []
    /// Always spans the whole window, so a spike outside the current scope stays
    /// visible while you browse a tighter one.
    private(set) var days: [DayBucket] = []

    private var watcher: Watcher?
    /// Last scan's per-file results, so a rescan only re-parses what changed.
    private var scanCache: [String: ScannedFile] = [:]
    private var scanning = false
    private var rescanWhenDone = false

    init() {
        labels = insights?.labelsByID ?? [:]
    }

    /// Rescan. `quiet` is for the watcher: a live conversation writes every few
    /// seconds, and a spinner blinking on every one of those reads as breakage.
    @MainActor
    func refresh(quiet: Bool = false) async {
        // Writes that land mid-scan don't start a second one — they queue a single
        // repeat, so a burst can't stack up scans but also can't be lost.
        guard !scanning else { return rescanWhenDone = true }
        scanning = true
        if !quiet { loading = true }
        let cache = scanCache
        let scan = await Task.detached(priority: .userInitiated) { scanAll(cache: cache) }.value
        sessions = scan.sessions
        scanCache = scan.cache
        recompute()
        loading = false
        scanning = false
        startWatching()
        if rescanWhenDone {
            rescanWhenDone = false
            await refresh(quiet: true)
        }
    }

    /// Follow the log directory so an active conversation appears as it happens.
    @MainActor
    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Watcher(path: projectsDir) { [weak self] in
            Task { @MainActor in await self?.refresh(quiet: true) }
        }
    }

    /// Summarize and cluster recent conversations with the local `claude` CLI.
    @MainActor
    func analyze() async {
        guard !analyzing else { return }
        analyzing = true
        status = "Reading your conversations…"
        let batch = sessions
        do {
            insights = try await Task.detached(priority: .userInitiated) {
                try runAnalysis(batch)
            }.value
            status = "Cross-referenced."
        } catch {
            status = "Couldn’t reach Claude — \(error.localizedDescription)"
        }
        analyzing = false
    }

    func summary(_ s: Session) -> String? { insights?.summaries[s.id] }
    func topics(_ s: Session) -> [String] { labels[s.id] ?? [] }

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

    /// Matches narrowed to the selected day, or to the scope — before topics.
    private var inRange: [Session] {
        if let day = selectedDay {
            return matched.filter { dayKey($0.last) == day }
        }
        let cutoff = Date().timeIntervalSince1970 - scope.seconds
        return matched.filter { $0.last >= cutoff }
    }

    /// What the list shows.
    var visible: [Session] {
        guard let cluster else { return inRange }
        return inRange.filter { topics($0).contains(cluster) }
    }

    /// The topic chips: every cluster present in what's currently in range, with
    /// how many of those conversations it holds. Counted before the chip filter,
    /// so picking one doesn't empty out the others.
    var topicCounts: [(label: String, count: Int)] {
        let rows = inRange
        return (insights?.clusters.map(\.label) ?? [])
            .map { label in (label, rows.filter { topics($0).contains(label) }.count) }
            // A picked chip stays even when it empties out, or there is nothing
            // left to click to get back.
            .filter { $0.1 > 0 || $0.0 == cluster }
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
