import SwiftUI

// Not @main: top-level code lives here so --selftest can run without a UI,
// mirroring `python3 dashboard.py --selftest`.
if CommandLine.arguments.contains("--selftest") {
    runSelftest()
    exit(0)
}

// Parity probe against the frozen Python implementation:
//   swift run DejaVu --dump | diff - <(python3 dashboard.py --dump)
if let i = CommandLine.arguments.firstIndex(of: "--dump") {
    let query = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
    var found = scanAll()
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
