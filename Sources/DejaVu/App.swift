import AppKit
import SwiftUI

struct DejaVuApp: App {
    @State private var store = Store()

    var body: some Scene {
        Window("Claude Déjà Vu", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 940, minHeight: 560)
                .task { await store.refresh() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct ContentView: View {
    @Bindable var store: Store
    // Seeded like DEJAVU_QUERY, so a transcript can be opened and looked at directly.
    @State private var selection: Session.ID? =
        ProcessInfo.processInfo.environment["DEJAVU_SELECT"]
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search, scope, and the strip control everything below them, so they
            // span the window rather than living in one column.
            header
            Divider()
            splitView
        }
        .navigationTitle("Claude Déjà Vu")
        .toolbar {
            if store.loading || store.analyzing { ProgressView().controlSize(.small) }
            Button { Task { await store.analyze() } } label: {
                Label("Cross-reference", systemImage: "sparkles")
            }
            .disabled(store.analyzing || store.sessions.isEmpty)
            .help("Summarize and group these conversations using the local claude CLI")
            Button { Task { await store.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .onKeyPress(.escape) {
            store.query = ""; store.selectedDay = nil; store.cluster = nil; store.repo = nil
            return .handled
        }
    }

    private var header: some View {
        // Three stacked rows of controls; they need air between them or the chips
        // read as an underline on the scope picker.
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                TextField("Search, or file: to search paths", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .frame(maxWidth: 460)
                    // Floats over the strip below rather than pushing it down.
                    .overlay(alignment: .topLeading) {
                        // Only while the box has focus, like the web version's
                        // activeElement check — clicking a result should close it.
                        if searchFocused, !store.completions.isEmpty {
                            CompletionList(paths: store.completions,
                                           term: fileTerm(store.query) ?? "") {
                                store.query = filePrefix + $0
                            }
                            .offset(y: 26)
                        }
                    }

                Picker("", selection: $store.scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(store.selectedDay != nil)

                RepoMenu(repos: store.repoCounts, selected: $store.repo)

                Spacer(minLength: 0)

                if let status = store.status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
            }
            // The completions panel hangs out of this row. Without this it draws
            // *under* the strip below, which is a later sibling in the stack.
            .zIndex(1)

            TopicChips(topics: store.topicCounts, selected: $store.cluster,
                       analyzed: store.insights != nil)

            HStack(alignment: .bottom, spacing: 16) {
                Text("Activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 19)
                DayStrip(days: store.days, selected: $store.selectedDay)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .zIndex(1)  // keeps the completions list above the panes
    }

    private var splitView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Text(countLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                Divider()
                List(store.visible, selection: $selection) { s in
                    SessionRow(session: s, query: store.query,
                               summary: store.summary(s), topics: store.topics(s),
                               repo: store.repo(of: s), onRepo: { store.repo = $0 })
                        .tag(s.id)
                        .listRowInsets(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
                .overlay {
                    if store.visible.isEmpty { emptyState }
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 390)
        } detail: {
            if let s = store.visible.first(where: { $0.id == selection })
                ?? store.sessions.first(where: { $0.id == selection }) {
                TranscriptView(session: s, term: highlightTerm,
                               resume: store.resumeCommand(s), store: store,
                               onOpen: { selection = $0 })
            } else {
                ContentUnavailableView("Pick a conversation", systemImage: "text.bubble")
            }
        }
    }

    /// Says why the list is as short as it is — especially after picking a day.
    private var countLabel: String {
        let n = store.visible.count
        let inRepo = store.repo.map { " in \(repoLabel($0))" } ?? ""
        let onDay = store.selectedDay.map { " on \(shortLabel($0))" } ?? ""
        return "\(n) \(n == 1 ? "conversation" : "conversations")\(inRepo)\(onDay)"
    }

    /// `file:` queries match paths, not prose — nothing to highlight in the text.
    private var highlightTerm: String? {
        fileTerm(store.query) == nil && !store.query.isEmpty ? store.query : nil
    }

    @ViewBuilder private var emptyState: some View {
        if store.loading {
            ContentUnavailableView("Scanning…", systemImage: "clock")
        } else if let repo = store.repo {
            // Before the search and day cases: with a repo picked, that is the filter
            // most likely to be the reason, and the one least visible in the list.
            ContentUnavailableView("Nothing in \(repoLabel(repo))", systemImage: "folder",
                                   description: Text(repoEmptyReason))
        } else if !store.query.isEmpty {
            ContentUnavailableView.search(text: store.query)
        } else if store.selectedDay != nil {
            ContentUnavailableView("Nothing that day", systemImage: "calendar")
        } else {
            ContentUnavailableView("No conversations", systemImage: "tray",
                                   description: Text("Nothing in \(store.scope.rawValue) under \(projectsDir)"))
        }
    }

    /// Which of the other filters emptied the repo out — the thing to undo.
    private var repoEmptyReason: String {
        if !store.query.isEmpty { return "No conversation in this repo matches “\(store.query)”." }
        if let day = store.selectedDay { return "Nothing in this repo on \(shortLabel(day))." }
        return "Nothing in this repo in \(store.scope.rawValue) — try All repos."
    }
}

/// The repos in the window, with counts. A menu rather than a chips row: two dozen
/// of these would scroll four at a time, and the Topics row already owns that space.
struct RepoMenu: View {
    let repos: [(repo: String, count: Int)]
    @Binding var selected: String?

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("All repos") { selected = nil }
                Divider()
                ForEach(repos, id: \.repo) { r in
                    // A Toggle, so macOS draws the checkmark and clicking the picked
                    // one turns it off — two ways back to all repos, both native.
                    Toggle(isOn: Binding(get: { selected == r.repo },
                                         set: { selected = $0 ? r.repo : nil })) {
                        Text("\(repoLabel(r.repo))   \(r.count)")
                    }
                }
            } label: {
                Label(selected.map(repoLabel) ?? "All repos", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(selected ?? "Show one repository at a time")

            if selected != nil {
                Button { selected = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Back to all repos")
            }
        }
    }
}

// --- sidebar pieces ----------------------------------------------------------

/// One bar per day across the whole window. Click to narrow to that day.
///
/// ponytail: plain rectangles rather than Swift Charts — 20 lines beats learning
/// the chart selection API for 28 bars and a tooltip.
struct DayStrip: View {
    let days: [DayBucket]
    @Binding var selected: String?
    @State private var hovered: Int?
    /// Fixed, matching the web version — bars that stretch with the window read
    /// as a different chart every time you drag the divider.
    var barWidth: CGFloat = 15

    private let barHeight: CGFloat = 30
    private let labelHeight: CGFloat = 12
    private let gap: CGFloat = 3
    private let tipWidth: CGFloat = 260

    private var columnPitch: CGFloat { barWidth + gap }
    private var stripWidth: CGFloat { CGFloat(days.count) * columnPitch - gap }

    var body: some View {
        let peak = max(days.map(\.messages).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                VStack(spacing: 6) {
                    // The bar sits at the bottom of a full-height column, and the
                    // column is the hit area — otherwise a quiet day is a 2px target.
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(d, hovered: hovered == i))
                        .frame(width: barWidth,
                               height: max(2, CGFloat(d.messages) / CGFloat(peak) * barHeight))
                    Text(i % 7 == 0 ? shortLabel(d.day) : "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(selected == d.day ? Color.primary : Color.secondary)
                        .fixedSize()                       // let it overhang its column
                        .frame(width: barWidth, height: labelHeight, alignment: .leading)
                }
                .frame(width: barWidth, height: barHeight + labelHeight + 6)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                .onTapGesture {
                    guard d.sessions > 0 else { return }
                    selected = (selected == d.day) ? nil : d.day
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: days.map(\.messages))
        // Own tooltip rather than .help(): the native one waits about a second,
        // which on a strip you sweep across reads as nothing happening.
        .overlay(alignment: .topLeading) { tooltip }
    }

    @ViewBuilder private var tooltip: some View {
        if let i = hovered, days.indices.contains(i) {
            DayTooltip(bucket: days[i])
                .frame(width: tipWidth)
                .offset(x: tipX(i), y: barHeight + labelHeight + 14)
                .transaction { $0.animation = nil }   // follows the pointer instantly
                .allowsHitTesting(false)
        }
    }

    /// Centred under its bar, then kept inside the strip's own width. Bars are a
    /// fixed pitch, so this is arithmetic — no GeometryReader needed.
    private func tipX(_ i: Int) -> CGFloat {
        let centre = CGFloat(i) * columnPitch + barWidth / 2
        return min(max(0, centre - tipWidth / 2), max(0, stripWidth - tipWidth))
    }

    private func fill(_ d: DayBucket, hovered: Bool) -> Color {
        if selected == d.day || hovered { return .primary }
        if d.messages == 0 { return .secondary.opacity(0.15) }
        return selected == nil ? .accentColor.opacity(0.55) : .accentColor.opacity(0.25)
    }
}

/// The strip's hover card: day, then a summary, then one line per repo.
/// Stays dark in both appearances, like the web version's #tip.
struct DayTooltip: View {
    let bucket: DayBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(longLabel(bucket.day))
                .font(.system(size: 13, weight: .semibold))
            Text(daySummary(bucket))
                .font(.system(size: 11.5, design: .monospaced))
                .opacity(0.66)
                .padding(.bottom, 2)
            ForEach(bucket.projects, id: \.name) { p in
                HStack(spacing: 16) {
                    Text((p.name as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text("\(p.messages)")
                }
                .font(.system(size: 11.5, design: .monospaced))
                .opacity(0.92)
            }
        }
        .foregroundStyle(Color(white: 0.98))
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.086, blue: 0.082),
                    in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.28), radius: 15, y: 12)
    }
}

func daySummary(_ d: DayBucket) -> String {
    guard d.sessions > 0 else { return "nothing" }
    let plural = d.sessions == 1 ? "conversation" : "conversations"
    return "\(d.sessions) \(plural) · \(d.messages) messages"
}

// Locale-aware, like the web version's toLocaleDateString: "12 Aug" or "Aug 12"
// depending on where you are.
private func dayFormatter(_ template: String) -> DateFormatter {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(template)
    return f
}
private let shortDay = dayFormatter("dMMM")
private let longDay = dayFormatter("EEEEdMMMM")
private let dayParser: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func shortLabel(_ day: String) -> String {
    dayParser.date(from: day).map { shortDay.string(from: $0) } ?? day
}

func longLabel(_ day: String) -> String {
    dayParser.date(from: day).map { longDay.string(from: $0) } ?? day
}

struct CompletionList: View {
    let paths: [String]
    let term: String
    let pick: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(paths.prefix(8), id: \.self) { p in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    // The basename is what tells these paths apart, so it never
                    // truncates — the directory gives way instead.
                    Text(highlighted((p as NSString).lastPathComponent, term))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text((p as NSString).deletingLastPathComponent
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered == p ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? p : (hovered == p ? nil : hovered) }
                .onTapGesture { pick(p) }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 460, alignment: .leading)
        // Fully opaque: this floats over the activity strip, and a translucent
        // panel lets the bars and their date labels read straight through it.
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        // Swallow hover so the strip underneath stops showing its day tooltip.
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Topics found by the last cross-reference, as filter chips — or, before there
/// has been one, the line that says what the button is for.
struct TopicChips: View {
    let topics: [(label: String, count: Int)]
    @Binding var selected: String?
    let analyzed: Bool

    var body: some View {
        if !topics.isEmpty {
            // ponytail: scrolls sideways where the web version wraps. Seven topics
            // of a few words already overrun the window, and wrapping would push
            // the activity strip down a row every time Claude finds another one.
            HStack(spacing: 8) {
                label
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(topics, id: \.label) { t in
                            let on = selected == t.label
                            Button { selected = on ? nil : t.label } label: {
                                HStack(spacing: 6) {
                                    Text(t.label).font(.system(size: 12, weight: .medium))
                                    Text("\(t.count)")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .opacity(0.6)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(on ? AnyShapeStyle(Color.accentColor)
                                               : AnyShapeStyle(.quaternary),
                                            in: Capsule())
                                .foregroundStyle(on ? Color.white : .primary)
                            }
                            .buttonStyle(.plain)
                            .help("\(t.count) \(t.count == 1 ? "conversation" : "conversations") in this topic")
                        }
                    }
                    .padding(.bottom, 2)   // room for the scroller to appear under
                }
            }
        } else if !analyzed {
            HStack(spacing: 8) {
                label
                Text("Run Cross-reference to group related conversations across projects.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var label: some View {
        Text("Topics")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

struct SessionRow: View {
    let session: Session
    let query: String
    /// From the last cross-reference, when there has been one.
    var summary: String?
    var topics: [String] = []
    /// The repo this conversation's working directory rolls up to.
    var repo: String?
    var onRepo: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Where and when, above the title — keeps the title line uncontested.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 0) {
                    // Only the name is a button: the branch and the age half of this
                    // line have to keep selecting the row.
                    Button(repoLabel(repo ?? session.project)) { onRepo?(repo ?? session.project) }
                        .buttonStyle(.plain)
                        .help("Show only \(session.project)")
                        .disabled(onRepo == nil)
                    if let branch = session.branch { Text(" · \(branch)") }
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(age(session.last)) · \(session.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)

            Text(session.title)
                .font(.system(size: 14, weight: .semibold))
                .lineSpacing(3)
                .lineLimit(2)
                .padding(.top, 5)

            if let summary {
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .padding(.top, 4)
            }

            if !topics.isEmpty {
                // "≈ topic", like the web version's .tag::before — these are
                // approximate groupings, not labels anyone typed.
                Text(topics.map { "≈ \($0)" }.joined(separator: "   "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .padding(.top, 7)
            }

            if !session.peers.isEmpty {
                // Chips under the title, like the web version's .tags row.
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(session.peers.prefix(2).joined(separator: ", ")
                        + (session.peers.count > 2 ? " +\(session.peers.count - 2)" : ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.purple)
                .padding(.top, 6)
                .help("Received messages from: \(session.peers.joined(separator: ", "))")
            }

            if let s = subtitle {
                Text(s)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        // Reads as a quote rather than more row text.
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.28))
                            .frame(width: 2)
                    }
                    .padding(.top, 7)
            }
        }
    }

    /// A text match shows its context; a `file:` match shows which paths hit.
    /// The match, with the term painted — same treatment the transcript gives it,
    /// so a hit looks the same wherever you meet it.
    private var subtitle: AttributedString? {
        if let term = fileTerm(query) {
            let hits = matchingFiles(session, term).prefix(3)
                .map { ($0 as NSString).lastPathComponent }
            return hits.isEmpty ? nil : highlighted(hits.joined(separator: " · "), term)
        }
        guard !query.isEmpty, let s = snippet(session.blob, term: query) else { return nil }
        return highlighted(s, query)
    }
}

private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

func age(_ epochSeconds: Double) -> String {
    relative.localizedString(for: Date(timeIntervalSince1970: epochSeconds), relativeTo: Date())
}

/// 842, 12.4k, 2.4M — token counts run to seven digits, and nobody reads those.
func compact(_ n: Int) -> String {
    switch n {
    case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
    case 10_000...: "\(n / 1000)k"
    case 1_000...: String(format: "%.1fk", Double(n) / 1000)
    default: "\(n)"
    }
}

/// "4h 12m", "35m", "50s" — a conversation's wall clock, not a duration to the second.
func spanLabel(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m" }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

/// Model ids are long and all start the same way; the part that differs is enough.
func shortModel(_ id: String) -> String {
    let name = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
    // Drop a trailing date stamp: claude-haiku-4-5-20251001 -> haiku-4-5
    let parts = name.split(separator: "-")
    if let last = parts.last, last.count == 8, Int(last) != nil {
        return parts.dropLast().joined(separator: "-")
    }
    return name
}

// --- transcript --------------------------------------------------------------

/// A message plus its parsed blocks. Markdown is parsed once when the transcript
/// loads, not on every redraw as the list scrolls.
struct RenderedMessage: Identifiable {
    let id: Int
    let role: String
    let ts: Double?
    let text: String
    let blocks: [Block]
    /// Set when the turn was relayed from another session, with the session it was
    /// traced back to (nil when the peer is gone or was never in the window).
    var from: Peer?
    var senderID: Session.ID?
}

struct TranscriptView: View {
    let session: Session
    let term: String?
    let resume: String
    let store: Store
    let onOpen: (Session.ID) -> Void
    @State private var messages: [RenderedMessage] = []
    @State private var stats = Stats()
    @State private var copied = false
    /// Which session the messages on screen belong to, so a reload can tell a
    /// switch to another conversation from more text arriving in this one.
    @State private var loaded: Session.ID?
    /// Whether the end of the transcript is on screen — what decides if a live
    /// append should be followed.
    @State private var atTail = true

    private let tailAnchor = "tail"
    private let scrollSpace = "transcript"

    /// Changes whenever the tail does. The count alone is not enough: a turn that
    /// is still being written grows in place, since consecutive parts merge into
    /// one turn rather than arriving as new ones.
    private var tailKey: String { "\(messages.count)-\(messages.last?.text.count ?? 0)" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(messages) { m in
                                MessageView(message: m, term: term, onOpen: onOpen).id(m.id)
                            }
                            // Somewhere to scroll to, and the thing whose position
                            // says whether the tail is on screen.
                            Color.clear
                                .frame(height: 1)
                                .id(tailAnchor)
                                .background(GeometryReader { tail in
                                    Color.clear.preference(
                                        key: TailDistance.self,
                                        value: tail.frame(in: .named(scrollSpace)).maxY
                                            - viewport.size.height)
                                })
                        }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: scrollSpace)
                    // Within a message or so of the end counts as "at the end" —
                    // resting exactly on the last pixel is not something anyone does.
                    .onPreferenceChange(TailDistance.self) { atTail = $0 < 120 }
                }
                // On arriving at a conversation, not on every live append — a
                // transcript that yanked back to the search hit each time Claude
                // typed another line would be unreadable.
                .onChange(of: loaded) { scrollToFirstHit(proxy) }
                // Follow a live conversation, but only from the bottom: if you have
                // scrolled up to read something, new text must not drag you away.
                .onChange(of: tailKey) {
                    guard loaded == session.id, atTail else { return }
                    withAnimation { proxy.scrollTo(tailAnchor, anchor: .bottom) }
                }
            }
        }
        // Reloads when you pick another conversation, and again whenever this one
        // grows — the watcher hands us a new Session with a higher count, which
        // would otherwise sit in the list while the open transcript went stale.
        .task(id: "\(session.id)#\(session.count)") {
            let switched = loaded != session.id
            if switched {
                copied = false
                // Blanking on a live append would flash the pane and lose the
                // scroll position; only a different conversation earns that.
                messages = []
                stats = Stats()
            }
            let path = session.path
            let result = await Task.detached(priority: .userInitiated) { () -> ([RenderedMessage], Stats) in
                let t = readTranscript(path: path)
                return (t.messages.map {
                    RenderedMessage(id: $0.id, role: $0.role, ts: $0.ts,
                                    text: $0.text, blocks: parseBlocks($0.text), from: $0.from)
                }, t.stats)
            }.value
            stats = result.1
            // Tracing a peer needs the scanned session list, which lives out here.
            messages = result.0.map { m in
                guard let peer = m.from else { return m }
                var m = m
                m.senderID = store.sender(peer, at: m.ts)?.id
                return m
            }
            loaded = session.id
        }
    }

    /// The pane owns its title, so the transcript reads as a document rather than
    /// borrowing the window's titlebar.
    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.project)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                StatsLine(stats: stats, session: session)
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resume, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Resume",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help(resume)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
    }

    /// Open a search result on the match, not at the top.
    private func scrollToFirstHit(_ proxy: ScrollViewProxy) {
        guard let term, !term.isEmpty,
              let hit = messages.first(where: {
                  $0.text.range(of: term, options: .caseInsensitive) != nil
              }) else { return }
        withAnimation { proxy.scrollTo(hit.id, anchor: .center) }
    }
}

/// One line of "what this conversation was", under the title: branch, models,
/// wall clock, size, and what it cost. The full breakdown is a tooltip — the
/// header is for recognising a conversation, not for auditing it.
struct StatsLine: View {
    let stats: Stats
    let session: Session

    var body: some View {
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detail)
                .padding(.top, 2)
        }
    }

    private var parts: [String] {
        var out: [String] = []
        if let branch = session.branch { out.append(branch) }
        if !stats.models.isEmpty {
            out.append(stats.models.map(shortModel).joined(separator: " + "))
        }
        if stats.span >= 1 { out.append(spanLabel(stats.span)) }
        out.append("\(session.count) msgs")
        if !session.files.isEmpty { out.append("\(session.files.count) files") }
        if stats.toolCalls > 0 { out.append("\(stats.toolCalls) tools") }
        if stats.input + stats.output > 0 {
            out.append("\(compact(stats.input))↓ \(compact(stats.output))↑")
        }
        return out
    }

    /// Spelled out, with the numbers the one-liner rounds off.
    private var detail: String {
        var lines: [String] = []
        if !stats.models.isEmpty {
            lines.append("Models: " + stats.models.map(shortModel).joined(separator: ", "))
        }
        if stats.input + stats.output > 0 {
            // "in" is everything sent, cache reads included — that is what the log
            // records and what the context actually cost to carry.
            var t = "Tokens: \(stats.input.formatted()) in (cache included)"
                + ", \(stats.output.formatted()) out"
            if stats.thinking > 0 { t += ", \(stats.thinking.formatted()) thinking" }
            lines.append(t)
        }
        if !stats.tools.isEmpty {
            let top = stats.tools.prefix(6).map { "\($0.name) \($0.count)" }
            lines.append("Tools: " + top.joined(separator: ", ")
                + (stats.tools.count > 6 ? ", +\(stats.tools.count - 6) more" : ""))
        }
        if !session.peers.isEmpty {
            lines.append("Messaged by: " + session.peers.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

/// How far past the bottom of the visible area the end of the transcript sits.
/// Negative or small means the tail is on screen.
private struct TailDistance: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessageView: View {
    let message: RenderedMessage
    let term: String?
    let onOpen: (Session.ID) -> Void

    private var isUser: Bool { message.role == "user" }

    /// Your turns sit in a tinted card pushed to the right; Claude's run full width
    /// as plain document text. The asymmetry is in the block, not the text — prose
    /// set flush right is hard to read back, and code blocks can't align that way
    /// at all. Runs alternate after merging, so no separators are needed.
    var body: some View {
        if let peer = message.from {
            PeerMessageView(peer: peer, senderID: message.senderID, blocks: message.blocks,
                            ts: message.ts, term: term, onOpen: onOpen)
        } else if isUser {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.22)))
                // The 720 box caps how wide a long turn wraps; the card inside it
                // is content-sized, so it must hug the box's trailing edge too —
                // otherwise a short message floats in the middle of the pane.
                .frame(maxWidth: 720, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 9)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 15)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(isUser ? "You" : "Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isUser ? Color.accentColor : .secondary)
                if let ts = message.ts {
                    Text(age(ts)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            MarkdownView(blocks: message.blocks, highlight: term)
        }
    }
}


/// A turn relayed from another Claude session — neither you nor this session's
/// Claude, so it gets its own colour and sits full width rather than in either
/// speaker's lane. Clicking through jumps to the session it came from.
struct PeerMessageView: View {
    let peer: Peer
    let senderID: Session.ID?
    let blocks: [Block]
    let ts: Double?
    let term: String?
    let onOpen: (Session.ID) -> Void

    private let tint = Color.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Text(peer.name)
                    .font(.system(size: 12, weight: .semibold))
                if let mode = peer.mode {
                    Text(mode).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let ts { Text(age(ts)).font(.system(size: 10)).foregroundStyle(.tertiary) }

                Spacer(minLength: 8)

                if let senderID {
                    Button { onOpen(senderID) } label: {
                        Label("Open session", systemImage: "arrow.up.forward.square")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                } else {
                    // The socket in the tag is long dead, so an unmatched name is
                    // all that is left — say so rather than offering a dead link.
                    Text("sender not in window")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(tint)

            MarkdownView(blocks: blocks, highlight: term)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.25)))
        .padding(.vertical, 9)
    }
}
