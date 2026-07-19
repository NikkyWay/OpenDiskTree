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
