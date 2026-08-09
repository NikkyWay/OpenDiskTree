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
    var pathEventIDs: [String: FSEventStreamEventId] = [:]
    var dropped = false
    var historyComplete: Bool
    var latestEventID: FSEventStreamEventId
    var generation: UInt64 = 0
    var stream: FSEventStreamRef?
    let ignoredRootPaths: [String]

    init(sinceEventID: FSEventStreamEventId, ignoredRootPaths: [String]) {
      let sinceNow = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
      historyComplete = sinceEventID == sinceNow
      latestEventID = sinceEventID == sinceNow ? FSEventsGetCurrentEventId() : sinceEventID
      self.ignoredRootPaths = ignoredRootPaths
    }

    func record(path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId) {
      lock.lock()
      defer { lock.unlock() }
      if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
        historyComplete = true
      }
      guard !ignoredRootPaths.contains(where: { pathIsEqualOrDescendant(path, of: $0) }) else {
        latestEventID = max(latestEventID, eventID)
        return
      }
      pathEventIDs[path] = max(pathEventIDs[path] ?? 0, eventID)
      latestEventID = max(latestEventID, eventID)
      generation &+= 1
      let incompleteFlags =
        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
      if flags & incompleteFlags != 0 { dropped = true }
    }

    func snapshot(
      rootPath: String,
      sinceEventID: FSEventStreamEventId?
    ) -> ChangeJournalSnapshot {
      lock.lock()
      defer { lock.unlock() }
      let filtered = Set<String>(
        pathEventIDs.compactMap { path, eventID in
          guard pathIsEqualOrDescendant(path, of: rootPath),
            sinceEventID.map({ eventID > $0 }) ?? true
          else { return nil }
          return path
        })
      return ChangeJournalSnapshot(
        paths: filtered, complete: historyComplete && !dropped,
        latestEventID: latestEventID, generation: generation)
    }

    func advanceBaseline(to eventID: FSEventStreamEventId) {
      lock.lock()
      // Keep events that arrived after the snapshot being committed. Clearing
      // the whole map here creates a race where filesystem changes made during
      // a scan disappear from the next incremental update.
      pathEventIDs = pathEventIDs.filter { $0.value > eventID }
      dropped = false
      historyComplete = true
      lock.unlock()
    }
  }

  private let state: State

  public init(
    rootPath: String = "/",
    sinceEventID: FSEventStreamEventId = FSEventStreamEventId(
      kFSEventStreamEventIdSinceNow),
    ignoredRootPaths: [String] = []
  ) {
    state = State(
      sinceEventID: sinceEventID,
      ignoredRootPaths: ignoredRootPaths.map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
      })
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
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
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
      nil, callback, &context, paths, sinceEventID, 0.15,
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

  public func snapshot(
    for rootURL: URL,
    sinceEventID: FSEventStreamEventId? = nil
  ) -> ChangeJournalSnapshot {
    state.snapshot(
      rootPath: rootURL.standardizedFileURL.path,
      sinceEventID: sinceEventID)
  }

  public func generation() -> UInt64 {
    state.lock.lock()
    defer { state.lock.unlock() }
    return state.generation
  }

  /// Commits exactly the event boundary represented by a completed scan.
  /// Events newer than this boundary remain queued for the next update.
  public func advanceBaseline(to eventID: FSEventStreamEventId) {
    state.advanceBaseline(to: eventID)
  }
}

private func pathIsEqualOrDescendant(_ path: String, of root: String) -> Bool {
  path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}
