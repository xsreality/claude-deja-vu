import SwiftUI

// Not @main: top-level code lives here so --selftest can run without a UI,
// mirroring `python3 dashboard.py --selftest`.
if CommandLine.arguments.contains("--selftest") {
    runSelftest()
    exit(0)
}

// The Cross-reference button, headless: the one way to exercise the `claude -p`
// call (PATH probing, pipes, parsing) without a UI in front of it.
if CommandLine.arguments.contains("--analyze") {
    do {
        let i = try runAnalysis(scanAll().sessions)
        print("\(i.summaries.count) summaries, \(i.clusters.count) clusters → \(insightsFile)")
        for c in i.clusters { print("  \(c.label): \(c.session_ids.count)") }
    } catch {
        print("failed: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// Parity probe against the frozen Python implementation:
//   swift run DejaVu --dump | diff - <(python3 dashboard.py --dump)
if let i = CommandLine.arguments.firstIndex(of: "--dump") {
    let query = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
    var found = scanAll().sessions
    if let term = fileTerm(query) {
        found = found.filter { !matchingFiles($0, term).isEmpty }
    } else if !query.isEmpty {
        found = found.filter { $0.blobLower.contains(query.lowercased()) }
    }
    for s in found {
        print("\(s.id)\t\(s.count)\t\(s.files.count)\t\(s.project)\t\(s.title.replacingOccurrences(of: "\n", with: " "))")
    }
    exit(0)
}

DejaVuApp.main()
