import Foundation

// Writing a conversation out of the app. The opposite direction to Markdown.swift,
// and much the smaller job: Claude Code already writes markdown, so the recorded
// text is the output and the work is mostly in not getting in the way of it.

let maxExportNameLength = 80
let fallbackExportName = "conversation"

/// Facts are joined with this, and dropped rather than written empty, the same
/// rule `StatsLine` follows on screen.
private let factSeparator = " · "

/// Fixed rather than localized: `--selftest` asserts the rendered text, and the
/// other date in this app (`dayKey`) is pinned the same way and for the same reason.
private let exportDate: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// Who said it, as the label above a turn.
///
/// A relayed turn is named for the session that sent it and says so. Without the
/// parenthetical a reader meets a bold name where every other turn has a speaker,
/// and takes it for a person.
func speakerLabel(_ m: Message) -> String {
    if let peer = m.from { return "**\(peer.name)** (another Claude session)" }
    return m.role == "assistant" ? "**Claude**" : "**You**"
}

/// What the header line says about a conversation, in order, minus anything the
/// app does not actually know. `(unknown)` is our own placeholder for a missing
/// working directory, so it is a fact we do not have rather than one to print.
func exportFacts(_ s: Session) -> [String] {
    var facts: [String] = []
    if s.project != unknownProject { facts.append(s.project) }
    if let branch = s.branch { facts.append(branch) }
    facts.append(exportDate.string(from: Date(timeIntervalSince1970: s.last)))
    facts.append("\(s.count) \(s.count == 1 ? "turn" : "turns")")
    return facts
}

/// One conversation as a markdown document.
///
/// Turns are separated by a rule and labelled in bold rather than with headings.
/// Claude writes `#` and `##` headings constantly, so any heading level chosen for
/// speakers collides with the message's own outline: a turn's `## The approach`
/// would read as another speaker, and a turn containing `# Title` would outrank
/// every speaker in the file. The conversation's title is the document's only
/// heading, so every heading under it belongs to the conversation.
func markdownExport(_ messages: [Message], _ s: Session) -> String {
    var out = "# \(s.title)\n"
    let facts = exportFacts(s)
    if !facts.isEmpty { out += "\n*\(facts.joined(separator: factSeparator))*\n" }
    for m in messages {
        // Verbatim: not re-wrapped, not re-indented, not trimmed. A trailing blank
        // line costs nothing in markdown; reformatting somebody's code block does.
        out += "\n---\n\n\(speakerLabel(m))\n\n\(m.text)\n"
    }
    return out
}

/// A filename proposing the conversation, without the extension.
///
/// The session id would always be valid and always be useless: nobody recognises
/// `7b12fa18-d027-42f8…` in a folder a week later. The person can rename in the
/// panel; the job here is to offer something they know.
func exportFilename(_ title: String) -> String {
    // `/` and `:` are the two macOS rejects. Newlines are legal in a filename and
    // still have no business in one.
    var name = title
    for bad in ["/", ":", "\n", "\r"] {
        name = name.replacingOccurrences(of: bad, with: " ")
    }
    // Collapses the runs those replacements just made, and any that were there already.
    name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // Cut before the extension is added, so the `.md` always survives the cap.
    name = String(name.prefix(maxExportNameLength))
        .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? fallbackExportName : name
}
