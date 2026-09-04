import CoreServices
import Foundation

/// Calls back when anything under a directory tree changes.
///
/// ponytail: FSEvents rather than a timer. A rescan reads every session file in
/// the 4-week window, so polling for changes would cost far more than the changes
/// are worth, and a live conversation writes a line every few seconds, which a
/// poll would either miss or chase. The stream's own latency does the coalescing,
/// so a burst of appends is one rescan.
final class Watcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    /// `latency` seconds of writes are coalesced into one callback.
    init?(path: String, latency: CFTimeInterval = 2, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            // NoDefer: fire at the *start* of a quiet burst, so the first write
            // after a pause shows up now rather than `latency` later.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
