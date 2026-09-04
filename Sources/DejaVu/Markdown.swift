import SwiftUI

// Block-level markdown, ported from dashboard.py's md(). AttributedString only
// does inline markup. Headings, lists, tables and quotes need real layout, so
// the text is split into blocks here and each block is laid out as itself.
//
// ponytail: plain string scanning, no regex and no parser dependency. It covers
// the same grammar the web version does; anything fancier (nested lists, footnotes)
// renders as its own paragraph rather than wrongly.

indirect enum Block: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(String)
    case list(items: [String], ordered: Bool)
    case quote([Block])
    case rule
    case table(head: [String], rows: [[String]])
}

private func isFence(_ l: String) -> Bool {
    l.trimmingCharacters(in: .whitespaces).hasPrefix("```")
}

private func isRule(_ l: String) -> Bool {
    let t = l.trimmingCharacters(in: .whitespaces)
    guard t.count >= 3 else { return false }
    return ["-", "*", "_"].contains { c in t.allSatisfy { String($0) == c } }
}

private func headingLevel(_ l: String) -> (Int, String)? {
    let t = l.drop { $0 == " " }
    let hashes = t.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = t.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    return (hashes, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
}

/// The bullet or number marker at the head of a list item, if any.
private func listMarker(_ l: String) -> (marker: String, ordered: Bool)? {
    let t = l.drop { $0 == " " }
    if let first = t.first, "-*+".contains(first), t.dropFirst().first == " " {
        return (String(first), false)
    }
    let digits = t.prefix { $0.isNumber }
    if !digits.isEmpty, t.dropFirst(digits.count).first == ".",
       t.dropFirst(digits.count + 1).first == " " {
        return (String(digits) + ".", true)
    }
    return nil
}

private func isTableRow(_ l: String) -> Bool {
    let t = l.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("|") && t.hasSuffix("|") && t.count > 1
}

/// A `|---|:--|` separator, which is what turns two piped lines into a table.
private func isTableDivider(_ l: String) -> Bool {
    let t = l.trimmingCharacters(in: .whitespaces)
    return t.contains("-") && t.allSatisfy { " |:-".contains($0) }
}

private func tableCells(_ l: String) -> [String] {
    var t = l.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") { t.removeLast() }
    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

private func isQuote(_ l: String) -> Bool {
    l.drop { $0 == " " }.first == ">"
}

private func stripQuote(_ l: String) -> String {
    var t = String(l.drop { $0 == " " }.dropFirst())   // the ">"
    if t.first == " " { t.removeFirst() }
    return t
}

/// True for a line that begins a block, so a paragraph knows where to stop.
private func startsBlock(_ l: String) -> Bool {
    isFence(l) || headingLevel(l) != nil || isQuote(l)
        || listMarker(l) != nil || isTableRow(l)
}

func parseBlocks(_ text: String) -> [Block] {
    let lines = text.components(separatedBy: "\n")
    var out: [Block] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]

        if isFence(line) {
            var body: [String] = []
            i += 1
            while i < lines.count, !isFence(lines[i]) { body.append(lines[i]); i += 1 }
            i += 1                                    // the closing fence
            out.append(.code(body.joined(separator: "\n")))
            continue
        }

        if let (level, text) = headingLevel(line) {
            out.append(.heading(level: level, text: text))
            i += 1
            continue
        }

        // Checked before lists, or "---" reads as a bullet.
        if isRule(line) {
            out.append(.rule)
            i += 1
            continue
        }

        if isTableRow(line), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
            let head = tableCells(line)
            i += 2
            var rows: [[String]] = []
            while i < lines.count, isTableRow(lines[i]) {
                rows.append(tableCells(lines[i]))
                i += 1
            }
            out.append(.table(head: head, rows: rows))
            continue
        }

        if isQuote(line) {
            var body: [String] = []
            while i < lines.count, isQuote(lines[i]) { body.append(stripQuote(lines[i])); i += 1 }
            out.append(.quote(parseBlocks(body.joined(separator: "\n"))))
            continue
        }

        if let (_, ordered) = listMarker(line) {
            var items: [String] = []
            while i < lines.count, let (marker, _) = listMarker(lines[i]) {
                let stripped = lines[i].drop { $0 == " " }.dropFirst(marker.count + 1)
                var item = String(stripped)
                i += 1
                // An indented follow-on line continues the item it sits under.
                while i < lines.count, listMarker(lines[i]) == nil,
                      lines[i].hasPrefix("  "), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    item += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                items.append(item)
            }
            out.append(.list(items: items, ordered: ordered))
            continue
        }

        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
            continue
        }

        var body: [String] = []
        while i < lines.count,
              !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
              !startsBlock(lines[i]) {
            body.append(lines[i])
            i += 1
        }
        if body.isEmpty {
            // A block starter no branch claimed, such as a `| x |` line with no divider
            // under it, say. The web drops these; keep it as text instead, since
            // silently losing a line of a transcript is worse than plain styling.
            out.append(.paragraph(line))
            i += 1
        } else {
            out.append(.paragraph(body.joined(separator: "\n")))
        }
    }
    return out
}

// --- rendering ---------------------------------------------------------------

private let bodySize: CGFloat = 13.5
private let codeSize: CGFloat = 12.5
/// 13.5px text on a 1.7 line box, minus the ~1.2 SwiftUI already applies.
private let bodyLeading: CGFloat = 6.5

/// Inline markup for one run of text, with `code` spans styled and search hits painted.
func inlineMarkdown(_ s: String, highlight: String? = nil) -> AttributedString {
    var a = (try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)

    // Collect first: styling runs while iterating them invalidates the indices.
    let codeRanges = a.runs.compactMap {
        $0.inlinePresentationIntent?.contains(.code) == true ? $0.range : nil
    }
    for r in codeRanges {
        a[r].font = .system(size: codeSize, design: .monospaced)
        a[r].backgroundColor = .secondary.opacity(0.18)
    }
    return highlighting(a, highlight)
}

struct MarkdownView: View {
    let blocks: [Block]
    var highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inlineMarkdown(text, highlight: highlight))
                .font(.system(size: bodySize))
                .lineSpacing(bodyLeading)
                .textSelection(.enabled)

        case .heading(let level, let text):
            Text(inlineMarkdown(text, highlight: highlight))
                .font(.system(size: headingSize(level), weight: .bold))
                .padding(.top, 8)

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted(code, highlight))
                    .font(.system(size: codeSize, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ordered ? "\(n + 1)." : "•")
                            .font(.system(size: bodySize))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: ordered ? 18 : 9, alignment: .trailing)
                        Text(inlineMarkdown(item, highlight: highlight))
                            .font(.system(size: bodySize))
                            .lineSpacing(bodyLeading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)

        case .quote(let inner):
            MarkdownView(blocks: inner, highlight: highlight)
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.separator).frame(width: 2)
                }

        case .rule:
            Divider().padding(.vertical, 6)

        case .table(let head, let rows):
            TableBlock(head: head, rows: rows, highlight: highlight)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15.5
        default: 14
        }
    }
}

/// Wide tables scroll inside themselves rather than stretching the transcript.
struct TableBlock: View {
    let head: [String]
    let rows: [[String]]
    var highlight: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(head.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, bold: true)
                    }
                }
                .background(Color.primary.opacity(0.05))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                        .gridCellColumns(max(head.count, row.count))
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellView(cell, bold: false)
                        }
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func cellView(_ text: String, bold: Bool) -> some View {
        Text(inlineMarkdown(text, highlight: highlight))
            .font(.system(size: codeSize, weight: bold ? .bold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(minWidth: 60, alignment: .leading)
    }
}
