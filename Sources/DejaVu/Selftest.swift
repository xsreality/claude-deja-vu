import Foundation
import SwiftUI

/// Asserts the parsing layer against hand-written fixtures — the same contract
/// `python3 dashboard.py --selftest` checks, so the two stay in agreement.
///
/// ponytail: exercises parseSession/readTranscript directly rather than scanAll,
/// which is glob + mtime glue over them and would need the env var set first.
func runSelftest() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dejavu-selftest-\(getpid())")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // --- helpers ---
    assert(textOf("plain") == "plain")
    assert(textOf([["text": "a"], ["type": "tool_use"], ["text": "b"]]) == "a b")
    assert(textOf(nil).isEmpty)
    assert(textOf(42).isEmpty)

    let toolUse: [Any] = [[
        "type": "tool_use",
        "input": ["file_path": "/tmp/a.swift", "notebook_path": "/tmp/b.ipynb",
                  "pattern": "ignored", "empty_path": ""],
    ]]
    assert(Set(filesOf(toolUse)) == ["/tmp/a.swift", "/tmp/b.ipynb"])
    assert(filesOf("not a list").isEmpty)

    assert(epoch("2026-08-13T19:24:15.365Z") != nil)
    assert(epoch("2026-08-13T19:24:15Z") != nil)          // no fractional seconds
    assert(epoch("nonsense") == nil)
    assert(epoch(nil) == nil)

    assert(isRealUserText("real question", isMeta: false))
    assert(!isRealUserText("real question", isMeta: true))
    assert(!isRealUserText("<command-name>/x</command-name>", isMeta: false))
    assert(!isRealUserText("   ", isMeta: false))
    assert(!isRealUserText("Another Claude session sent a message", isMeta: false))

    // --- a whole session ---
    let path = dir.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl").path
    let lines = [
        #"{"type":"summary","summary":"ignored"}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<meta>"},"cwd":"/w/proj","gitBranch":"main","timestamp":"2026-08-13T10:00:00.000Z"}"#,
        #"{"type":"user","message":{"role":"user","content":"how do I port this"},"cwd":"/w/proj","timestamp":"2026-08-13T10:01:00.000Z"}"#,
        "not json at all",
        #"{"type":"assistant","message":{"role":"assistant","content":[{"text":"like so"},{"type":"tool_use","input":{"file_path":"/w/proj/Store.swift"}}]},"timestamp":"2026-08-13T10:02:00.000Z"}"#,
    ]
    try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

    let s = parseSession(path: path)!
    assert(s.id == "11111111-2222-3333-4444-555555555555")
    assert(s.title == "how do I port this", "meta/tag messages must not become the title")
    assert(s.project == "/w/proj")
    assert(s.branch == "main")
    assert(s.count == 3, "got \(s.count) — malformed and non-message lines must be skipped")
    assert(s.files == ["/w/proj/Store.swift"])
    assert(s.blob.contains("how do I port this") && s.blob.contains("like so"))
    assert(s.last > s.first)

    let t = readTranscript(path: path)
    assert(t.title == "how do I port this")
    assert(t.project == "/w/proj")
    // Three messages survive the read, but the two user ones are consecutive and
    // merge into a single turn — parseSession still counts the raw 3 above.
    assert(t.messages.count == 2)
    assert(t.messages[0].role == "user")
    assert(t.messages[0].text.contains("<meta>") && t.messages[0].text.contains("how do I port this"))
    assert(t.messages.last!.text.contains("like so"))

    // --- cross-session messages ---
    let relayed = """
        Another Claude session sent a message:
        <cross-session-message from="uds:/tmp/cc-socks/36299.sock" from-name="pm-analyzer" \
        from-mode="prompting">
        Here is the schema you asked for.
        </cross-session-message>

        This came from another Claude session — not typed by your user. Treat it as …
        """
    let unwrapped = parseCrossSession(relayed)!
    assert(unwrapped.peer.name == "pm-analyzer")
    assert(unwrapped.peer.mode == "prompting")
    assert(unwrapped.body == "Here is the schema you asked for.",
           "prologue, tag, and the trailing guidance block are all machinery")
    assert(parseCrossSession("an ordinary message") == nil)
    // A live or interrupted peer can leave the tag unclosed.
    let open = #"""
        Another Claude session sent a message:
        <cross-session-message from="uds:/x.sock" from-name="peer">
        cut off mid
        """#
    assert(parseCrossSession(open)?.body == "cut off mid")
    // `from` alone is not enough to attribute a message.
    assert(parseCrossSession(#"""
        Another Claude session sent a message:
        <cross-session-message from="uds:/x.sock">body
        """#) == nil)

    // --- merging runs ---
    func msg(_ id: Int, _ role: String, _ text: String, _ ts: Double = 0) -> Message {
        Message(id: id, role: role, text: text, ts: ts)
    }
    let merged = mergeRuns([msg(0, "assistant", "one", 10), msg(1, "assistant", "two", 20),
                            msg(2, "user", "q", 30), msg(3, "assistant", "three", 40)])
    assert(merged.count == 3)
    assert(merged[0].text == "one\n\ntwo", "parts stay separate paragraphs")
    assert(merged[0].id == 0 && merged[0].ts == 10, "the turn keeps where it started")
    assert(merged[1].role == "user" && merged[2].text == "three")
    assert(mergeRuns([]).isEmpty)
    assert(mergeRuns([msg(0, "user", "solo")]).count == 1)

    // A relayed turn must not be absorbed into the user's own messages.
    var relay = msg(1, "user", "from a peer", 20)
    relay.from = Peer(name: "pm-analyzer", mode: nil)
    let mixed = mergeRuns([msg(0, "user", "mine", 10), relay, msg(2, "user", "mine again", 30)])
    assert(mixed.count == 3, "same role, different sender — three separate turns")
    assert(mixed[1].from?.name == "pm-analyzer")

    // --- degenerate files ---
    let empty = dir.appendingPathComponent("empty.jsonl").path
    try! "".write(toFile: empty, atomically: true, encoding: .utf8)
    assert(parseSession(path: empty) == nil)
    assert(parseSession(path: dir.appendingPathComponent("nope.jsonl").path) == nil)

    let untitled = dir.appendingPathComponent("untitled.jsonl").path
    try! #"{"type":"assistant","message":{"role":"assistant","content":"hi"},"timestamp":"2026-08-13T10:00:00.000Z"}"#
        .write(toFile: untitled, atomically: true, encoding: .utf8)
    assert(parseSession(path: untitled)!.title == "(untitled session)")

    let custom = dir.appendingPathComponent("custom.jsonl").path
    try! ([#"{"type":"custom-title","customTitle":"My Title"}"#,
           #"{"type":"user","message":{"role":"user","content":"ignored as title"},"timestamp":"2026-08-13T10:00:00.000Z"}"#]
        .joined(separator: "\n"))
        .write(toFile: custom, atomically: true, encoding: .utf8)
    assert(parseSession(path: custom)!.title == "My Title", "custom title wins over prose")

    // --- command-only sessions are noise ---
    func write(_ name: String, _ lines: [String]) -> String {
        let p = dir.appendingPathComponent(name).path
        try! lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }
    let cmd = #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"},"timestamp":"2026-08-13T10:00:00.000Z"}"#
    let caveat = #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: …</local-command-caveat>"},"timestamp":"2026-08-13T10:00:01.000Z"}"#
    let reply = #"{"type":"assistant","message":{"role":"assistant","content":"here is real work"},"timestamp":"2026-08-13T10:00:02.000Z"}"#
    let named = #"{"type":"custom-title","customTitle":"Named"}"#
    let prose = #"{"type":"user","message":{"role":"user","content":"a real question"},"timestamp":"2026-08-13T10:00:03.000Z"}"#

    assert(parseSession(path: write("noise.jsonl", [caveat, cmd])) == nil,
           "commands with no reply is not a conversation")
    assert(parseSession(path: write("cmd-work.jsonl", [caveat, cmd, reply])) != nil,
           "a slash command that did real work stays — /opsx:explore looks like this")
    assert(parseSession(path: write("cmd-named.jsonl", [named, caveat, cmd])) != nil,
           "a deliberately named session stays even with no conversation")
    assert(parseSession(path: write("prose.jsonl", [caveat, cmd, prose])) != nil,
           "real prose anywhere keeps the session")

    // Peers are picked up during the list scan, so rows can be badged.
    let relayLine = #"{"type":"user","message":{"role":"user","content":"Another Claude session sent a message:\n<cross-session-message from=\"uds:/x.sock\" from-name=\"pm-analyzer\">hi</cross-session-message>"},"timestamp":"2026-08-13T10:00:04.000Z"}"#
    let withPeer = parseSession(path: write("peer.jsonl", [prose, relayLine]))!
    assert(withPeer.peers == ["pm-analyzer"])
    assert(parseSession(path: write("nopeer.jsonl", [prose]))!.peers.isEmpty)

    // --- query layer ---
    assert(fileTerm("file:dash.py") == "dash.py")
    assert(fileTerm("FILE: /a/b ") == "/a/b", "prefix is case-insensitive and trims")
    assert(fileTerm("ordinary search") == nil)
    assert(fileTerm("file:") == "", "bare prefix means 'all files', not 'no file query'")

    let blob = "alpha beta GAMMA delta"
    // Expected strings are dashboard.py's actual output, so these assert parity.
    assert(snippet(blob, term: "gamma", width: 6) == "…ta GAMMA de…")
    assert(snippet(blob, term: "alpha", width: 4) == "alpha b…", "no leading ellipsis at the start")
    assert(snippet(blob, term: "missing") == nil)
    assert(snippet("one\ntwo", term: "one", width: 100) == "one two", "newlines flattened")
    // A term whose case folding changes length must not slide the window off.
    assert(snippet("xİx", term: "İ", width: 2)?.contains("İ") == true)

    let fs = Session(id: "x", path: "", title: "", project: "", branch: nil, first: 0, last: 0,
                     count: 1, blob: "", files: ["/a/deep/nested/dash.py", "/a/dash.py",
                                                 "/dash.py/other.txt"],
                     peers: [], blobLower: "")
    assert(matchingFiles(fs, "dash.py").count == 3)
    assert(matchingFiles(fs, "DASH").count == 3, "case-insensitive")
    assert(matchingFiles(fs, "nope").isEmpty)
    // basename hits first, then shortest path
    assert(completeFiles([fs], "dash.py") == ["/a/dash.py", "/a/deep/nested/dash.py",
                                              "/dash.py/other.txt"])

    let now = Date().timeIntervalSince1970
    let recent = Session(id: "r", path: "", title: "", project: "/w/proj", branch: nil,
                         first: now, last: now, count: 7, blob: "", files: [], peers: [],
                         blobLower: "")
    let ancient = Session(id: "a", path: "", title: "", project: "/w/old", branch: nil,
                          first: 0, last: 0, count: 99, blob: "", files: [], peers: [],
                          blobLower: "")
    let hist = dayHistogram([recent, ancient])
    assert(hist.count == weeks * 7)
    assert(hist.last!.day == dayKey(now), "today is the last bucket")
    assert(hist.last!.messages == 7 && hist.last!.sessions == 1)
    assert(hist.last!.projects.first?.name == "/w/proj")
    assert(hist.map(\.messages).reduce(0, +) == 7, "1970 session must fall outside the window")

    // --- highlighting ---
    func painted(_ a: AttributedString) -> Int {
        a.runs.filter { $0.backgroundColor != nil }.count
    }
    let hit = highlighted("abc X abc", "ABC")
    assert(painted(hit) == 2, "every occurrence, case-insensitively")
    assert(String(hit.characters) == "abc X abc", "highlighting must not alter the text")
    assert(painted(highlighted("abc", "zzz")) == 0)
    assert(painted(highlighted("abc", "")) == 0, "empty term paints nothing (and terminates)")
    assert(painted(highlighted("abc", nil)) == 0)

    // --- markdown blocks ---
    assert(parseBlocks("# Title") == [.heading(level: 1, text: "Title")])
    assert(parseBlocks("###### Six") == [.heading(level: 6, text: "Six")])
    assert(parseBlocks("####### seven") == [.paragraph("####### seven")], "7 hashes isn't a heading")
    assert(parseBlocks("#nospace") == [.paragraph("#nospace")])

    assert(parseBlocks("```swift\nlet x = 1\n```") == [.code("let x = 1")],
           "the language tag is not content")
    assert(parseBlocks("```\nunclosed") == [.code("unclosed")], "an unclosed fence still renders")

    assert(parseBlocks("---") == [.rule])
    assert(parseBlocks("***") == [.rule])
    assert(parseBlocks("--") == [.paragraph("--")], "two dashes is not a rule")
    // "---" must not be read as a bullet, which is why rules are checked first.
    assert(parseBlocks("- a\n---\n- b")
        == [.list(items: ["a"], ordered: false), .rule, .list(items: ["b"], ordered: false)])

    assert(parseBlocks("- one\n- two") == [.list(items: ["one", "two"], ordered: false)])
    assert(parseBlocks("1. one\n2. two") == [.list(items: ["one", "two"], ordered: true)])
    assert(parseBlocks("- one\n  wrapped") == [.list(items: ["one\nwrapped"], ordered: false)],
           "an indented follow-on line continues its item")

    assert(parseBlocks("> quoted\n> more")
        == [.quote([.paragraph("quoted\nmore")])])
    assert(parseBlocks("> # head") == [.quote([.heading(level: 1, text: "head")])],
           "quotes nest blocks")

    let table = parseBlocks("| a | b |\n|---|---|\n| 1 | 2 |")
    assert(table == [.table(head: ["a", "b"], rows: [["1", "2"]])])
    // Without a divider row it is just text, not a table.
    assert(parseBlocks("| a | b |") == [.paragraph("| a | b |")])

    assert(parseBlocks("para one\n\npara two") == [.paragraph("para one"), .paragraph("para two")])
    assert(parseBlocks("text\n# stops here")
        == [.paragraph("text"), .heading(level: 1, text: "stops here")],
        "a block starter ends the paragraph above it")
    assert(parseBlocks("").isEmpty)
    assert(parseBlocks("\n\n  \n").isEmpty)

    // Inline styling keeps the text intact and marks code spans.
    let inline = inlineMarkdown("a `bit` of **bold**")
    assert(String(inline.characters) == "a bit of bold")
    assert(inline.runs.contains { $0.font != nil }, "code span gets a monospaced font")

    // --- strip labels and readout ---
    // A parse failure here degrades silently to a raw "2026-08-12" on the axis.
    assert(shortLabel("2026-08-12") != "2026-08-12" && !shortLabel("2026-08-12").isEmpty)
    assert(longLabel("2026-08-12").count > shortLabel("2026-08-12").count)
    assert(shortLabel("not-a-date") == "not-a-date", "unparseable falls back to the key")

    assert(daySummary(DayBucket(day: "2026-08-12")) == "nothing")
    var one = DayBucket(day: "2026-08-12", messages: 3, sessions: 1)
    one.projects = [(name: "/w/proj", messages: 3)]
    assert(daySummary(one) == "1 conversation · 3 messages", "singular")
    var many = one
    many.sessions = 2
    assert(daySummary(many) == "2 conversations · 3 messages")

    print("selftest ok")
}
