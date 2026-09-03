import Darwin
import Foundation
import OSLog

private let scannerSignposter = OSSignposter(
  subsystem: "io.github.NikkyWay.OpenDiskTree", category: "Scanner")

public actor ScanControl {
  private var paused = false
  private var cancelled = false

  public init() {}

  public func pause() { paused = true }
  public func resume() { paused = false }
  public func cancel() {
    cancelled = true
    paused = false
  }
  public func reset() {
    paused = false
    cancelled = false
  }
  public func isCancelled() -> Bool { cancelled }

  fileprivate func checkpoint() async -> Bool {
    while paused && !cancelled {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return !cancelled
  }
}

public struct ScanOptions: Sendable {
  public let rootURL: URL
  public let intensity: ScanIntensity
  public let crossSelectedVolume: Bool
  public let mode: ScanMode
  public let startingItemID: Int64

  public init(
    rootURL: URL,
    intensity: ScanIntensity = .balanced,
    crossSelectedVolume: Bool = false,
    mode: ScanMode = .full,
    startingItemID: Int64 = 2
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.intensity = intensity
    self.crossSelectedVolume = crossSelectedVolume
    self.mode = mode
    self.startingItemID = max(2, startingItemID)
  }
}

public struct ReusedSubtree: Sendable, Equatable {
  public let itemID: Int64
  public let itemCount: Int64
  public let fileCount: Int64
  public let directoryCount: Int64
  public let logicalBytes: UInt64
  public let allocatedBytes: UInt64
  public let maximumDepth: Int
  public let containsHardLinks: Bool
  public let classification: Classification

  public init(
    itemID: Int64,
    itemCount: Int64,
    fileCount: Int64,
    directoryCount: Int64,
    logicalBytes: UInt64,
    allocatedBytes: UInt64,
    maximumDepth: Int,
    containsHardLinks: Bool,
    classification: Classification
  ) {
    self.itemID = itemID
    self.itemCount = itemCount
    self.fileCount = fileCount
    self.directoryCount = directoryCount
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
    self.maximumDepth = maximumDepth
    self.containsHardLinks = containsHardLinks
    self.classification = classification
  }
}

private struct PendingDirectory: Sendable {
  let id: Int64
  let path: String
  let depth: Int
  let deviceID: UInt64
}

private struct ReadOutcome: Sendable {
  let directory: PendingDirectory
  let listing: NativeDirectoryListing?
  let error: DirectoryReadError?
}

private struct FileIdentity: Hashable, Sendable {
  let device: UInt64
  let file: UInt64
}

private struct WorkingDirectoryRollup: Sendable {
  let itemID: Int64
  let parentID: Int64?
  let depth: Int
  let ownClassification: Classification
  var logicalBytes: UInt64 = 0
  var allocatedBytes: UInt64 = 0
  var maximumChildRisk = 0
  var nonReviewChildren = 0
  var childCount = 0
  var containsProtectedRule = false
  var itemCount: Int64 = 0
  var fileCount: Int64 = 0
  var directoryCount: Int64 = 0
  var maximumDepth: Int
  var containsHardLinks = false
  var precomputedClassification: Classification?

  init(
    itemID: Int64,
    parentID: Int64?,
    depth: Int,
    ownClassification: Classification
  ) {
    self.itemID = itemID
    self.parentID = parentID
    self.depth = depth
    self.ownClassification = ownClassification
    maximumDepth = depth
  }

  mutating func absorb(
    logicalBytes: UInt64,
    allocatedBytes: UInt64,
    classification: Classification,
    itemCount: Int64 = 0,
    fileCount: Int64 = 0,
    directoryCount: Int64 = 0,
    maximumDepth: Int? = nil,
    containsHardLinks: Bool = false
  ) {
    self.logicalBytes &+= logicalBytes
    self.allocatedBytes &+= allocatedBytes
    maximumChildRisk = max(maximumChildRisk, classification.status.riskRank)
    if classification.status != .review { nonReviewChildren += 1 }
    childCount += 1
    containsProtectedRule = containsProtectedRule || classification.isProtectedRule
    self.itemCount += itemCount
    self.fileCount += fileCount
    self.directoryCount += directoryCount
    self.maximumDepth = max(self.maximumDepth, maximumDepth ?? depth)
    self.containsHardLinks = self.containsHardLinks || containsHardLinks
  }

  mutating func useReusedSubtree(_ subtree: ReusedSubtree) {
    logicalBytes = subtree.logicalBytes
    allocatedBytes = subtree.allocatedBytes
    itemCount = subtree.itemCount
    fileCount = subtree.fileCount
    directoryCount = subtree.directoryCount
    maximumDepth = subtree.maximumDepth
    containsHardLinks = subtree.containsHardLinks
    precomputedClassification = subtree.classification
  }

  func finalizedClassification() -> Classification {
    if let precomputedClassification { return precomputedClassification }
    if ownClassification.isProtectedRule,
      ownClassification.status == .doNotTouch || ownClassification.status == .deleteViaSourceApp
    {
      return ownClassification
    }

    let status: SafetyStatus
    let reason: String
    switch maximumChildRisk {
    case 5...:
      status = .doNotTouch
      reason = "This folder contains protected data and must not be removed directly."
    case 4:
      status = .deleteViaSourceApp
      reason =
        "This folder contains application-managed data. Use the source application for cleanup."
    case 0:
      status = .safeToDelete
      reason = "All scanned contents matched safe cleanup rules."
    case 1:
      status = .recreatedAutomatically
      reason = "All scanned contents are disposable or can be rebuilt automatically."
    case 2 where nonReviewChildren == 0:
      status = .review
      reason = "No trusted cleanup rule matched this folder or its contents."
    default:
      status = .mixed
      reason = "This folder contains mixed safety statuses. Inspect its contents before cleanup."
    }
    return Classification(
      status: status,
      ruleID: "aggregate.folder",
      reason: reason,
      confidence: .high,
      isProtectedRule: ownClassification.isProtectedRule || containsProtectedRule
    )
  }
}

public final class DiskScanner: Sendable {
  public let control: ScanControl
  private let ruleEngine: RuleEngine

  public init(ruleEngine: RuleEngine = RuleEngine(), control: ScanControl = ScanControl()) {
    self.ruleEngine = ruleEngine
    self.control = control
  }

  public func scan(
    scanID: Int64,
    rootItemID: Int64,
    options: ScanOptions,
    onBatch: @Sendable ([ScannedItem], ScanProgress) async throws -> Void,
    onErrors: @Sendable ([ScanErrorRecord]) async throws -> Void,
    onProgress: @Sendable (ScanProgress) async -> Void = { _ in },
    reuseCatalog: SubtreeReuseCatalog? = nil,
    changedPaths: [String] = [],
    onReuseCandidate: @Sendable (ScannedItem) async throws -> ReusedSubtree? = { _ in nil },
    onReuseSubtree: (@Sendable (ReusedSubtree, ScannedItem) async throws -> Void)? = nil
  ) async throws -> ScannerResult {
    let signpostState = scannerSignposter.beginInterval("Disk scan")
    defer { scannerSignposter.endInterval("Disk scan", signpostState) }
    await control.reset()
    let rootPath = options.rootURL.path
    let rootStat = try Self.statItem(path: rootPath)
    var queue = [
      PendingDirectory(id: rootItemID, path: rootPath, depth: 0, deviceID: rootStat.deviceID)
    ]
    var cursor = 0
    var nextID = options.startingItemID
    var progress = ScanProgress(currentPath: rootPath)
    progress.directories = 1
    var linkedStorage = Set<FileIdentity>()
    var bulkCount = 0
    var fallbackCount = 0
    var maximumDepth = 0
    var reusedItemCount: Int64 = 0
    var reusedPaths: [String] = []
    let collectDirectoryRollups = true
    var directoryOrder: [Int64] = [rootItemID]
    var workingDirectories: [Int64: WorkingDirectoryRollup] = [:]
    if collectDirectoryRollups {
      workingDirectories.reserveCapacity(400_000)
      workingDirectories[rootItemID] = WorkingDirectoryRollup(
        itemID: rootItemID,
        parentID: nil,
        depth: 0,
        ownClassification: ruleEngine.classify(path: rootPath, kind: .directory)
      )
    }
    // Larger transactions avoid SQLite fsync/prepare overhead on metadata-heavy scans.
    // The live refresh gate in AppModel keeps the first useful rows responsive.
    let batchLimit = options.intensity == .turbo ? 32_768 : 16_384
    var bufferedItems: [ScannedItem] = []
    bufferedItems.reserveCapacity(batchLimit)
    var lastFlush = Date()
    var lastProgressUpdate = Date()
    let minimumFlushCount = options.intensity == .turbo ? 8_192 : 4_096
    let flushInterval: TimeInterval = 0.75

    try await withThrowingTaskGroup(of: ReadOutcome.self) { group in
      let parallelism = options.intensity.parallelism
      var activeReaders = 0
      var errors: [ScanErrorRecord] = []

      while activeReaders < parallelism && cursor < queue.count {
        let directory = queue[cursor]
        cursor += 1
        activeReaders += 1
        group.addTask { Self.readDirectory(directory) }
      }

      while activeReaders > 0 {
        guard await control.checkpoint(), !Task.isCancelled else {
          group.cancelAll()
          break
        }
        guard let outcome = try await group.next() else { break }
        activeReaders -= 1

        // Keep readers busy with already discovered work before processing a
        // potentially very wide directory on the coordinator task.
        while activeReaders < parallelism && cursor < queue.count {
          let directory = queue[cursor]
          cursor += 1
          activeReaders += 1
          group.addTask { Self.readDirectory(directory) }
        }

        progress.currentPath = outcome.directory.path
        if let error = outcome.error {
          if Self.shouldReportDirectoryReadError(
            path: outcome.directory.path,
            rootPath: rootPath,
            code: error.code
          ) {
            progress.inaccessible += 1
            errors.append(
              ScanErrorRecord(
                scanID: scanID,
                path: outcome.directory.path,
                code: error.code,
                message: error.message
              ))
          }
        } else if let listing = outcome.listing {
          if listing.usedBulkAPI { bulkCount += 1 } else { fallbackCount += 1 }

          var entriesSinceCheckpoint = 0
          for entry in listing.entries {
            // Checking an actor for every directory entry is disproportionately
            // expensive on metadata-heavy trees. Task cancellation remains cheap
            // per item; pause/cancel actor state is sampled often enough to stay
            // responsive without turning the hot path into millions of awaits.
            guard !Task.isCancelled else { break }
            entriesSinceCheckpoint += 1
            if entriesSinceCheckpoint >= 256 {
              entriesSinceCheckpoint = 0
              guard await control.checkpoint() else { break }
            }
            let path =
              outcome.directory.path == "/"
              ? "/\(entry.name)" : "\(outcome.directory.path)/\(entry.name)"
            if Self.shouldSkip(path: path, rootPath: rootPath) { continue }

            let depth = outcome.directory.depth + 1
            maximumDepth = max(maximumDepth, depth)
            let isContainer = entry.kind.canHaveChildren
            let ownLogical = isContainer ? 0 : entry.logicalBytes
            let ownAllocated = isContainer ? 0 : entry.allocatedBytes
            var accountedAllocated = ownAllocated
            if entry.kind == .file && entry.linkCount > 1 {
              let identity = FileIdentity(device: entry.deviceID, file: entry.fileID)
              if !linkedStorage.insert(identity).inserted { accountedAllocated = 0 }
            }
            let classification = ruleEngine.classify(
              path: path,
              kind: entry.kind,
              fileExtension: entry.fileExtension
            )
            let provisionalID = nextID
            nextID += 1
            let provisionalItem = ScannedItem(
              id: provisionalID,
              scanID: scanID,
              parentID: outcome.directory.id,
              path: path,
              name: entry.name,
              depth: depth,
              kind: entry.kind,
              fileExtension: entry.fileExtension,
              ownLogicalBytes: ownLogical,
              ownAllocatedBytes: ownAllocated,
              accountedAllocatedBytes: accountedAllocated,
              logicalBytes: ownLogical,
              allocatedBytes: accountedAllocated,
              createdAt: entry.createdAt,
              modifiedAt: entry.modifiedAt,
              deviceID: entry.deviceID,
              fileID: entry.fileID,
              linkCount: entry.linkCount,
              isHidden: entry.isHidden,
              isPackage: entry.isPackage,
              classification: classification
            )
            let reuse: ReusedSubtree?
            if isContainer, let reuseCatalog {
              // Avoid an async hop for every directory in the production
              // incremental path. The catalog is immutable and safe to match
              // directly on the scanner coordinator.
              reuse = reuseCatalog.match(
                candidate: provisionalItem, changedPaths: changedPaths)
            } else if isContainer {
              reuse = try await onReuseCandidate(provisionalItem)
            } else {
              reuse = nil
            }
            let id: Int64
            let item: ScannedItem
            if let reuse {
              // Reused IDs keep parent references stable across snapshots. The store
              // copies descendants only after this parent row has been committed.
              id = reuse.itemID
              item = ScannedItem(
                id: id, scanID: provisionalItem.scanID, parentID: provisionalItem.parentID,
                path: provisionalItem.path, name: provisionalItem.name,
                depth: provisionalItem.depth,
                kind: provisionalItem.kind, fileExtension: provisionalItem.fileExtension,
                ownLogicalBytes: provisionalItem.ownLogicalBytes,
                ownAllocatedBytes: provisionalItem.ownAllocatedBytes,
                accountedAllocatedBytes: provisionalItem.accountedAllocatedBytes,
                logicalBytes: provisionalItem.logicalBytes,
                allocatedBytes: provisionalItem.allocatedBytes,
                createdAt: provisionalItem.createdAt, modifiedAt: provisionalItem.modifiedAt,
                deviceID: provisionalItem.deviceID, fileID: provisionalItem.fileID,
                linkCount: provisionalItem.linkCount, isHidden: provisionalItem.isHidden,
                isPackage: provisionalItem.isPackage, classification: provisionalItem.classification
              )
            } else {
              id = provisionalID
              item = provisionalItem
            }
            bufferedItems.append(item)
            if isContainer {
              if collectDirectoryRollups {
                directoryOrder.append(id)
                workingDirectories[id] = WorkingDirectoryRollup(
                  itemID: id,
                  parentID: outcome.directory.id,
                  depth: depth,
                  ownClassification: classification
                )
              }
              progress.directories += 1
              if let reuse {
                workingDirectories[id]?.useReusedSubtree(reuse)
                reusedPaths.append(item.path)
                // An in-place overlay only records this boundary. Keep normal
                // batching instead of issuing one SQLite call per reused folder.
                if let onReuseSubtree { try await onReuseSubtree(reuse, item) }
                reusedItemCount += reuse.itemCount
                progress.files += reuse.fileCount
                progress.directories += reuse.directoryCount
                progress.logicalBytes &+= reuse.logicalBytes
                progress.allocatedBytes &+= reuse.allocatedBytes
                maximumDepth = max(maximumDepth, reuse.maximumDepth)
                continue
              }
              if Self.shouldTraverseDirectory(
                rootDeviceID: rootStat.deviceID,
                entryDeviceID: entry.deviceID,
                isMountPoint: entry.isMountPoint,
                crossSelectedVolume: options.crossSelectedVolume)
              {
                queue.append(
                  PendingDirectory(id: id, path: path, depth: depth, deviceID: entry.deviceID))
              }
            } else {
              if collectDirectoryRollups {
                workingDirectories[outcome.directory.id]?.absorb(
                  logicalBytes: ownLogical,
                  allocatedBytes: accountedAllocated,
                  classification: classification,
                  itemCount: 1,
                  fileCount: entry.kind == .file ? 1 : 0,
                  maximumDepth: depth,
                  containsHardLinks: entry.linkCount > 1
                )
              }
              progress.files += 1
              progress.logicalBytes &+= ownLogical
              progress.allocatedBytes &+= accountedAllocated
            }

            if bufferedItems.count >= batchLimit {
              await onProgress(progress)
              try await onBatch(bufferedItems, progress)
              bufferedItems.removeAll(keepingCapacity: true)
              lastFlush = Date()
            }
          }
        }

        while activeReaders < parallelism && cursor < queue.count {
          let directory = queue[cursor]
          cursor += 1
          activeReaders += 1
          group.addTask { Self.readDirectory(directory) }
        }
        if errors.count >= 128 {
          try await onErrors(errors)
          errors.removeAll(keepingCapacity: true)
        }
        if Date().timeIntervalSince(lastProgressUpdate) >= 0.5 {
          await onProgress(progress)
          lastProgressUpdate = Date()
        }
        if bufferedItems.count >= minimumFlushCount
          && Date().timeIntervalSince(lastFlush) >= flushInterval
        {
          try await onBatch(bufferedItems, progress)
          bufferedItems.removeAll(keepingCapacity: true)
          lastFlush = Date()
        }
        if cursor > 10_000 && cursor > queue.count / 2 {
          queue.removeFirst(cursor)
          cursor = 0
        }
      }
      if !errors.isEmpty { try await onErrors(errors) }
    }

    if !bufferedItems.isEmpty { try await onBatch(bufferedItems, progress) }

    var directoryRollups: [DirectoryRollup] = []
    let controlCancelled = await control.isCancelled()
    if collectDirectoryRollups && !Task.isCancelled && !controlCancelled {
      directoryRollups.reserveCapacity(directoryOrder.count)
      for itemID in directoryOrder.reversed() {
        guard let working = workingDirectories.removeValue(forKey: itemID) else { continue }
        let classification = working.finalizedClassification()
        directoryRollups.append(
          DirectoryRollup(
            itemID: working.itemID,
            logicalBytes: working.logicalBytes,
            allocatedBytes: working.allocatedBytes,
            itemCount: working.itemCount,
            fileCount: working.fileCount,
            directoryCount: working.directoryCount,
            maximumDepth: working.maximumDepth,
            containsHardLinks: working.containsHardLinks,
            classification: classification
          ))
        if let parentID = working.parentID {
          workingDirectories[parentID]?.absorb(
            logicalBytes: working.logicalBytes,
            allocatedBytes: working.allocatedBytes,
            classification: classification,
            itemCount: working.itemCount + 1,
            fileCount: working.fileCount,
            directoryCount: working.directoryCount + 1,
            maximumDepth: working.maximumDepth,
            containsHardLinks: working.containsHardLinks
          )
        }
      }
    }

    return ScannerResult(
      progress: progress,
      cancelled: await control.isCancelled() || Task.isCancelled,
      bulkDirectoryCount: bulkCount,
      fallbackDirectoryCount: fallbackCount,
      maximumDepth: maximumDepth,
      reusedItemCount: reusedItemCount,
      reusedPaths: reusedPaths,
      journalComplete: true,
      directoryRollups: directoryRollups
    )
  }

  public static func makeRootItem(
    scanID: Int64, id: Int64, url: URL, engine: RuleEngine = RuleEngine()
  ) throws -> ScannedItem {
    let info = try statItem(path: url.path)
    return ScannedItem(
      id: id, scanID: scanID, parentID: nil, path: url.path,
      name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
      depth: 0, kind: .directory, fileExtension: nil,
      ownLogicalBytes: 0, ownAllocatedBytes: 0, accountedAllocatedBytes: 0,
      logicalBytes: 0, allocatedBytes: 0,
      createdAt: info.createdAt, modifiedAt: info.modifiedAt,
      deviceID: info.deviceID, fileID: info.fileID, linkCount: info.linkCount,
      isHidden: false, isPackage: false,
      classification: engine.classify(path: url.path, kind: .directory)
    )
  }

  private static func statItem(path: String) throws -> (
    deviceID: UInt64, fileID: UInt64, linkCount: UInt32, createdAt: Date?, modifiedAt: Date?
  ) {
    var info = stat()
    let result = path.withCString { lstat($0, &info) }
    if result != 0 {
      throw DirectoryReadError.posix(
        path: path, code: errno, message: String(cString: strerror(errno)))
    }
    return (
      UInt64(info.st_dev), UInt64(info.st_ino), UInt32(info.st_nlink),
      info.st_birthtimespec.tv_sec > 0
        ? Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)) : nil,
      info.st_mtimespec.tv_sec > 0
        ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
    )
  }

  private static func readDirectory(_ directory: PendingDirectory) -> ReadOutcome {
    do {
      return ReadOutcome(
        directory: directory,
        listing: try FastDirectoryReader.read(path: directory.path),
        error: nil
      )
    } catch let error as DirectoryReadError {
      return ReadOutcome(directory: directory, listing: nil, error: error)
    } catch {
      return ReadOutcome(
        directory: directory,
        listing: nil,
        error: .posix(path: directory.path, code: EIO, message: error.localizedDescription)
      )
    }
  }

  static func shouldTraverseDirectory(
    rootDeviceID: UInt64,
    entryDeviceID: UInt64,
    isMountPoint: Bool,
    crossSelectedVolume: Bool
  ) -> Bool {
    crossSelectedVolume || (!isMountPoint && entryDeviceID == rootDeviceID)
  }

  static func shouldSkip(path: String, rootPath: String) -> Bool {
    guard rootPath == "/" else { return false }
    let excluded = [
      "/Volumes", "/System/Volumes/Data", "/System/Volumes/VM", "/System/Volumes/Preboot",
      "/System/Volumes/Update", "/System/Volumes/xarts", "/System/Volumes/iSCPreboot",
      "/System/Volumes/Hardware",
      "/Network", "/net", "/home", "/dev",
    ]
    return excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
  }

  static func shouldReportDirectoryReadError(path: String, rootPath: String, code: Int32) -> Bool {
    guard rootPath == "/", code == EACCES || code == EPERM else { return true }

    // A non-privileged macOS app cannot traverse these system-owned locations,
    // even with Full Disk Access. They are expected gaps in a full-disk scan,
    // not actionable scan failures. Explicit folder scans still report them.
    let protectedSystemPaths = [
      "/System",
      "/private/var",
      "/private/etc/cups/certs",
      "/usr/sbin/authserver",
      "/Library/Application Support/Apple/AssetCache/Data",
      "/Library/Application Support/Apple/ParentalControls/Users",
      "/Library/Caches/com.apple.amsengagementd.classicdatavault",
      "/Library/Caches/com.apple.aned",
      "/Library/Caches/com.apple.aneuserd",
      "/Library/Caches/com.apple.iconservices.store",
    ]
    return !protectedSystemPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
  }
}
