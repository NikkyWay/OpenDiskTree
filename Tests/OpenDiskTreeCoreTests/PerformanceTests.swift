import Foundation
import Testing

@testable import OpenDiskTreeCore

@Test(.timeLimit(.minutes(20)))
func realFilesystemTraversalBenchmark() async throws {
  guard let path = ProcessInfo.processInfo.environment["OPENDISKTREE_BENCHMARK_ROOT"],
    !path.isEmpty
  else { return }

  let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  let scanner = DiskScanner()
  let clock = ContinuousClock()
  let intensity: ScanIntensity =
    ProcessInfo.processInfo.environment["OPENDISKTREE_BENCHMARK_INTENSITY"] == "balanced"
    ? .balanced : .turbo
  if ProcessInfo.processInfo.environment["OPENDISKTREE_BENCHMARK_STORE"] == "1" {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenDiskTreeRealBenchmark-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let store = try ScanStore(databaseURL: scratch.appendingPathComponent("benchmark.sqlite"))
    let scan = try await store.beginScan(rootURL: root, intensity: intensity)
    let rootItem = try DiskScanner.makeRootItem(scanID: scan.id, id: 1, url: root)
    try await store.insert([rootItem])
    let batchWriter = ScanBatchWriter(store: store)
    let totalStarted = clock.now
    let traversalStarted = clock.now
    let result = try await scanner.scan(
      scanID: scan.id, rootItemID: 1,
      options: ScanOptions(rootURL: root, intensity: intensity),
      onBatch: { items, _ in try await batchWriter.submit(items) },
      onErrors: { errors in try await store.insert(errors: errors) }
    )
    try await batchWriter.finish()
    let traversalElapsed = traversalStarted.duration(to: clock.now)
    let finalizationStarted = clock.now
    let completed = try await store.finishScan(scan.id, result: result)
    let finalizationElapsed = finalizationStarted.duration(to: clock.now)
    let totalElapsed = totalStarted.duration(to: clock.now)
    let itemCount = result.progress.files + result.progress.directories
    print(
      "Persisted \(itemCount.formatted()) real metadata rows under \(root.path): "
        + "traversal+write \(traversalElapsed), finalization \(finalizationElapsed), "
        + "total \(totalElapsed)"
    )
    if ProcessInfo.processInfo.environment["OPENDISKTREE_BENCHMARK_INCREMENTAL"] == "1" {
      let catalogStarted = clock.now
      let catalog = try await store.makeReuseCatalog(scanID: completed.id)
      let catalogElapsed = catalogStarted.duration(to: clock.now)
      let changedPath = ProcessInfo.processInfo.environment["OPENDISKTREE_BENCHMARK_CHANGED_PATH"]
        ?? root.appendingPathComponent("tmp").path
      let overlay = try await store.beginScan(
        rootURL: root, intensity: intensity, mode: .incremental)
      let overlayRoot = try DiskScanner.makeRootItem(scanID: overlay.id, id: 1, url: root)
      try await store.insert([overlayRoot])
      let startingID = try await store.maximumItemID(scanID: completed.id) + 1
      let overlayWriter = ScanBatchWriter(store: store)
      let traversalStarted = clock.now
      let overlayResult = try await scanner.scan(
        scanID: overlay.id, rootItemID: 1,
        options: ScanOptions(
          rootURL: root, intensity: intensity, mode: .incremental,
          startingItemID: startingID),
        onBatch: { items, _ in try await overlayWriter.submit(items) },
        onErrors: { errors in try await store.insert(errors: errors) },
        reuseCatalog: catalog,
        changedPaths: [changedPath])
      try await overlayWriter.finish()
      let overlayTraversalElapsed = traversalStarted.duration(to: clock.now)
      let mergeStarted = clock.now
      let updated = try await store.finishIncrementalOverlay(
        baseScanID: completed.id, overlayScanID: overlay.id, result: overlayResult)
      let mergeElapsed = mergeStarted.duration(to: clock.now)
      print(
        "Incremental catalog \(catalog.count.formatted()) directories in \(catalogElapsed), "
          + "traversal \(overlayTraversalElapsed), merge \(mergeElapsed), "
          + "reused \(updated.reusedItemCount.formatted()) items"
      )
    }
    return
  }

  let started = clock.now
  let result = try await scanner.scan(
    scanID: 0, rootItemID: 1,
    options: ScanOptions(rootURL: root, intensity: intensity),
    onBatch: { _, _ in },
    onErrors: { _ in }
  )
  let elapsed = started.duration(to: clock.now)
  let itemCount = result.progress.files + result.progress.directories
  print(
    "Traversed \(itemCount.formatted()) real metadata rows under \(root.path) in \(elapsed) "
      + "(bulk directories: \(result.bulkDirectoryCount.formatted()), "
      + "fallback: \(result.fallbackDirectoryCount.formatted()))"
  )
}

@Test(.timeLimit(.minutes(1)))
func scannerMetadataBenchmark() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "OpenDiskTreeBenchmark-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let payload = Data(repeating: 0x41, count: 128)
  for directoryIndex in 0..<20 {
    let directory = root.appendingPathComponent("directory-\(directoryIndex)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for fileIndex in 0..<100 {
      try payload.write(to: directory.appendingPathComponent("file-\(fileIndex).dat"))
    }
  }

  let store = try ScanStore(databaseURL: root.appendingPathComponent("benchmark.sqlite"))
  let scan = try await store.beginScan(rootURL: root, intensity: .turbo)
  let rootItem = try DiskScanner.makeRootItem(scanID: scan.id, id: 1, url: root)
  try await store.insert([rootItem])
  let scanner = DiskScanner()
  let clock = ContinuousClock()
  let elapsed = try await clock.measure {
    let result = try await scanner.scan(
      scanID: scan.id, rootItemID: 1, options: ScanOptions(rootURL: root, intensity: .turbo),
      onBatch: { items, _ in try await store.insert(items) },
      onErrors: { errors in try await store.insert(errors: errors) }
    )
    _ = try await store.finishScan(scan.id, result: result)
  }
  #expect(elapsed < .seconds(10))
  let completed = try await store.fetchScan(scan.id)
  #expect((completed?.itemCount ?? 0) >= 2_021)
}

@Test(.timeLimit(.minutes(10)))
func sqlitePersistenceBenchmark() async throws {
  let requested =
    ProcessInfo.processInfo.environment["OPENDISKTREE_BENCHMARK_ITEMS"]
    .flatMap(Int.init) ?? 20_000
  let itemCount = max(1, min(requested, 2_000_000))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "OpenDiskTreePersistenceBenchmark-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let store = try ScanStore(databaseURL: root.appendingPathComponent("benchmark.sqlite"))
  let scan = try await store.beginScan(rootURL: root, intensity: .balanced)
  let rootItem = try DiskScanner.makeRootItem(scanID: scan.id, id: 1, url: root)
  try await store.insert([rootItem])

  let clock = ContinuousClock()
  let elapsed = try await clock.measure {
    for offset in stride(from: 0, to: itemCount, by: 2_048) {
      let upperBound = min(offset + 2_048, itemCount)
      let batch = (offset..<upperBound).map { index in
        ScannedItem(
          id: Int64(index + 2), scanID: scan.id, parentID: 1,
          path: root.appendingPathComponent("metadata-\(index).dat").path,
          name: "metadata-\(index).dat", depth: 1, kind: .file, fileExtension: "dat",
          ownLogicalBytes: 4_096, ownAllocatedBytes: 4_096, accountedAllocatedBytes: 4_096,
          logicalBytes: 4_096, allocatedBytes: 4_096, createdAt: nil, modifiedAt: nil,
          deviceID: 1, fileID: UInt64(index + 2), linkCount: 1, isHidden: false,
          isPackage: false, classification: .review)
      }
      try await store.insert(batch)
    }
    let progress = ScanProgress(
      files: Int64(itemCount), directories: 1,
      logicalBytes: UInt64(itemCount) * 4_096,
      allocatedBytes: UInt64(itemCount) * 4_096)
    _ = try await store.finishScan(
      scan.id,
      result: ScannerResult(
        progress: progress, cancelled: false, bulkDirectoryCount: 0,
        fallbackDirectoryCount: 0, maximumDepth: 1))
  }

  let completed = try await store.fetchScan(scan.id)
  #expect(completed?.itemCount == Int64(itemCount + 1))
  #expect(completed?.allocatedBytes == UInt64(itemCount) * 4_096)
  let firstPage = try await store.fetchItemsPageAfterID(
    scanID: scan.id, scope: .entireScan, afterID: 0, limit: 100)
  let secondPage = try await store.fetchItemsPageAfterID(
    scanID: scan.id, scope: .entireScan, afterID: firstPage.last?.id ?? 0, limit: 100)
  #expect(firstPage.count == min(100, itemCount + 1))
  #expect(secondPage.first?.id == firstPage.last.map { $0.id + 1 })
  #expect(elapsed < .seconds(itemCount >= 1_000_000 ? 300 : 15))
  print("Persisted \(itemCount.formatted()) metadata rows in \(elapsed)")
}
