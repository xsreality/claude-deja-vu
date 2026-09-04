import Foundation

// Port of dashboard.py's "AI insights" layer: one `claude -p` call that summarizes
// recent sessions and clusters related ones across projects, cached to disk.

let sampleChars = 700          // chars sent to Claude per session (start+middle+end)
let maxAnalyzeSessions = 40    // cap the batch so the prompt stays small enough to parse
let analyzeTimeout: TimeInterval = 300

/// The cache file, shared in shape (not location) with the Python viewer.
///
/// Application Support rather than beside the binary: the app ships read-only in
/// a `.app` bundle, and a Homebrew install is not writable.
let insightsFile: String = ProcessInfo.processInfo.environment["DEJAVU_INSIGHTS"]
    ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DejaVu/insights.json").path)

struct Insights: Codable {
    struct Cluster: Codable, Hashable {
        var label: String
        var session_ids: [String]
    }
    var summaries: [String: String]
    var clusters: [Cluster]
    var generated: Double

    init(summaries: [String: String] = [:], clusters: [Cluster] = [],
         generated: Double = Date().timeIntervalSince1970) {
        self.summaries = summaries
        self.clusters = clusters
        self.generated = generated
    }

    // Hand-written so a cache (or a reply) missing a key still decodes; Claude
    // returns no `generated`, and either half can come back absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summaries = (try? c.decode([String: String].self, forKey: .summaries)) ?? [:]
        clusters = (try? c.decode([Cluster].self, forKey: .clusters)) ?? []
        generated = (try? c.decode(Double.self, forKey: .generated)) ?? Date().timeIntervalSince1970
    }

    /// Topic labels attached to each session id, from the cluster memberships.
    var labelsByID: [String: [String]] {
        var out: [String: [String]] = [:]
        for c in clusters where !c.label.isEmpty {
            for id in c.session_ids { out[id, default: []].append(c.label) }
        }
        return out
    }
}

/// ~limit chars drawn from start+middle+end so buried topics still show.
func sampleText(_ blob: String, limit: Int = sampleChars) -> String {
    guard blob.count > limit else { return blob }
    let chars = Array(blob)
    let n = limit / 3
    let mid = chars.count / 2
    let start = String(chars[0..<n])
    let middle = String(chars[(mid - n / 2)..<(mid + n / 2)])
    let end = String(chars[(chars.count - n)...])
    return "\(start)\n…\n\(middle)\n…\n\(end)"
}

func buildAnalyzePrompt(_ sessions: [Session]) -> String {
    let digests = sessions.map {
        ["id": $0.id, "title": $0.title, "project": $0.project, "sample": sampleText($0.blob)]
    }
    let json = (try? JSONSerialization.data(withJSONObject: digests))
        .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    return """
        You analyze a developer's Claude Code sessions to help them recall and \
        find conversations. For the sessions below, return ONLY a JSON object \
        (no prose, no markdown fences) of the form:
        {"summaries": {"<session_id>": "one concise line of what it was about"}, \
        "clusters": [{"label": "short topic name", "session_ids": ["id", ...]}]}
        Clusters are topics that may span different projects; group sessions that \
        discuss related work even across projects. A session may be in no cluster. \
        Use only the given session ids.

        SESSIONS:
        \(json)
        """
}

/// Pull the first {...} JSON object out of possibly-noisy CLI output.
func extractInsights(_ text: String) -> Insights? {
    let cleaned = text.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
    guard let start = cleaned.firstIndex(of: "{"),
          let end = cleaned.lastIndex(of: "}"), start < end else { return nil }
    return try? JSONDecoder().decode(Insights.self,
                                     from: Data(cleaned[start...end].utf8))
}

// --- the CLI call -------------------------------------------------------------

enum AnalyzeError: LocalizedError {
    case notFound, timedOut, failed(String), unparsable

    var errorDescription: String? {
        switch self {
        case .notFound: "the `claude` CLI could not be found."
        case .timedOut: "it took longer than \(Int(analyzeTimeout / 60)) minutes."
        case .failed(let why): why
        case .unparsable: "it returned output that could not be parsed."
        }
    }
}

/// Where `claude` lives, by absolute path.
///
/// An app launched from Finder inherits a minimal PATH (no Homebrew, no
/// `~/.claude/local`), so `which` finds nothing and a bare "claude" never
/// launches. Ask a login shell, which is the only thing that knows what the
/// user's profile put on PATH, and fall back to the known homes if it can't say.
///
/// Shell first, not last: `~/.claude/local/claude` is a *stale* npm install on
/// plenty of machines (it is here, a year old, and it crashes on startup), and
/// guessing it over the one the user actually runs picks the broken one.
func claudePath() -> String? {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
    probe.arguments = ["-lc", "command -v claude"]
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = FileHandle.nullDevice
    if (try? probe.run()) != nil {
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let path = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    let home = NSHomeDirectory()
    return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Run one `claude -p` with the prompt on stdin. Blocking; call it off the main actor.
func runClaude(prompt: String) throws -> String {
    guard let exe = claudePath() else { throw AnalyzeError.notFound }
    // A child that exits before reading the whole prompt would otherwise kill us
    // with SIGPIPE mid-write instead of surfacing as an error.
    signal(SIGPIPE, SIG_IGN)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = ["-p"]
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = stderr
    try proc.run()

    // The prompt is ~40KB and the pipe buffer is ~64KB, so writing it whole is
    // *currently* safe, but it grows with maxAnalyzeSessions, and a full buffer
    // deadlocks against a child that is waiting for us to read its output. Both
    // ends move on their own thread; this one only reads.
    let writer = DispatchQueue(label: "dejavu.stdin")
    writer.async {
        try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()   // the EOF `claude -p` waits on
    }
    var errData = Data()
    let errQueue = DispatchQueue(label: "dejavu.stderr")
    errQueue.async { errData = stderr.fileHandleForReading.readDataToEndOfFile() }

    // Process has no timeout of its own.
    var killed = false
    let killer = DispatchWorkItem { killed = true; proc.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + analyzeTimeout, execute: killer)

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    killer.cancel()
    errQueue.sync {}   // barrier: errData is settled once this returns

    if killed { throw AnalyzeError.timedOut }
    guard proc.terminationStatus == 0 else {
        let why = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw AnalyzeError.failed(String((why.isEmpty ? "the CLI failed." : why).prefix(300)))
    }
    return String(decoding: outData, as: UTF8.self)
}

/// Summarize and cluster the most recent sessions, caching the result.
func runAnalysis(_ sessions: [Session]) throws -> Insights {
    // A 150-session prompt (~260KB) overflows the CLI; cap to the most recent.
    let out = try runClaude(prompt: buildAnalyzePrompt(Array(sessions.prefix(maxAnalyzeSessions))))
    guard let insights = extractInsights(out) else { throw AnalyzeError.unparsable }
    saveInsights(insights)
    return insights
}

func loadInsights() -> Insights? {
    guard let data = FileManager.default.contents(atPath: insightsFile) else { return nil }
    return try? JSONDecoder().decode(Insights.self, from: data)
}

func saveInsights(_ insights: Insights) {
    let url = URL(fileURLWithPath: insightsFile)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // The analysis is still usable this run even if the cache write fails.
    try? JSONEncoder().encode(insights).write(to: url)
}
