import CSQLite
import Foundation

public struct ExportOptions: Sendable {
  public let format: ExportFormat
  public let scope: ExportScope
  public let privacy: PrivacyMode
  public let topFileLimit: Int
  public let topDirectoryLimit: Int
  public let aggregateDepth: Int

  public init(
    format: ExportFormat,
    scope: ExportScope = .entireScan,
    privacy: PrivacyMode = .basic,
    topFileLimit: Int = 500,
    topDirectoryLimit: Int = 200,
    aggregateDepth: Int = 4
  ) {
    self.format = format
    self.scope = scope
    self.privacy = privacy
    self.topFileLimit = max(1, topFileLimit)
    self.topDirectoryLimit = max(1, topDirectoryLimit)
    self.aggregateDepth = max(1, aggregateDepth)
  }
}

public struct ExportProgress: Sendable, Equatable {
  public let exportedItems: Int
  public let bytesWritten: UInt64
}

private struct ExportManifest: Encodable {
  let schemaVersion = 1
  let application = "OpenDiskTree"
  let generatedAt: Date
  let privacyMode: PrivacyMode
  let scope: String
  let containsFileContents = false
  let allocatedSizeCaveat =
    "Hard links are counted once. APFS clone sharing cannot be measured exactly with public APIs."
}

private struct ExportItem: Encodable {
  let id: Int64
  let parentID: Int64?
  let path: String
  let name: String
  let depth: Int
  let kind: ItemKind
  let fileExtension: String?
  let logicalBytes: UInt64
  let allocatedBytes: UInt64
  let createdAt: Date?
  let modifiedAt: Date?
  let linkCount: UInt32
  let isHidden: Bool
  let isPackage: Bool
  let safetyStatus: SafetyStatus
  let ruleID: String?
  let reason: String
  let confidence: RuleConfidence
  let sourceApplication: String?
  let duplicateGroupID: Int64?

  init(_ item: ScannedItem, path: String, includeHashDetails: Bool) {
    id = item.id
    parentID = item.parentID
    self.path = path
    name = URL(fileURLWithPath: path).lastPathComponent
    depth = item.depth
    kind = item.kind
    fileExtension = item.fileExtension
    logicalBytes = item.logicalBytes
    allocatedBytes = item.allocatedBytes
    createdAt = item.createdAt
    modifiedAt = item.modifiedAt
    linkCount = item.linkCount
    isHidden = item.isHidden
    isPackage = item.isPackage
    safetyStatus = item.classification.status
    ruleID = item.classification.ruleID
    reason = item.classification.reason
    confidence = item.classification.confidence
    sourceApplication = item.classification.sourceApplication
    duplicateGroupID = item.duplicateGroupID
  }
}

private struct ExportScan: Encodable {
  let id: Int64
  let rootPath: String
  let volumeName: String
  let volumeUUID: String?
  let startedAt: Date
  let finishedAt: Date?
  let state: ScanState
  let intensity: ScanIntensity
  let itemCount: Int64
  let logicalBytes: UInt64
  let allocatedBytes: UInt64
  let inaccessibleCount: Int64

  init(_ scan: ScanRecord, rootPath: String, privacy: PrivacyMode) {
    id = scan.id
    self.rootPath = rootPath
    volumeName = privacy == .full ? scan.volumeName : "$VOLUME"
    volumeUUID = privacy == .full ? scan.volumeUUID : nil
    startedAt = scan.startedAt
    finishedAt = scan.finishedAt
    state = scan.state
    intensity = scan.intensity
    itemCount = scan.itemCount
    logicalBytes = scan.logicalBytes
    allocatedBytes = scan.allocatedBytes
    inaccessibleCount = scan.inaccessibleCount
  }
}

private struct ExportError: Encodable {
  let path: String
  let code: Int32
  let message: String
}

private struct AIReport: Encodable {
  let manifest: ExportManifest
  let warning: String
  let scan: ExportScan
  let scope: String
  let scopeItemCount: Int
  let scopeLogicalBytes: UInt64
  let scopeAllocatedBytes: UInt64
  let inaccessiblePaths: [String]
  let topFiles: [ExportItem]
  let topDirectories: [ExportItem]
  let statusBytes: [String: UInt64]
  let extensionBytes: [String: UInt64]
  let duplicateGroups: [DuplicateGroup]
  let changes: [ScanChange]
  let configuredAggregateDepth: Int
}

public actor ScanExporter {
  private let store: ScanStore

  public init(store: ScanStore) { self.store = store }

  public func export(
    scanID: Int64,
    to destination: URL,
    options: ExportOptions,
    onProgress: @Sendable (ExportProgress) async -> Void = { _ in }
  ) async throws {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      switch options.format {
      case .json:
        try await exportJSON(
          scanID: scanID, to: temporary, options: options, onProgress: onProgress)
      case .csv:
        try await exportCSV(scanID: scanID, to: temporary, options: options, onProgress: onProgress)
      case .sqlite:
        try await exportSQLite(
          scanID: scanID, to: temporary, options: options, onProgress: onProgress)
      case .aiReport: try await exportAIReport(scanID: scanID, to: temporary, options: options)
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private func exportJSON(
    scanID: Int64,
    to url: URL,
    options: ExportOptions,
    onProgress: @Sendable (ExportProgress) async -> Void
  ) async throws {
    guard let scan = try await store.fetchScan(scanID) else { throw StoreError.missingScan(scanID) }
    let errors = try await store.errors(scanID: scanID)
    let duplicates = try await duplicateGroups(scanID: scanID, scope: options.scope)
    let rules = RuleEngine.builtInRules + (try await store.loadUserRules())
    let encoder = Self.encoder()
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var written: UInt64 = 0
    var redactor = PathRedactor(mode: options.privacy)
    let exportedScan = ExportScan(
      scan, rootPath: redactor.redact(scan.rootPath), privacy: options.privacy)
    let exportedErrors = errors.map { error -> ExportError in
      let path = redactor.redact(error.path)
      return ExportError(
        path: path, code: error.code,
        message: error.message.replacingOccurrences(of: error.path, with: path))
    }
    func write(_ data: Data) throws {
      try handle.write(contentsOf: data)
      written += UInt64(data.count)
    }

    try write(Data("{\"manifest\":".utf8))
    try write(
      encoder.encode(
        ExportManifest(
          generatedAt: Date(), privacyMode: options.privacy, scope: Self.scopeName(options.scope))))
    try write(Data(",\"scan\":".utf8))
    try write(encoder.encode(exportedScan))
    try write(Data(",\"errors\":".utf8))
    try write(encoder.encode(exportedErrors))
    try write(Data(",\"rules\":".utf8))
    try write(encoder.encode(RuleDocument(rules: rules)))
    let safeDuplicates =
      options.privacy == .strict
      ? duplicates.map {
        DuplicateGroup(
          id: $0.id, scanID: $0.scanID, logicalBytes: $0.logicalBytes, sha256: "",
          itemIDs: $0.itemIDs, reclaimableBytes: $0.reclaimableBytes)
      } : duplicates
    try write(Data(",\"duplicateGroups\":".utf8))
    try write(encoder.encode(safeDuplicates))
    try write(Data(",\"items\":[".utf8))
    var offset = 0
    var first = true
    while true {
      let page = try await store.fetchItemsPage(
        scanID: scanID, scope: options.scope, limit: 5_000, offset: offset)
      if page.isEmpty { break }
      for item in page {
        if !first { try write(Data(",".utf8)) }
        first = false
        let exported = ExportItem(
          item, path: redactor.redact(item.path), includeHashDetails: options.privacy != .strict)
        try write(encoder.encode(exported))
      }
      offset += page.count
      await onProgress(ExportProgress(exportedItems: offset, bytesWritten: written))
    }
    try write(Data("]}".utf8))
  }

  private func exportCSV(
    scanID: Int64,
    to url: URL,
    options: ExportOptions,
    onProgress: @Sendable (ExportProgress) async -> Void
  ) async throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let header =
      "schema_version,id,parent_id,path,name,depth,kind,extension,logical_bytes,allocated_bytes,created_at,modified_at,link_count,is_hidden,is_package,safety_status,rule_id,reason,confidence,source_application,duplicate_group_id\n"
    try handle.write(contentsOf: Data(header.utf8))
    var written = UInt64(header.utf8.count)
    var offset = 0
    var redactor = PathRedactor(mode: options.privacy)
    while true {
      let page = try await store.fetchItemsPage(
        scanID: scanID, scope: options.scope, limit: 5_000, offset: offset)
      if page.isEmpty { break }
      var text = ""
      text.reserveCapacity(page.count * 240)
      for item in page {
        let path = redactor.redact(item.path)
        var values: [String] = []
        values.reserveCapacity(21)
        values.append("1")
        values.append(String(item.id))
        values.append(item.parentID.map(String.init) ?? "")
        values.append(path)
        values.append(URL(fileURLWithPath: path).lastPathComponent)
        values.append(String(item.depth))
        values.append(item.kind.rawValue)
        values.append(item.fileExtension ?? "")
        values.append(String(item.logicalBytes))
        values.append(String(item.allocatedBytes))
        values.append(item.createdAt.map(Self.dateString) ?? "")
        values.append(item.modifiedAt.map(Self.dateString) ?? "")
        values.append(String(item.linkCount))
        values.append(item.isHidden ? "true" : "false")
        values.append(item.isPackage ? "true" : "false")
        values.append(item.classification.status.rawValue)
        values.append(item.classification.ruleID ?? "")
        values.append(item.classification.reason)
        values.append(item.classification.confidence.rawValue)
        values.append(item.classification.sourceApplication ?? "")
        values.append(item.duplicateGroupID.map(String.init) ?? "")
        text += values.map(Self.csv).joined(separator: ",") + "\n"
      }
      let data = Data(text.utf8)
      try handle.write(contentsOf: data)
      written += UInt64(data.count)
      offset += page.count
      await onProgress(ExportProgress(exportedItems: offset, bytesWritten: written))
    }
  }

  private func exportSQLite(
    scanID: Int64,
    to url: URL,
    options: ExportOptions,
    onProgress: @Sendable (ExportProgress) async -> Void
  ) async throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
      throw StoreError.open("Unable to create SQLite export.")
    }
    defer { sqlite3_close(handle) }
    let schema = """
      PRAGMA journal_mode=DELETE;
      CREATE TABLE manifest(schema_version INTEGER, generated_at TEXT, privacy_mode TEXT, scope TEXT, contains_file_contents INTEGER);
      CREATE TABLE scan(json TEXT NOT NULL);
      CREATE TABLE items(id INTEGER PRIMARY KEY,parent_id INTEGER,path TEXT,name TEXT,depth INTEGER,kind TEXT,extension TEXT,logical_bytes INTEGER,allocated_bytes INTEGER,created_at TEXT,modified_at TEXT,link_count INTEGER,is_hidden INTEGER,is_package INTEGER,safety_status TEXT,rule_id TEXT,reason TEXT,confidence TEXT,source_application TEXT,duplicate_group_id INTEGER);
      CREATE INDEX items_parent ON items(parent_id);
      CREATE INDEX items_size ON items(allocated_bytes DESC);
      CREATE INDEX items_status ON items(safety_status);
      CREATE TABLE scan_errors(path TEXT,error_code INTEGER,message TEXT);
      CREATE TABLE duplicate_groups(id INTEGER PRIMARY KEY,logical_bytes INTEGER,sha256 TEXT,reclaimable_bytes INTEGER);
      CREATE TABLE duplicate_members(group_id INTEGER,item_id INTEGER,PRIMARY KEY(group_id,item_id));
      """
    guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
      throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
    }
    var redactor = PathRedactor(mode: options.privacy)
    let scan =
      try await store.fetchScan(scanID).map {
        let exported = ExportScan(
          $0, rootPath: redactor.redact($0.rootPath), privacy: options.privacy)
        return String(decoding: try Self.encoder().encode(exported), as: UTF8.self)
      } ?? "{}"
    try Self.sqliteExec(
      handle, "INSERT INTO manifest VALUES(1,?,?,?,0)",
      [
        .text(Self.dateString(Date())), .text(options.privacy.rawValue),
        .text(Self.scopeName(options.scope)),
      ])
    try Self.sqliteExec(handle, "INSERT INTO scan(json) VALUES(?)", [.text(scan)])
    try Self.sqliteExec(handle, "BEGIN", [])
    let itemSQL = "INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    let itemStatement = try Self.sqlitePrepare(handle, itemSQL)
    defer { sqlite3_finalize(itemStatement) }
    var offset = 0
    while true {
      let page = try await store.fetchItemsPage(
        scanID: scanID, scope: options.scope, limit: 5_000, offset: offset)
      if page.isEmpty { break }
      for item in page {
        let path = redactor.redact(item.path)
        try Self.sqliteStep(
          handle, itemStatement, sql: itemSQL,
          values: [
            .integer(item.id), item.parentID.map(SQLiteExportValue.integer) ?? .null, .text(path),
            .text(URL(fileURLWithPath: path).lastPathComponent),
            .integer(Int64(item.depth)), .text(item.kind.rawValue),
            item.fileExtension.map(SQLiteExportValue.text) ?? .null,
            .unsigned(item.logicalBytes), .unsigned(item.allocatedBytes),
            item.createdAt.map { .text(Self.dateString($0)) } ?? .null,
            item.modifiedAt.map { .text(Self.dateString($0)) } ?? .null,
            .integer(Int64(item.linkCount)),
            .integer(item.isHidden ? 1 : 0), .integer(item.isPackage ? 1 : 0),
            .text(item.classification.status.rawValue),
            item.classification.ruleID.map(SQLiteExportValue.text) ?? .null,
            .text(item.classification.reason), .text(item.classification.confidence.rawValue),
            item.classification.sourceApplication.map(SQLiteExportValue.text) ?? .null,
            item.duplicateGroupID.map(SQLiteExportValue.integer) ?? .null,
          ])
      }
      offset += page.count
      await onProgress(ExportProgress(exportedItems: offset, bytesWritten: 0))
    }
    try Self.sqliteExec(handle, "COMMIT", [])
    for error in try await store.errors(scanID: scanID) {
      let path = redactor.redact(error.path)
      try Self.sqliteExec(
        handle, "INSERT INTO scan_errors VALUES(?,?,?)",
        [
          .text(path), .integer(Int64(error.code)),
          .text(error.message.replacingOccurrences(of: error.path, with: path)),
        ])
    }
    for group in try await duplicateGroups(scanID: scanID, scope: options.scope) {
      try Self.sqliteExec(
        handle, "INSERT INTO duplicate_groups VALUES(?,?,?,?)",
        [
          .integer(group.id), .unsigned(group.logicalBytes),
          .text(options.privacy == .strict ? "" : group.sha256), .unsigned(group.reclaimableBytes),
        ])
      for member in group.itemIDs {
        try Self.sqliteExec(
          handle, "INSERT INTO duplicate_members VALUES(?,?)",
          [.integer(group.id), .integer(member)])
      }
    }
  }

  private func exportAIReport(scanID: Int64, to url: URL, options: ExportOptions) async throws {
    guard let scanRecord = try await store.fetchScan(scanID) else {
      throw StoreError.missingScan(scanID)
    }
    var topFiles: [ScannedItem] = []
    var topDirectories: [ScannedItem] = []
    var statusBytes: [SafetyStatus: UInt64] = [:]
    var extensionBytes: [String: UInt64] = [:]
    var scopedDuplicateItems: [Int64: UInt64] = [:]
    var itemCount = 0
    var logicalBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var reportChanges: [ScanChange] = []

    if options.scope == .entireScan {
      let summary = try await store.summary(
        scanID: scanID, topFileLimit: options.topFileLimit,
        topDirectoryLimit: options.topDirectoryLimit)
      topFiles = summary.topFiles
      topDirectories = try await store.fetchLargest(
        scanID: scanID, containers: true, maximumDepth: options.aggregateDepth,
        limit: options.topDirectoryLimit
      )
      statusBytes = summary.statusBytes
      extensionBytes = summary.extensionBytes
      itemCount = Int(summary.scan.itemCount)
      logicalBytes = summary.scan.logicalBytes
      allocatedBytes = summary.scan.allocatedBytes
      reportChanges = summary.changes
      for group in summary.duplicateGroups {
        for id in group.itemIDs { scopedDuplicateItems[id] = group.logicalBytes }
      }
    } else {
      var offset = 0
      while true {
        let page = try await store.fetchItemsPage(
          scanID: scanID, scope: options.scope, limit: 5_000, offset: offset)
        if page.isEmpty { break }
        itemCount += page.count
        for item in page {
          if item.kind.canHaveChildren {
            if item.depth <= options.aggregateDepth { topDirectories.append(item) }
          } else {
            topFiles.append(item)
            logicalBytes &+= item.ownLogicalBytes
            allocatedBytes &+= item.accountedAllocatedBytes
            statusBytes[item.classification.status, default: 0] &+= item.accountedAllocatedBytes
            extensionBytes[item.fileExtension ?? "", default: 0] &+= item.accountedAllocatedBytes
          }
          if item.duplicateGroupID != nil {
            scopedDuplicateItems[item.id] = item.accountedAllocatedBytes
          }
        }
        topFiles.sort { $0.allocatedBytes > $1.allocatedBytes }
        topDirectories.sort { $0.allocatedBytes > $1.allocatedBytes }
        if topFiles.count > options.topFileLimit {
          topFiles.removeLast(topFiles.count - options.topFileLimit)
        }
        if topDirectories.count > options.topDirectoryLimit {
          topDirectories.removeLast(topDirectories.count - options.topDirectoryLimit)
        }
        offset += page.count
      }
    }

    let availableGroups = try await store.duplicateGroups(scanID: scanID)
    let scopedGroups: [DuplicateGroup]
    if options.scope == .entireScan {
      scopedGroups = availableGroups.map {
        DuplicateGroup(
          id: $0.id, scanID: $0.scanID, logicalBytes: $0.logicalBytes,
          sha256: "", itemIDs: $0.itemIDs, reclaimableBytes: $0.reclaimableBytes
        )
      }
    } else {
      scopedGroups = availableGroups.compactMap { group -> DuplicateGroup? in
        let members = group.itemIDs.filter { scopedDuplicateItems[$0] != nil }
        guard members.count > 1 else { return nil }
        let allocated = members.compactMap { scopedDuplicateItems[$0] }
        let reclaimable = allocated.reduce(UInt64(0), &+) - (allocated.max() ?? 0)
        return DuplicateGroup(
          id: group.id, scanID: group.scanID, logicalBytes: group.logicalBytes,
          sha256: "", itemIDs: members, reclaimableBytes: reclaimable
        )
      }
    }
    let errorsRaw = try await store.errors(scanID: scanID)
    var redactor = PathRedactor(mode: options.privacy)
    let scan = ExportScan(
      scanRecord, rootPath: redactor.redact(scanRecord.rootPath), privacy: options.privacy)
    let files = topFiles.map {
      ExportItem($0, path: redactor.redact($0.path), includeHashDetails: false)
    }
    let directories = topDirectories.map {
      ExportItem($0, path: redactor.redact($0.path), includeHashDetails: false)
    }
    let errors = errorsRaw.map { redactor.redact($0.path) }
    let changes = reportChanges.map {
      ScanChange(
        kind: $0.kind, path: redactor.redact($0.path), previousBytes: $0.previousBytes,
        currentBytes: $0.currentBytes)
    }
    let scopeName = Self.scopeName(options.scope)
    let report = AIReport(
      manifest: ExportManifest(generatedAt: Date(), privacyMode: options.privacy, scope: scopeName),
      warning:
        "Safety labels are conservative hints, not guarantees. Never delete important data solely because an automated analysis recommends it.",
      scan: scan, scope: scopeName, scopeItemCount: itemCount,
      scopeLogicalBytes: logicalBytes, scopeAllocatedBytes: allocatedBytes,
      inaccessiblePaths: errors, topFiles: files, topDirectories: directories,
      statusBytes: Dictionary(
        uniqueKeysWithValues: statusBytes.map { ($0.key.rawValue, $0.value) }),
      extensionBytes: extensionBytes, duplicateGroups: scopedGroups, changes: changes,
      configuredAggregateDepth: options.aggregateDepth
    )
    try Self.encoder().encode(report).write(to: url, options: .atomic)
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func csv(_ value: String) -> String {
    guard
      value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
    else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func dateString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func scopeName(_ scope: ExportScope) -> String {
    switch scope {
    case .entireScan: "entire_scan"
    case .filtered: "current_filter"
    case .selection: "selection"
    }
  }

  private func duplicateGroups(scanID: Int64, scope: ExportScope) async throws -> [DuplicateGroup] {
    let allGroups = try await store.duplicateGroups(scanID: scanID)
    guard scope != .entireScan else { return allGroups }
    var memberSizes: [Int64: UInt64] = [:]
    var offset = 0
    while true {
      let page = try await store.fetchItemsPage(
        scanID: scanID, scope: scope, limit: 5_000, offset: offset)
      if page.isEmpty { break }
      for item in page where item.duplicateGroupID != nil {
        memberSizes[item.id] = item.accountedAllocatedBytes
      }
      offset += page.count
    }
    return allGroups.compactMap { group in
      let members = group.itemIDs.filter { memberSizes[$0] != nil }
      guard members.count > 1 else { return nil }
      let sizes = members.compactMap { memberSizes[$0] }
      return DuplicateGroup(
        id: group.id, scanID: group.scanID, logicalBytes: group.logicalBytes,
        sha256: group.sha256, itemIDs: members,
        reclaimableBytes: sizes.reduce(UInt64(0), &+) - (sizes.max() ?? 0)
      )
    }
  }
}

private enum SQLiteExportValue {
  case integer(Int64)
  case unsigned(UInt64)
  case text(String)
  case null
}

extension ScanExporter {
  fileprivate static func sqlitePrepare(_ handle: OpaquePointer, _ sql: String) throws
    -> OpaquePointer
  {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
    }
    return statement
  }

  fileprivate static func sqliteStep(
    _ handle: OpaquePointer, _ statement: OpaquePointer, sql: String, values: [SQLiteExportValue]
  ) throws {
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .integer(let number): _ = sqlite3_bind_int64(statement, index, number)
      case .unsigned(let number):
        _ = sqlite3_bind_int64(
          statement, index, number > UInt64(Int64.max) ? Int64.max : Int64(number))
      case .text(let text):
        _ = text.withCString {
          sqlite3_bind_text(
            statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      case .null: _ = sqlite3_bind_null(statement, index)
      }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw StoreError.sqlite(
        code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
  }

  fileprivate static func sqliteExec(
    _ handle: OpaquePointer, _ sql: String, _ values: [SQLiteExportValue]
  ) throws {
    let statement = try sqlitePrepare(handle, sql)
    defer { sqlite3_finalize(statement) }
    try sqliteStep(handle, statement, sql: sql, values: values)
  }
}
