import CoreServices
import Foundation

public struct ChangeJournalSnapshot: Sendable, Equatable {
  public let paths: Set<String>
  public let complete: Bool
  public let latestEventID: FSEventStreamEventId
  public let generation: UInt64

  public init(
    paths: Set<String>, complete: Bool, latestEventID: FSEventStreamEventId, generation: UInt64
  ) {
    self.paths = paths
    self.complete = complete
    self.latestEventID = latestEventID
    self.generation = generation
  }
}

/// A small public-API change journal. It never claims that an event stream is
/// complete when macOS reports dropped events; callers must then run a full scan.
public final class FSEventsChangeJournal: @unchecked Sendable {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var paths = Set<String>()
    var dropped = false
    var latestEventID: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    var generation: UInt64 = 0
    var stream: FSEventStreamRef?

    func record(path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId) {
      lock.lock()
      defer { lock.unlock() }
      paths.insert(path)
      latestEventID = max(latestEventID, eventID)
      generation &+= 1
      let incompleteFlags =
        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
      if flags & incompleteFlags != 0 { dropped = true }
    }

    func snapshot(rootPath: String) -> ChangeJournalSnapshot {
      lock.lock()
      defer { lock.unlock() }
      let filtered = Set(paths.filter { pathIsEqualOrDescendant($0, of: rootPath) })
      return ChangeJournalSnapshot(
        paths: filtered, complete: !dropped, latestEventID: latestEventID, generation: generation)
    }

    func reset() {
      lock.lock()
      paths.removeAll(keepingCapacity: true)
      dropped = false
      lock.unlock()
    }
  }

  private let state: State

  public init(rootPath: String = "/") {
    state = State()
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(state).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let paths = [rootPath] as CFArray
    let flags =
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
    let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
      guard let info else { return }
      let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
      let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      for index in 0..<count {
        let path = paths[index]
        state.record(
          path: String(cString: path), flags: rawFlags[index], eventID: rawIDs[index])
      }
    }
    state.stream = FSEventStreamCreate(
      nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
      flags
    )
    if let stream = state.stream {
      FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "io.github.NikkyWay.OpenDiskTree.fsevents"))
      FSEventStreamStart(stream)
    }
  }

  deinit {
    guard let stream = state.stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  public func snapshot(for rootURL: URL) -> ChangeJournalSnapshot {
    state.snapshot(rootPath: rootURL.standardizedFileURL.path)
  }

  public func generation() -> UInt64 {
    state.lock.lock()
    defer { state.lock.unlock() }
    return state.generation
  }

  public func resetBaseline() { state.reset() }
}

private func pathIsEqualOrDescendant(_ path: String, of root: String) -> Bool {
  path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}
