import Foundation
import Testing

@testable import OpenDiskTreeCore

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
