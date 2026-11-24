import CoreServices
import Foundation

/// Debounced FSEvents watch. `onChange` receives the library root that changed.
final class FolderWatch {
    var onChange: ((String) -> Void)?

    private let state = NSLock()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.tim.chronicle.fsevents")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var roots: [String] = []
    private var pending: [String: DispatchWorkItem] = [:]

    func setRoots(_ paths: [String]) {
        let normalized = paths.map { PathGuard.canonical($0) }
        state.lock()
        let same = normalized == roots
        if !same { roots = normalized }
        state.unlock()
        if same { return }
        restart()
    }

    func stop() {
        queue.setSpecific(key: queueKey, value: 1)
        state.lock()
        let current = stream
        stream = nil
        state.unlock()
        if let current {
            FSEventStreamStop(current)
        }
        // Wait until an in-flight event finishes. Skip the wait on that queue:
        // its last callback can release this watch, and syncing would deadlock.
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
        state.lock()
        let waiting = pending
        pending.removeAll()
        state.unlock()
        waiting.values.forEach { $0.cancel() }
        if let current {
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
        }
    }

    deinit { stop() }

    private func restart() {
        stop()
        state.lock()
        let paths = roots
        state.unlock()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
                let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                guard let paths = array as? [String] else { return }
                watch.note(paths)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8,
            flags
        ) else { return }

        state.lock()
        stream = created
        state.unlock()
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Every watched root that contains `path`. A folder and a folder inside it can both be watched.
    static func affectedRoots(_ path: String, roots: [String]) -> [String] {
        roots.filter { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func note(_ paths: [String]) {
        state.lock()
        let roots = self.roots
        state.unlock()
        var dirty = Set<String>()
        for path in paths {
            let resolved = PathGuard.canonicalLeaf(path)
            dirty.formUnion(Self.affectedRoots(resolved, roots: roots))
        }
        for root in dirty {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.state.lock()
                self.pending[root] = nil
                self.state.unlock()
                let change = self.onChange
                DispatchQueue.main.async {
                    change?(root)
                }
            }
            state.lock()
            pending[root]?.cancel()
            pending[root] = work
            state.unlock()
            queue.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }
}
