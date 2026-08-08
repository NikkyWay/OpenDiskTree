import Foundation
import CSQLite
import Testing

@testable import OpenDiskTreeCore

private struct TestWorkspace {
  let url: URL

  init(name: String = UUID().uuidString) throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenDiskTreeTests-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}

private func write(_ text: String, to url: URL) throws {
  try Data(text.utf8).write(to: url)
}

private func scanFixture(_ root: URL, databaseURL: URL) async throws -> (ScanStore, ScanRecord) {
  let store = try ScanStore(databaseURL: databaseURL)
  let record = try await store.beginScan(rootURL: root, intensity: .balanced)
  let engine = RuleEngine(homePath: root.path)
  let rootItem = try DiskScanner.makeRootItem(scanID: record.id, id: 1, url: root, engine: engine)
  try await store.insert([rootItem])
  let scanner = DiskScanner(ruleEngine: engine)
  let result = try await scanner.scan(
    scanID: record.id,
    rootItemID: 1,
    options: ScanOptions(rootURL: root),
    onBatch: { items, _ in try await store.insert(items) },
    onErrors: { errors in try await store.insert(errors: errors) }
  )
  return (store, try await store.finishScan(record.id, result: result))
}

@Test func nativeReaderHandlesUnicodePackagesAndSymlinks() throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  try write("hello", to: workspace.url.appendingPathComponent("данные.txt"))
  let package = workspace.url.appendingPathComponent("Example.app", isDirectory: true)
  try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: workspace.url.appendingPathComponent("loop"),
    withDestinationURL: workspace.url
  )

  let listing = try FastDirectoryReader.read(path: workspace.url.path)
  #expect(listing.usedBulkAPI)
  #expect(listing.entries.contains { $0.name == "данные.txt" && $0.kind == .file })
  #expect(
    listing.entries.contains { $0.name == "Example.app" && $0.kind == .package && $0.isPackage })
  #expect(listing.entries.contains { $0.name == "loop" && $0.kind == .symbolicLink })
  let dataEntry = try #require(listing.entries.first { $0.name == "данные.txt" })
  #expect(dataEntry.logicalBytes == 5)
  #expect(dataEntry.fileID > 0)
  #expect(dataEntry.deviceID > 0)
  #expect(dataEntry.linkCount >= 1)
}

@Test func fastOverviewListsOnlyTheSelectedDirectory() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  try write("hello", to: workspace.url.appendingPathComponent("visible.txt"))
  let nested = workspace.url.appendingPathComponent("Nested", isDirectory: true)
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  try write("not part of the first pass", to: nested.appendingPathComponent("inside.txt"))

  let result = await FastOverviewScanner.scan(rootURL: workspace.url)
  #expect(result.inaccessibleCount == 0)
  #expect(result.children.contains { $0.name == "visible.txt" && $0.allocatedBytes > 0 })
  #expect(result.children.contains { $0.name == "Nested" && $0.kind == .directory })
  #expect(result.root?.path == workspace.url.path)
}

@Test func fullDiskTraversalDoesNotEnterNestedVolumes() {
  #expect(
    !DiskScanner.shouldTraverseDirectory(
      rootDeviceID: 10, entryDeviceID: 11, isMountPoint: false, crossSelectedVolume: false))
  #expect(
    !DiskScanner.shouldTraverseDirectory(
      rootDeviceID: 10, entryDeviceID: 10, isMountPoint: true, crossSelectedVolume: false))
  #expect(
    DiskScanner.shouldTraverseDirectory(
      rootDeviceID: 10, entryDeviceID: 11, isMountPoint: true, crossSelectedVolume: true))
}

@Test func cancelledSnapshotUsesLiveProgressTotals() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let store = try ScanStore(databaseURL: workspace.url.appendingPathComponent("cancelled.sqlite"))
  let scan = try await store.beginScan(rootURL: workspace.url, intensity: .balanced)
  let root = try DiskScanner.makeRootItem(scanID: scan.id, id: 1, url: workspace.url)
  try await store.insert([root])
  let progress = ScanProgress(
    files: 8, directories: 3, logicalBytes: 12_345, allocatedBytes: 16_384,
    currentPath: workspace.url.path)
  let result = ScannerResult(
    progress: progress, cancelled: true, bulkDirectoryCount: 1, fallbackDirectoryCount: 0,
    maximumDepth: 2)

  let finished = try await store.finishScan(scan.id, result: result)
  #expect(finished.state == .cancelled)
  #expect(finished.itemCount == 11)
  #expect(finished.logicalBytes == 12_345)
  #expect(finished.allocatedBytes == 16_384)
}

@Test func cleanupRulesAreConservativeAndAdvancedOverridesAreExplicit() {
  let override = CleanupRule(
    id: "user.system", title: "Unsafe override", priority: 10_000,
    pattern: "/System", matchKind: .prefix, status: .safeToDelete,
    reason: "Test override", isUserRule: true
  )
  let guarded = RuleEngine(userRules: [override], allowProtectedOverrides: false)
  let advanced = RuleEngine(userRules: [override], allowProtectedOverrides: true)
  #expect(
    guarded.classify(path: "/System/Library/CoreServices", kind: .directory).status == .doNotTouch)
  #expect(
    advanced.classify(path: "/System/Library/CoreServices", kind: .directory).status
      == .safeToDelete)
  #expect(
    RuleEngine().classify(path: "/Users/someone/Documents/report.docx", kind: .file).status
      == .review)
}

@Test func folderAggregationNeverHidesRestrictedChildren() {
  let safe = Classification(
    status: .safeToDelete, ruleID: "safe", reason: "safe", confidence: .high)
  let recreated = Classification(
    status: .recreatedAutomatically, ruleID: "cache", reason: "cache", confidence: .high)
  let protected = Classification(
    status: .doNotTouch, ruleID: "system", reason: "system", confidence: .high,
    isProtectedRule: true)
  #expect(RuleEngine.aggregate([safe, safe]).status == .safeToDelete)
  #expect(RuleEngine.aggregate([safe, recreated]).status == .recreatedAutomatically)
  let mixed = RuleEngine.aggregate([safe, protected])
  #expect(mixed.status == .mixed)
  #expect(mixed.isProtectedRule)
}

@Test func privacyModesDoNotLeakPrivatePrefixes() {
  var basic = PathRedactor(mode: .basic, homePath: "/Users/NikkyWay")
  #expect(
    basic.redact("/Users/NikkyWay/Projects/Secret/file.txt") == "$HOME/Projects/Secret/file.txt")

  var strict = PathRedactor(mode: .strict, homePath: "/Users/NikkyWay")
  let first = strict.redact("/Users/NikkyWay/Projects/Secret/file.txt")
  let second = strict.redact("/Users/NikkyWay/Projects/Secret/other.txt")
  #expect(!first.contains("Projects"))
  #expect(!first.contains("Secret"))
  #expect(first.hasSuffix(".txt"))
  #expect(
    first.split(separator: "/").dropLast().elementsEqual(second.split(separator: "/").dropLast()))
}

@Test func fileActionPolicyProtectsRootsAndManagedData() {
  let classification = Classification(
    status: .deleteViaSourceApp, ruleID: "managed", reason: "Use app", confidence: .high,
    isProtectedRule: true)
  let item = ScannedItem(
    id: 2, scanID: 1, parentID: 1, path: "/tmp/managed", name: "managed", depth: 1,
    kind: .directory, fileExtension: nil, ownLogicalBytes: 0, ownAllocatedBytes: 0,
    accountedAllocatedBytes: 0, logicalBytes: 10, allocatedBytes: 10,
    createdAt: nil, modifiedAt: nil, deviceID: 1, fileID: 2, linkCount: 1,
    isHidden: false, isPackage: false, classification: classification
  )
  #expect(
    FileActionPolicy.trashAuthorization(for: item, strictMode: true)
      == .blocked(reason: "Use the source application to remove this managed data."))
  #expect(
    FileActionPolicy.trashAuthorization(for: item, strictMode: false) == .requiresRiskConfirmation)
}

@Test func scannerPersistsAggregatesAndDoesNotFollowSymlink() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("Private Project", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
  try write(
    String(repeating: "a", count: 4_096), to: root.appendingPathComponent("nested/data.bin"))
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("nested/loop"), withDestinationURL: root)
  let databaseURL = workspace.url.appendingPathComponent("store.sqlite")
  let (store, scan) = try await scanFixture(root, databaseURL: databaseURL)

  #expect(scan.state == .completed)
  #expect(scan.itemCount >= 4)
  #expect(scan.logicalBytes >= 4_096)
  let tree = try await store.fetchDirectoryTree(scanID: scan.id)
  #expect(tree.contains { $0.name == "nested" })
  let children = try await store.fetchChildren(scanID: scan.id, parentID: 1)
  #expect(children.contains { $0.name == "nested" })
}

@Test func incrementalScanReusesUnchangedSubtree() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let stable = workspace.url.appendingPathComponent("stable", isDirectory: true)
  try FileManager.default.createDirectory(
    at: stable.appendingPathComponent("nested"), withIntermediateDirectories: true)
  try write(String(repeating: "stable", count: 400), to: stable.appendingPathComponent("data.bin"))
  let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    "OpenDiskTree-incremental-\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: databaseURL) }
  let (store, first) = try await scanFixture(workspace.url, databaseURL: databaseURL)
  let second = try await store.beginScan(
    rootURL: workspace.url, intensity: .balanced, mode: .incremental)
  let root = try DiskScanner.makeRootItem(scanID: second.id, id: 1, url: workspace.url)
  try await store.insert([root])
  let previousMaximum = try await store.maximumItemID(scanID: first.id)
  let scanner = DiskScanner()
  let result = try await scanner.scan(
    scanID: second.id,
    rootItemID: 1,
    options: ScanOptions(
      rootURL: workspace.url, mode: .incremental, startingItemID: previousMaximum + 1),
    onBatch: { items, _ in try await store.insert(items) },
    onErrors: { errors in try await store.insert(errors: errors) },
    onReuseCandidate: { candidate in
      try await store.reuseSubtree(
        previousScanID: first.id, newScanID: second.id, candidate: candidate, changedPaths: [])
    }
  )
  let finished = try await store.finishScan(second.id, result: result)
  #expect(result.reusedItemCount > 0)
  #expect(finished.mode == .incremental)
  #expect(finished.reusedItemCount == result.reusedItemCount)
  #expect(finished.itemCount == first.itemCount)
  #expect(finished.allocatedBytes == first.allocatedBytes)
}

@Test func duplicateFinderUsesContentNotOnlySize() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("duplicates", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let duplicate = String(repeating: "same-content-", count: 2_000)
  try write(duplicate, to: root.appendingPathComponent("one.dat"))
  try write(duplicate, to: root.appendingPathComponent("two.dat"))
  try write(
    String(repeating: "different----", count: 2_000),
    to: root.appendingPathComponent("different.dat"))
  let (store, scan) = try await scanFixture(
    root, databaseURL: workspace.url.appendingPathComponent("duplicates.sqlite"))

  let result = try await DuplicateFinder().find(scanID: scan.id, store: store, minimumBytes: 1)
  #expect(result.groups.count == 1)
  #expect(result.groups[0].itemIDs.count == 2)
  #expect(!result.groups[0].sha256.isEmpty)

  let exportedSQLite = workspace.url.appendingPathComponent("duplicates-export.sqlite")
  try await ScanExporter(store: store).export(
    scanID: scan.id, to: exportedSQLite, options: ExportOptions(format: .sqlite, privacy: .strict))
  var handle: OpaquePointer?
  #expect(sqlite3_open_v2(exportedSQLite.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
  defer { if let handle { sqlite3_close(handle) } }
  var statement: OpaquePointer?
  #expect(sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM duplicate_groups", -1, &statement, nil) == SQLITE_OK)
  defer { if let statement { sqlite3_finalize(statement) } }
  #expect(sqlite3_step(statement) == SQLITE_ROW)
  #expect(sqlite3_column_int(statement, 0) == 1)
  sqlite3_finalize(statement)
  statement = nil
  #expect(sqlite3_prepare_v2(handle, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK)
  #expect(sqlite3_step(statement) == SQLITE_ROW)
  #expect(String(cString: sqlite3_column_text(statement, 0)) == "ok")
}

@Test func exportsAreReadableAndStrictReportHidesNames() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("Private Project", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try write("private", to: root.appendingPathComponent("Secret Name.txt"))
  let (store, scan) = try await scanFixture(
    root, databaseURL: workspace.url.appendingPathComponent("exports-source.sqlite"))
  let exporter = ScanExporter(store: store)

  let json = workspace.url.appendingPathComponent("scan.json")
  try await exporter.export(
    scanID: scan.id, to: json, options: ExportOptions(format: .json, privacy: .strict))
  let jsonData = try Data(contentsOf: json)
  _ = try JSONSerialization.jsonObject(with: jsonData)
  let jsonText = String(decoding: jsonData, as: UTF8.self)
  #expect(!jsonText.contains("Private Project"))
  #expect(!jsonText.contains("Secret Name"))

  let csv = workspace.url.appendingPathComponent("scan.csv")
  try await exporter.export(
    scanID: scan.id, to: csv, options: ExportOptions(format: .csv, privacy: .basic))
  #expect(String(decoding: try Data(contentsOf: csv), as: UTF8.self).hasPrefix("schema_version,"))

  let sqlite = workspace.url.appendingPathComponent("scan-export.sqlite")
  try await exporter.export(
    scanID: scan.id, to: sqlite, options: ExportOptions(format: .sqlite, privacy: .strict))
  #expect((try sqlite.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)

  let report = workspace.url.appendingPathComponent("ai-report.json")
  try await exporter.export(
    scanID: scan.id, to: report, options: ExportOptions(format: .aiReport, privacy: .strict))
  let reportText = String(decoding: try Data(contentsOf: report), as: UTF8.self)
  #expect(reportText.contains("Never delete important data"))
  #expect(!reportText.contains("Secret Name"))

  let filteredReport = workspace.url.appendingPathComponent("filtered-ai-report.json")
  let filter = ItemFilter(extensions: ["txt"])
  try await exporter.export(
    scanID: scan.id,
    to: filteredReport,
    options: ExportOptions(format: .aiReport, scope: .filtered(filter), privacy: .strict)
  )
  let filteredObject = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: filteredReport)) as? [String: Any])
  #expect(filteredObject["scope"] as? String == "current_filter")
  #expect(filteredObject["scopeItemCount"] as? Int == 1)
}

@Test func protectedDirectoryStatusSurvivesDatabaseAggregation() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("protected", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try write("data", to: root.appendingPathComponent("child.txt"))
  let rule = CleanupRule(
    id: "test.protected", title: "Protected fixture", priority: 10_000,
    pattern: root.path, matchKind: .prefix, status: .doNotTouch,
    reason: "Protected by test", isProtected: true, isUserRule: true
  )
  let engine = RuleEngine(userRules: [rule], allowProtectedOverrides: true)
  let store = try ScanStore(databaseURL: workspace.url.appendingPathComponent("protected.sqlite"))
  let record = try await store.beginScan(rootURL: root, intensity: .balanced)
  try await store.insert([
    DiskScanner.makeRootItem(scanID: record.id, id: 1, url: root, engine: engine)
  ])
  let result = try await DiskScanner(ruleEngine: engine).scan(
    scanID: record.id, rootItemID: 1, options: ScanOptions(rootURL: root),
    onBatch: { items, _ in try await store.insert(items) },
    onErrors: { errors in try await store.insert(errors: errors) }
  )
  _ = try await store.finishScan(record.id, result: result)
  let rootItem = try #require(await store.fetchItem(scanID: record.id, itemID: 1))
  #expect(rootItem.classification.status == .doNotTouch)
  #expect(rootItem.classification.isProtectedRule)
}

@Test func historyAndDuplicateGroupsRemainIndependentBetweenScans() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("history", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let database = workspace.url.appendingPathComponent("history.sqlite")
  let firstPayload = String(repeating: "first", count: 500)
  try write(firstPayload, to: root.appendingPathComponent("one.bin"))
  try write(firstPayload, to: root.appendingPathComponent("two.bin"))
  let (store, first) = try await scanFixture(root, databaseURL: database)
  let firstDuplicates = try await DuplicateFinder().find(scanID: first.id, store: store)
  #expect(firstDuplicates.groups.count == 1)

  let secondPayload = String(repeating: "second", count: 1_000)
  try write(secondPayload, to: root.appendingPathComponent("one.bin"))
  try write(secondPayload, to: root.appendingPathComponent("two.bin"))
  let secondRecord = try await store.beginScan(rootURL: root, intensity: .balanced)
  let rootItem = try DiskScanner.makeRootItem(scanID: secondRecord.id, id: 1, url: root)
  try await store.insert([rootItem])
  let scanner = DiskScanner()
  let result = try await scanner.scan(
    scanID: secondRecord.id, rootItemID: 1, options: ScanOptions(rootURL: root),
    onBatch: { items, _ in try await store.insert(items) },
    onErrors: { errors in try await store.insert(errors: errors) }
  )
  let second = try await store.finishScan(secondRecord.id, result: result)
  let secondDuplicates = try await DuplicateFinder().find(scanID: second.id, store: store)
  #expect(secondDuplicates.groups.count == 1)
  #expect(try await store.duplicateGroups(scanID: first.id).count == 1)
  #expect(try await store.duplicateGroups(scanID: second.id).count == 1)
  #expect(
    try await store.changes(scanID: second.id).contains {
      $0.kind == .grown && $0.path.hasSuffix("one.bin")
    })

  try await store.pruneCompletedHistoryInBackground(rootPath: root.path, keeping: 1)
  #expect(try await store.fetchScan(first.id) == nil)
  #expect(try await store.fetchScan(second.id) != nil)
  #expect(try await store.duplicateGroups(scanID: first.id).isEmpty)
}

@Test func trashedRowsAreRemovedFromStoredTotals() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("cleanup", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try write(String(repeating: "x", count: 8_192), to: root.appendingPathComponent("cache.bin"))
  let (store, scan) = try await scanFixture(
    root, databaseURL: workspace.url.appendingPathComponent("cleanup.sqlite"))
  let file = try #require(
    await store.fetchLargest(scanID: scan.id, containers: false, limit: 1).first)
  try await store.markTrashed(scanID: scan.id, itemIDs: [file.id])
  let updated = try #require(await store.fetchScan(scan.id))
  #expect(updated.logicalBytes == 0)
  #expect(updated.allocatedBytes == 0)
}

@Test func identityCheckDetectsReplacementAfterScan() async throws {
  let workspace = try TestWorkspace()
  defer { workspace.remove() }
  let root = workspace.url.appendingPathComponent("identity", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let fileURL = root.appendingPathComponent("replace-me.txt")
  try write("original", to: fileURL)
  let (store, scan) = try await scanFixture(
    root, databaseURL: workspace.url.appendingPathComponent("identity.sqlite"))
  let item = try #require(
    await store.fetchLargest(scanID: scan.id, containers: false, limit: 1).first)
  #expect(FileActionPolicy.currentIdentityMatches(item))
  try FileManager.default.removeItem(at: fileURL)
  try write("replacement", to: fileURL)
  #expect(!FileActionPolicy.currentIdentityMatches(item))
}
