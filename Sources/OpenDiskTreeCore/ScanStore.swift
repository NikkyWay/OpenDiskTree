import CSQLite
import Foundation

public enum StoreError: LocalizedError, Sendable {
  case open(String)
  case sqlite(code: Int32, message: String, sql: String)
  case missingScan(Int64)

  public var errorDescription: String? {
    switch self {
    case .open(let message): message
    case .sqlite(_, let message, let sql): "SQLite error: \(message) [\(sql)]"
    case .missingScan(let id): "Scan \(id) does not exist."
    }
  }
}

private enum SQLValue {
  case integer(Int64)
  case unsigned(UInt64)
  case text(String)
  case null
}

private final class SQLiteConnection {
  let handle: OpaquePointer

  init(url: URL) throws {
    var pointer: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
      let message =
        pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
      if let pointer { sqlite3_close(pointer) }
      throw StoreError.open(message)
    }
    handle = pointer
  }

  deinit { sqlite3_close(handle) }

  func execute(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &message)
    if result != SQLITE_OK {
      let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(message)
      throw StoreError.sqlite(code: result, message: text, sql: sql)
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw StoreError.sqlite(
        code: result, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
    return statement
  }

  func bind(_ values: [SQLValue], to statement: OpaquePointer, sql: String) throws {
    sqlite3_clear_bindings(statement)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
      case .unsigned(let number):
        result = sqlite3_bind_int64(statement, index, Int64(clamping: number))
      case .text(let text):
        result = text.withCString {
          sqlite3_bind_text(
            statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      case .null: result = sqlite3_bind_null(statement, index)
      }
      if result != SQLITE_OK {
        throw StoreError.sqlite(
          code: result, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
      }
    }
  }

  func stepDone(_ statement: OpaquePointer, sql: String) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      throw StoreError.sqlite(
        code: result, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
    sqlite3_reset(statement)
  }
}

private final class ISO8601FormatterBox: @unchecked Sendable {
  let value = ISO8601DateFormatter()
}

public actor ScanStore {
  // Formatter construction asks ICU to build a locale/time-zone model. Creating it for
  // every timestamp made metadata insertion disproportionately expensive on large scans.
  // ScanStore is an actor, so this formatter is only accessed serially.
  private static let iso8601Formatter = ISO8601FormatterBox()

  public nonisolated let databaseURL: URL
  private let database: SQLiteConnection

  public init(databaseURL: URL? = nil) throws {
    if let databaseURL {
      self.databaseURL = databaseURL
    } else {
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      let directory = applicationSupport.appendingPathComponent("OpenDiskTree", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      self.databaseURL = directory.appendingPathComponent("OpenDiskTree.sqlite")
    }
    database = try SQLiteConnection(url: self.databaseURL)
    try Self.migrate(database)
  }

  public func beginScan(rootURL: URL, intensity: ScanIntensity) throws -> ScanRecord {
    // These indexes are only needed for filtering and duplicate queries after a scan.
    // Maintaining them for every discovered file multiplies random SQLite writes.
    try database.execute("DROP INDEX IF EXISTS items_path")
    try database.execute("DROP INDEX IF EXISTS items_status")
    try database.execute("DROP INDEX IF EXISTS items_duplicate_candidates")
    try database.execute("DROP INDEX IF EXISTS items_scan_depth")
    let values = try rootURL.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey])
    let volumeName = values.volumeName ?? rootURL.lastPathComponent
    let now = Date()
    let sql = """
      INSERT INTO scans(root_path, volume_name, volume_uuid, started_at, state, intensity)
      VALUES(?, ?, ?, ?, ?, ?)
      """
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(
      [
        .text(rootURL.path), .text(volumeName), values.volumeUUIDString.map(SQLValue.text) ?? .null,
        .text(Self.dateString(now)), .text(ScanState.running.rawValue), .text(intensity.rawValue),
      ], to: statement, sql: sql)
    try database.stepDone(statement, sql: sql)
    let id = sqlite3_last_insert_rowid(database.handle)
    return ScanRecord(
      id: id, rootPath: rootURL.path, volumeName: volumeName, volumeUUID: values.volumeUUIDString,
      startedAt: now, finishedAt: nil, state: .running, intensity: intensity,
      itemCount: 0, logicalBytes: 0, allocatedBytes: 0, inaccessibleCount: 0
    )
  }

  public func insert(_ items: [ScannedItem]) throws {
    guard !items.isEmpty else { return }
    let sql = """
      INSERT INTO items(
        id, scan_id, parent_id, path, name, depth, kind, extension,
        own_logical_bytes, own_allocated_bytes, accounted_allocated_bytes, logical_bytes, allocated_bytes,
        created_at, modified_at, device_id, file_id, link_count, is_hidden, is_package,
        safety_status, rule_id, reason, confidence, source_application, is_protected_rule,
        duplicate_group_id, is_deleted
      ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.execute("BEGIN IMMEDIATE")
    do {
      for item in items {
        try database.bind(
          [
            .integer(item.id), .integer(item.scanID), item.parentID.map(SQLValue.integer) ?? .null,
            .text(item.path), .text(item.name), .integer(Int64(item.depth)),
            .text(item.kind.rawValue),
            item.fileExtension.map(SQLValue.text) ?? .null,
            .unsigned(item.ownLogicalBytes), .unsigned(item.ownAllocatedBytes),
            .unsigned(item.accountedAllocatedBytes),
            .unsigned(item.logicalBytes), .unsigned(item.allocatedBytes),
            item.createdAt.map { .text(Self.dateString($0)) } ?? .null,
            item.modifiedAt.map { .text(Self.dateString($0)) } ?? .null,
            .unsigned(item.deviceID), .unsigned(item.fileID), .integer(Int64(item.linkCount)),
            .integer(item.isHidden ? 1 : 0), .integer(item.isPackage ? 1 : 0),
            .text(item.classification.status.rawValue),
            item.classification.ruleID.map(SQLValue.text) ?? .null,
            .text(item.classification.reason), .text(item.classification.confidence.rawValue),
            item.classification.sourceApplication.map(SQLValue.text) ?? .null,
            .integer(item.classification.isProtectedRule ? 1 : 0),
            item.duplicateGroupID.map(SQLValue.integer) ?? .null, .integer(item.isDeleted ? 1 : 0),
          ], to: statement, sql: sql)
        try database.stepDone(statement, sql: sql)
      }
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
  }

  public func insert(errors: [ScanErrorRecord]) throws {
    guard !errors.isEmpty else { return }
    let sql = "INSERT INTO scan_errors(scan_id, path, error_code, message) VALUES(?,?,?,?)"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.execute("BEGIN IMMEDIATE")
    do {
      for error in errors {
        try database.bind(
          [
            .integer(error.scanID), .text(error.path), .integer(Int64(error.code)),
            .text(error.message),
          ], to: statement, sql: sql)
        try database.stepDone(statement, sql: sql)
      }
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
  }

  public func finishScan(_ scanID: Int64, result: ScannerResult, rootItemID: Int64 = 1) throws
    -> ScanRecord
  {
    if !result.cancelled {
      try aggregateDirectories(scanID: scanID, maximumDepth: result.maximumDepth)
    }
    try rebuildDeferredIndexes()
    let state: ScanState = result.cancelled ? .cancelled : .completed
    let finished = Date()
    let root = try fetchItem(scanID: scanID, itemID: rootItemID)
    let logicalBytes =
      result.cancelled
      ? result.progress.logicalBytes : (root?.logicalBytes ?? result.progress.logicalBytes)
    let allocatedBytes =
      result.cancelled
      ? result.progress.allocatedBytes : (root?.allocatedBytes ?? result.progress.allocatedBytes)
    let sql = """
      UPDATE scans SET finished_at=?, state=?, item_count=?, logical_bytes=?, allocated_bytes=?, inaccessible_count=?
      WHERE id=?
      """
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(
      [
        .text(Self.dateString(finished)), .text(state.rawValue),
        .integer(result.progress.files + result.progress.directories),
        .unsigned(logicalBytes),
        .unsigned(allocatedBytes),
        .integer(result.progress.inaccessible), .integer(scanID),
      ], to: statement, sql: sql)
    try database.stepDone(statement, sql: sql)
    guard let scan = try fetchScan(scanID) else { throw StoreError.missingScan(scanID) }
    if state == .completed { try pruneCompletedHistory(rootPath: scan.rootPath, keeping: 2) }
    return scan
  }

  public func failScan(_ scanID: Int64, message: String) throws {
    let sql = "UPDATE scans SET finished_at=?, state=? WHERE id=?"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(
      [.text(Self.dateString(Date())), .text(ScanState.failed.rawValue), .integer(scanID)],
      to: statement, sql: sql)
    try database.stepDone(statement, sql: sql)
    try insert(errors: [ScanErrorRecord(scanID: scanID, path: "", code: EIO, message: message)])
    try? rebuildDeferredIndexes()
  }

  private func rebuildDeferredIndexes() throws {
    try database.execute("CREATE INDEX IF NOT EXISTS items_path ON items(scan_id,path)")
    try database.execute("CREATE INDEX IF NOT EXISTS items_status ON items(scan_id,safety_status)")
    try database.execute(
      "CREATE INDEX IF NOT EXISTS items_duplicate_candidates ON items(scan_id,logical_bytes) WHERE kind='file'")
  }

  public func fetchScan(_ id: Int64) throws -> ScanRecord? {
    try queryScans(whereClause: "WHERE id=?", values: [.integer(id)], limit: 1).first
  }

  public func recentScans(limit: Int = 30) throws -> [ScanRecord] {
    try queryScans(whereClause: "ORDER BY started_at DESC", values: [], limit: limit)
  }

  public func deleteScan(_ scanID: Int64) throws {
    try executeBound("DELETE FROM scans WHERE id=?", [.integer(scanID)])
    try executeBound("DELETE FROM cleanup_actions WHERE scan_id=?", [.integer(scanID)])
  }

  public func fetchItem(scanID: Int64, itemID: Int64) throws -> ScannedItem? {
    let sql = Self.itemSelect + " WHERE scan_id=? AND id=? LIMIT 1"
    return try queryItems(sql: sql, values: [.integer(scanID), .integer(itemID)]).first
  }

  public func fetchChildren(
    scanID: Int64,
    parentID: Int64?,
    filter: ItemFilter = .empty,
    sort: ItemSort = .allocatedSize,
    ascending: Bool = false,
    limit: Int = 2_000,
    offset: Int = 0
  ) throws -> [ScannedItem] {
    var clauses = ["scan_id=?", "is_deleted=0"]
    var values: [SQLValue] = [.integer(scanID)]
    if let parentID {
      clauses.append("parent_id=?")
      values.append(.integer(parentID))
    } else {
      clauses.append("parent_id IS NULL")
    }
    append(filter: filter, clauses: &clauses, values: &values)
    values.append(.integer(Int64(limit)))
    values.append(.integer(Int64(offset)))
    let direction = ascending ? "ASC" : "DESC"
    let order =
      switch sort {
      case .allocatedSize: "allocated_bytes"
      case .logicalSize: "logical_bytes"
      case .name: "name COLLATE NOCASE"
      case .modified: "modified_at"
      case .status: "safety_status"
      }
    let sql =
      Self.itemSelect
      + " WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order) \(direction), id ASC LIMIT ? OFFSET ?"
    return try queryItems(sql: sql, values: values)
  }

  public func fetchLargest(
    scanID: Int64,
    containers: Bool? = nil,
    filter: ItemFilter = .empty,
    sort: ItemSort = .allocatedSize,
    maximumDepth: Int? = nil,
    limit: Int = 2_000,
    offset: Int = 0
  ) throws -> [ScannedItem] {
    var clauses = ["scan_id=?", "is_deleted=0"]
    var values: [SQLValue] = [.integer(scanID)]
    if let containers {
      clauses.append(
        containers ? "kind IN ('directory','package')" : "kind NOT IN ('directory','package')")
    }
    if let maximumDepth {
      clauses.append("depth<=?")
      values.append(.integer(Int64(maximumDepth)))
    }
    append(filter: filter, clauses: &clauses, values: &values)
    values += [.integer(Int64(limit)), .integer(Int64(offset))]
    let order = sort == .logicalSize ? "logical_bytes" : "allocated_bytes"
    let sql =
      Self.itemSelect
      + " WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order) DESC, id ASC LIMIT ? OFFSET ?"
    return try queryItems(sql: sql, values: values)
  }

  public func fetchDirectoryTree(scanID: Int64, limit: Int = 20_000) throws -> [ScannedItem] {
    let sql =
      Self.itemSelect
      + " WHERE scan_id=? AND is_deleted=0 AND kind IN ('directory','package') ORDER BY id ASC LIMIT ?"
    return try queryItems(sql: sql, values: [.integer(scanID), .integer(Int64(limit))])
  }

  public func fetchItemsPage(
    scanID: Int64, filter: ItemFilter = .empty, limit: Int = 5_000, offset: Int = 0
  ) throws -> [ScannedItem] {
    var clauses = ["scan_id=?", "is_deleted=0"]
    var values: [SQLValue] = [.integer(scanID)]
    append(filter: filter, clauses: &clauses, values: &values)
    values += [.integer(Int64(limit)), .integer(Int64(offset))]
    let sql =
      Self.itemSelect
      + " WHERE \(clauses.joined(separator: " AND ")) ORDER BY id ASC LIMIT ? OFFSET ?"
    return try queryItems(sql: sql, values: values)
  }

  public func fetchItemsPage(scanID: Int64, scope: ExportScope, limit: Int = 5_000, offset: Int = 0)
    throws -> [ScannedItem]
  {
    switch scope {
    case .entireScan:
      return try fetchItemsPage(scanID: scanID, limit: limit, offset: offset)
    case .filtered(let filter):
      return try fetchItemsPage(scanID: scanID, filter: filter, limit: limit, offset: offset)
    case .selection(let itemIDs, let includeDescendants):
      guard !itemIDs.isEmpty else { return [] }
      var clauses = ["scan_id=?", "is_deleted=0"]
      var values: [SQLValue] = [.integer(scanID)]
      let uniqueIDs = Array(Set(itemIDs)).sorted()
      if includeDescendants {
        let selected = try uniqueIDs.compactMap { try fetchItem(scanID: scanID, itemID: $0) }
        let pathClauses = selected.map { _ in "(id=? OR path LIKE ? ESCAPE '\\')" }
        clauses.append("(" + pathClauses.joined(separator: " OR ") + ")")
        for item in selected {
          values.append(.integer(item.id))
          let escaped = item.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "%", with: "\\%"
          ).replacingOccurrences(of: "_", with: "\\_")
          values.append(.text(escaped + "/%"))
        }
      } else {
        clauses.append(
          "id IN (\(Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")))")
        values += uniqueIDs.map(SQLValue.integer)
      }
      values += [.integer(Int64(limit)), .integer(Int64(offset))]
      let sql =
        Self.itemSelect
        + " WHERE \(clauses.joined(separator: " AND ")) ORDER BY id ASC LIMIT ? OFFSET ?"
      return try queryItems(sql: sql, values: values)
    }
  }

  public func summary(scanID: Int64, topFileLimit: Int = 500, topDirectoryLimit: Int = 200) throws
    -> StoreSummary
  {
    guard let scan = try fetchScan(scanID) else { throw StoreError.missingScan(scanID) }
    return StoreSummary(
      scan: scan,
      topFiles: try fetchLargest(scanID: scanID, containers: false, limit: topFileLimit),
      topDirectories: try fetchLargest(scanID: scanID, containers: true, limit: topDirectoryLimit),
      statusBytes: try statusBreakdown(scanID: scanID),
      extensionBytes: try extensionBreakdown(scanID: scanID),
      duplicateGroups: try duplicateGroups(scanID: scanID),
      errors: try errors(scanID: scanID),
      changes: try changes(scanID: scanID)
    )
  }

  public func recordCleanupAction(
    scanID: Int64, item: ScannedItem, outcome: String, message: String?
  ) throws {
    try executeBound(
      "INSERT INTO cleanup_actions(scan_id,item_id,original_path,status,performed_at,outcome,message) VALUES(?,?,?,?,?,?,?)",
      [
        .integer(scanID), .integer(item.id), .text(item.path),
        .text(item.classification.status.rawValue),
        .text(Self.dateString(Date())), .text(outcome), message.map(SQLValue.text) ?? .null,
      ]
    )
  }

  public func errors(scanID: Int64) throws -> [ScanErrorRecord] {
    let sql =
      "SELECT scan_id, path, error_code, message FROM scan_errors WHERE scan_id=? ORDER BY id"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind([.integer(scanID)], to: statement, sql: sql)
    var result: [ScanErrorRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(
        ScanErrorRecord(
          scanID: sqlite3_column_int64(statement, 0),
          path: Self.text(statement, 1) ?? "",
          code: sqlite3_column_int(statement, 2),
          message: Self.text(statement, 3) ?? ""
        ))
    }
    return result
  }

  public func statusBreakdown(scanID: Int64) throws -> [SafetyStatus: UInt64] {
    let sql =
      "SELECT safety_status, COALESCE(SUM(accounted_allocated_bytes),0) FROM items WHERE scan_id=? AND is_deleted=0 AND kind NOT IN ('directory','package') GROUP BY safety_status"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind([.integer(scanID)], to: statement, sql: sql)
    var values: [SafetyStatus: UInt64] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      if let raw = Self.text(statement, 0), let status = SafetyStatus(rawValue: raw) {
        values[status] = UInt64(max(0, sqlite3_column_int64(statement, 1)))
      }
    }
    return values
  }

  public func extensionBreakdown(scanID: Int64, limit: Int = 100) throws -> [String: UInt64] {
    let sql =
      "SELECT COALESCE(extension,''), COALESCE(SUM(accounted_allocated_bytes),0) AS bytes FROM items WHERE scan_id=? AND is_deleted=0 AND kind='file' GROUP BY extension ORDER BY bytes DESC LIMIT ?"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind([.integer(scanID), .integer(Int64(limit))], to: statement, sql: sql)
    var values: [String: UInt64] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      values[Self.text(statement, 0) ?? ""] = UInt64(max(0, sqlite3_column_int64(statement, 1)))
    }
    return values
  }

  public func duplicateCandidates(scanID: Int64, minimumBytes: UInt64 = 1) throws -> [[ScannedItem]]
  {
    let sizesSQL =
      "SELECT logical_bytes FROM items WHERE scan_id=? AND kind='file' AND is_deleted=0 AND logical_bytes>=? GROUP BY logical_bytes HAVING COUNT(*)>1 ORDER BY logical_bytes DESC"
    let statement = try database.prepare(sizesSQL)
    defer { sqlite3_finalize(statement) }
    try database.bind([.integer(scanID), .unsigned(minimumBytes)], to: statement, sql: sizesSQL)
    var sizes: [UInt64] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      sizes.append(UInt64(max(0, sqlite3_column_int64(statement, 0))))
    }
    var groups: [[ScannedItem]] = []
    for size in sizes {
      let sql =
        Self.itemSelect
        + " WHERE scan_id=? AND kind='file' AND is_deleted=0 AND logical_bytes=? ORDER BY id"
      groups.append(try queryItems(sql: sql, values: [.integer(scanID), .unsigned(size)]))
    }
    return groups
  }

  public func replaceDuplicateGroups(scanID: Int64, groups: [DuplicateGroup]) throws {
    try database.execute("BEGIN IMMEDIATE")
    do {
      try executeBound("DELETE FROM duplicate_members WHERE scan_id=?", [.integer(scanID)])
      try executeBound("DELETE FROM duplicate_groups WHERE scan_id=?", [.integer(scanID)])
      try executeBound(
        "UPDATE items SET duplicate_group_id=NULL WHERE scan_id=?", [.integer(scanID)])
      for group in groups {
        try executeBound(
          "INSERT INTO duplicate_groups(id, scan_id, logical_bytes, sha256, reclaimable_bytes) VALUES(?,?,?,?,?)",
          [
            .integer(group.id), .integer(scanID), .unsigned(group.logicalBytes),
            .text(group.sha256), .unsigned(group.reclaimableBytes),
          ]
        )
        for itemID in group.itemIDs {
          try executeBound(
            "INSERT INTO duplicate_members(group_id, scan_id, item_id) VALUES(?,?,?)",
            [.integer(group.id), .integer(scanID), .integer(itemID)])
          try executeBound(
            "UPDATE items SET duplicate_group_id=? WHERE scan_id=? AND id=?",
            [.integer(group.id), .integer(scanID), .integer(itemID)])
        }
      }
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
  }

  public func duplicateGroups(scanID: Int64, limit: Int = 500) throws -> [DuplicateGroup] {
    let sql =
      "SELECT id, logical_bytes, sha256, reclaimable_bytes FROM duplicate_groups WHERE scan_id=? ORDER BY reclaimable_bytes DESC LIMIT ?"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind([.integer(scanID), .integer(Int64(limit))], to: statement, sql: sql)
    var groups: [DuplicateGroup] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = sqlite3_column_int64(statement, 0)
      let memberSQL =
        "SELECT item_id FROM duplicate_members WHERE scan_id=? AND group_id=? ORDER BY item_id"
      let memberStatement = try database.prepare(memberSQL)
      try database.bind([.integer(scanID), .integer(id)], to: memberStatement, sql: memberSQL)
      var members: [Int64] = []
      while sqlite3_step(memberStatement) == SQLITE_ROW {
        members.append(sqlite3_column_int64(memberStatement, 0))
      }
      sqlite3_finalize(memberStatement)
      groups.append(
        DuplicateGroup(
          id: id, scanID: scanID,
          logicalBytes: UInt64(max(0, sqlite3_column_int64(statement, 1))),
          sha256: Self.text(statement, 2) ?? "",
          itemIDs: members,
          reclaimableBytes: UInt64(max(0, sqlite3_column_int64(statement, 3)))
        ))
    }
    return groups
  }

  public func changes(scanID: Int64, limit: Int = 1_000) throws -> [ScanChange] {
    guard let current = try fetchScan(scanID),
      let previous = try queryScans(
        whereClause: "WHERE root_path=? AND state='completed' AND id<? ORDER BY id DESC",
        values: [.text(current.rootPath), .integer(scanID)], limit: 1
      ).first
    else { return [] }

    var changes: [ScanChange] = []
    let addedSQL =
      "SELECT c.path, c.allocated_bytes FROM items c LEFT JOIN items p ON p.scan_id=? AND p.path=c.path WHERE c.scan_id=? AND c.is_deleted=0 AND p.id IS NULL ORDER BY c.allocated_bytes DESC LIMIT ?"
    changes += try queryChanges(
      sql: addedSQL, values: [.integer(previous.id), .integer(scanID), .integer(Int64(limit))],
      kind: .added)
    let removedSQL =
      "SELECT p.path, p.allocated_bytes FROM items p LEFT JOIN items c ON c.scan_id=? AND c.path=p.path WHERE p.scan_id=? AND p.is_deleted=0 AND c.id IS NULL ORDER BY p.allocated_bytes DESC LIMIT ?"
    changes += try queryChanges(
      sql: removedSQL, values: [.integer(scanID), .integer(previous.id), .integer(Int64(limit))],
      kind: .removed)

    let modifiedSQL = """
      SELECT c.path, p.allocated_bytes, c.allocated_bytes
      FROM items c JOIN items p ON p.scan_id=? AND p.path=c.path
      WHERE c.scan_id=? AND c.is_deleted=0 AND p.is_deleted=0 AND c.allocated_bytes<>p.allocated_bytes
      ORDER BY ABS(c.allocated_bytes-p.allocated_bytes) DESC LIMIT ?
      """
    let statement = try database.prepare(modifiedSQL)
    defer { sqlite3_finalize(statement) }
    try database.bind(
      [.integer(previous.id), .integer(scanID), .integer(Int64(limit))], to: statement,
      sql: modifiedSQL)
    while sqlite3_step(statement) == SQLITE_ROW {
      let previousBytes = UInt64(max(0, sqlite3_column_int64(statement, 1)))
      let currentBytes = UInt64(max(0, sqlite3_column_int64(statement, 2)))
      changes.append(
        ScanChange(
          kind: currentBytes > previousBytes ? .grown : .changed,
          path: Self.text(statement, 0) ?? "", previousBytes: previousBytes,
          currentBytes: currentBytes
        ))
    }
    return Array(
      changes.sorted {
        abs(Int64(clamping: ($0.currentBytes ?? 0)) - Int64(clamping: ($0.previousBytes ?? 0)))
          > abs(Int64(clamping: ($1.currentBytes ?? 0)) - Int64(clamping: ($1.previousBytes ?? 0)))
      }.prefix(limit))
  }

  public func markTrashed(scanID: Int64, itemIDs: [Int64]) throws {
    guard !itemIDs.isEmpty else { return }
    try database.execute("BEGIN IMMEDIATE")
    do {
      for id in itemIDs {
        try executeBound(
          """
          WITH RECURSIVE descendants(id) AS (
            SELECT ?
            UNION ALL
            SELECT child.id FROM items child JOIN descendants parent ON child.parent_id=parent.id WHERE child.scan_id=?
          )
          UPDATE items SET is_deleted=1 WHERE scan_id=? AND id IN (SELECT id FROM descendants)
          """, [.integer(id), .integer(scanID), .integer(scanID)])
      }
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
    let maximumDepth = try scalarInt(
      "SELECT COALESCE(MAX(depth),0) FROM items WHERE scan_id=?", [.integer(scanID)])
    try aggregateDirectories(scanID: scanID, maximumDepth: Int(maximumDepth))
    try executeBound(
      """
      UPDATE scans SET
        item_count=(SELECT COUNT(*) FROM items WHERE scan_id=? AND is_deleted=0),
        logical_bytes=COALESCE((SELECT logical_bytes FROM items WHERE scan_id=? AND parent_id IS NULL),0),
        allocated_bytes=COALESCE((SELECT allocated_bytes FROM items WHERE scan_id=? AND parent_id IS NULL),0)
      WHERE id=?
      """, [.integer(scanID), .integer(scanID), .integer(scanID), .integer(scanID)])
  }

  public func loadUserRules() throws -> [CleanupRule] {
    let sql = "SELECT json FROM user_rules ORDER BY id"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    let decoder = JSONDecoder()
    var rules: [CleanupRule] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let string = Self.text(statement, 0), let data = string.data(using: .utf8),
        let rule = try? decoder.decode(CleanupRule.self, from: data)
      {
        rules.append(rule)
      }
    }
    return rules
  }

  public func saveUserRules(_ rules: [CleanupRule]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try database.execute("BEGIN IMMEDIATE")
    do {
      try database.execute("DELETE FROM user_rules")
      for rule in rules {
        let text = String(decoding: try encoder.encode(rule), as: UTF8.self)
        try executeBound(
          "INSERT INTO user_rules(id, json, updated_at) VALUES(?,?,?)",
          [.text(rule.id), .text(text), .text(Self.dateString(Date()))])
      }
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
  }

  public func compact() throws { try database.execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;") }

  private func aggregateDirectories(scanID: Int64, maximumDepth: Int) throws {
    // A depth predicate is used once per level during the bottom-up rollup. Without this
    // index SQLite scans the complete items table for every depth, which becomes minutes
    // of work on a million-row snapshot.
    try database.execute("CREATE INDEX IF NOT EXISTS items_scan_depth ON items(scan_id,depth)")
    try database.execute(
      """
      CREATE TEMP TABLE IF NOT EXISTS odt_folder_rollups(
        parent_id INTEGER PRIMARY KEY,
        logical_bytes INTEGER NOT NULL,
        allocated_bytes INTEGER NOT NULL,
        risk_rank INTEGER NOT NULL,
        non_review INTEGER NOT NULL,
        child_count INTEGER NOT NULL,
        protected_rule INTEGER NOT NULL
      )
      """
    )
    try database.execute("BEGIN IMMEDIATE")
    do {
      for depth in stride(from: maximumDepth, through: 0, by: -1) {
        try database.execute("DELETE FROM odt_folder_rollups")
        try executeBound(
          """
          INSERT INTO odt_folder_rollups(
            parent_id, logical_bytes, allocated_bytes, risk_rank, non_review, child_count, protected_rule
          )
          SELECT parent.id,
            COALESCE(SUM(child.logical_bytes),0),
            COALESCE(SUM(child.allocated_bytes),0),
            COALESCE(MAX(CASE child.safety_status
              WHEN 'do_not_touch' THEN 5
              WHEN 'delete_via_source_app' THEN 4
              WHEN 'mixed' THEN 3
              WHEN 'review' THEN 2
              WHEN 'recreated_automatically' THEN 1
              ELSE 0 END),0),
            COALESCE(SUM(CASE WHEN child.id IS NULL OR child.safety_status='review' THEN 0 ELSE 1 END),0),
            COUNT(child.id), COALESCE(MAX(child.is_protected_rule),0)
          FROM items parent
          LEFT JOIN items child ON child.scan_id=parent.scan_id
            AND child.parent_id=parent.id AND child.is_deleted=0
          WHERE parent.scan_id=? AND parent.depth=? AND parent.kind IN ('directory','package')
          GROUP BY parent.id
          """, [.integer(scanID), .integer(Int64(depth))])
        try executeBound(
          """
          UPDATE items AS parent SET
            logical_bytes = parent.own_logical_bytes + COALESCE((SELECT logical_bytes FROM odt_folder_rollups WHERE parent_id=parent.id),0),
            allocated_bytes = parent.accounted_allocated_bytes + COALESCE((SELECT allocated_bytes FROM odt_folder_rollups WHERE parent_id=parent.id),0),
            safety_status = CASE
              WHEN parent.is_protected_rule=1 AND parent.safety_status IN ('do_not_touch','delete_via_source_app') THEN parent.safety_status
              WHEN rollup.risk_rank=5 THEN 'do_not_touch'
              WHEN rollup.risk_rank=4 THEN 'delete_via_source_app'
              WHEN rollup.risk_rank=0 THEN 'safe_to_delete'
              WHEN rollup.risk_rank<=1 THEN 'recreated_automatically'
              WHEN rollup.risk_rank=2 AND rollup.non_review=0 THEN 'review'
              ELSE 'mixed' END,
            reason = CASE
              WHEN parent.is_protected_rule=1 AND parent.safety_status IN ('do_not_touch','delete_via_source_app') THEN parent.reason
              WHEN rollup.risk_rank=5 THEN 'This folder contains protected data and must not be removed directly.'
              WHEN rollup.risk_rank=4 THEN 'This folder contains application-managed data. Use the source application for cleanup.'
              WHEN rollup.risk_rank=0 THEN 'All scanned contents matched safe cleanup rules.'
              WHEN rollup.risk_rank<=1 THEN 'All scanned contents are disposable or can be rebuilt automatically.'
              WHEN rollup.risk_rank=2 AND rollup.non_review=0 THEN 'No trusted cleanup rule matched this folder or its contents.'
              ELSE 'This folder contains mixed safety statuses. Inspect its contents before cleanup.' END,
            rule_id = CASE
              WHEN parent.is_protected_rule=1 AND parent.safety_status IN ('do_not_touch','delete_via_source_app') THEN parent.rule_id
              ELSE 'aggregate.folder' END,
            is_protected_rule = MAX(parent.is_protected_rule, rollup.protected_rule)
          FROM odt_folder_rollups rollup
          WHERE parent.scan_id=? AND parent.depth=? AND parent.kind IN ('directory','package')
            AND parent.id=rollup.parent_id
          """, [.integer(scanID), .integer(Int64(depth))])
      }
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
  }

  private static func migrate(_ database: SQLiteConnection) throws {
    try database.execute(
      """
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=NORMAL;
      PRAGMA foreign_keys=ON;
      PRAGMA temp_store=MEMORY;
      CREATE TABLE IF NOT EXISTS scans(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        root_path TEXT NOT NULL,
        volume_name TEXT NOT NULL,
        volume_uuid TEXT,
        started_at TEXT NOT NULL,
        finished_at TEXT,
        state TEXT NOT NULL,
        intensity TEXT NOT NULL,
        item_count INTEGER NOT NULL DEFAULT 0,
        logical_bytes INTEGER NOT NULL DEFAULT 0,
        allocated_bytes INTEGER NOT NULL DEFAULT 0,
        inaccessible_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS items(
        id INTEGER NOT NULL,
        scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
        parent_id INTEGER,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        depth INTEGER NOT NULL,
        kind TEXT NOT NULL,
        extension TEXT,
        own_logical_bytes INTEGER NOT NULL,
        own_allocated_bytes INTEGER NOT NULL,
        accounted_allocated_bytes INTEGER NOT NULL,
        logical_bytes INTEGER NOT NULL,
        allocated_bytes INTEGER NOT NULL,
        created_at TEXT,
        modified_at TEXT,
        device_id INTEGER NOT NULL,
        file_id INTEGER NOT NULL,
        link_count INTEGER NOT NULL,
        is_hidden INTEGER NOT NULL,
        is_package INTEGER NOT NULL,
        safety_status TEXT NOT NULL,
        rule_id TEXT,
        reason TEXT NOT NULL,
        confidence TEXT NOT NULL,
        source_application TEXT,
        is_protected_rule INTEGER NOT NULL DEFAULT 0,
        duplicate_group_id INTEGER,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(scan_id,id)
      );
      CREATE INDEX IF NOT EXISTS items_parent ON items(scan_id,parent_id);
      CREATE INDEX IF NOT EXISTS items_size ON items(scan_id,allocated_bytes DESC);
      CREATE INDEX IF NOT EXISTS items_path ON items(scan_id,path);
      CREATE INDEX IF NOT EXISTS items_status ON items(scan_id,safety_status);
      CREATE INDEX IF NOT EXISTS items_duplicate_candidates ON items(scan_id,logical_bytes) WHERE kind='file';
      CREATE TABLE IF NOT EXISTS scan_errors(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        error_code INTEGER NOT NULL,
        message TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS duplicate_groups(
        id INTEGER NOT NULL,
        scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
        logical_bytes INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        reclaimable_bytes INTEGER NOT NULL,
        PRIMARY KEY(scan_id,id)
      );
      CREATE TABLE IF NOT EXISTS duplicate_members(
        scan_id INTEGER NOT NULL,
        group_id INTEGER NOT NULL,
        item_id INTEGER NOT NULL,
        PRIMARY KEY(scan_id,group_id,item_id),
        FOREIGN KEY(scan_id,group_id) REFERENCES duplicate_groups(scan_id,id) ON DELETE CASCADE,
        FOREIGN KEY(scan_id,item_id) REFERENCES items(scan_id,id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS user_rules(
        id TEXT PRIMARY KEY,
        json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS cleanup_actions(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id INTEGER NOT NULL,
        item_id INTEGER NOT NULL,
        original_path TEXT NOT NULL,
        status TEXT NOT NULL,
        performed_at TEXT NOT NULL,
        outcome TEXT NOT NULL,
        message TEXT
      );
      """)
    let versionStatement = try database.prepare("PRAGMA user_version")
    let version =
      sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
    sqlite3_finalize(versionStatement)
    if version < 2 {
      try database.execute(
        """
        PRAGMA foreign_keys=OFF;
        DROP TABLE IF EXISTS duplicate_members;
        DROP TABLE IF EXISTS duplicate_groups;
        CREATE TABLE duplicate_groups(
          id INTEGER NOT NULL,
          scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
          logical_bytes INTEGER NOT NULL,
          sha256 TEXT NOT NULL,
          reclaimable_bytes INTEGER NOT NULL,
          PRIMARY KEY(scan_id,id)
        );
        CREATE TABLE duplicate_members(
          scan_id INTEGER NOT NULL,
          group_id INTEGER NOT NULL,
          item_id INTEGER NOT NULL,
          PRIMARY KEY(scan_id,group_id,item_id),
          FOREIGN KEY(scan_id,group_id) REFERENCES duplicate_groups(scan_id,id) ON DELETE CASCADE,
          FOREIGN KEY(scan_id,item_id) REFERENCES items(scan_id,id) ON DELETE CASCADE
        );
        PRAGMA user_version=2;
        PRAGMA foreign_keys=ON;
        """)
    }
  }

  private func append(filter: ItemFilter, clauses: inout [String], values: inout [SQLValue]) {
    if !filter.search.isEmpty {
      clauses.append("(name LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\')")
      let escaped = filter.search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "%", with: "\\%"
      ).replacingOccurrences(of: "_", with: "\\_")
      values += [.text("%\(escaped)%"), .text("%\(escaped)%")]
    }
    if !filter.extensions.isEmpty {
      clauses.append(
        "extension IN (\(Array(repeating: "?", count: filter.extensions.count).joined(separator: ",")))"
      )
      values += filter.extensions.sorted().map(SQLValue.text)
    }
    if !filter.statuses.isEmpty {
      clauses.append(
        "safety_status IN (\(Array(repeating: "?", count: filter.statuses.count).joined(separator: ",")))"
      )
      values += filter.statuses.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
    }
    if let minimum = filter.minimumBytes {
      clauses.append("allocated_bytes>=?")
      values.append(.unsigned(minimum))
    }
    if let maximum = filter.maximumBytes {
      clauses.append("allocated_bytes<=?")
      values.append(.unsigned(maximum))
    }
    if let modifiedAfter = filter.modifiedAfter {
      clauses.append("modified_at>=?")
      values.append(.text(Self.dateString(modifiedAfter)))
    }
    if let modifiedBefore = filter.modifiedBefore {
      clauses.append("modified_at<=?")
      values.append(.text(Self.dateString(modifiedBefore)))
    }
    if filter.duplicatesOnly { clauses.append("duplicate_group_id IS NOT NULL") }
  }

  private func queryScans(whereClause: String, values: [SQLValue], limit: Int) throws
    -> [ScanRecord]
  {
    let sql =
      "SELECT id,root_path,volume_name,volume_uuid,started_at,finished_at,state,intensity,item_count,logical_bytes,allocated_bytes,inaccessible_count FROM scans \(whereClause) LIMIT ?"
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(values + [.integer(Int64(limit))], to: statement, sql: sql)
    var scans: [ScanRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let started = Self.date(Self.text(statement, 4)),
        let state = ScanState(rawValue: Self.text(statement, 6) ?? ""),
        let intensity = ScanIntensity(rawValue: Self.text(statement, 7) ?? "")
      else { continue }
      scans.append(
        ScanRecord(
          id: sqlite3_column_int64(statement, 0), rootPath: Self.text(statement, 1) ?? "",
          volumeName: Self.text(statement, 2) ?? "", volumeUUID: Self.text(statement, 3),
          startedAt: started, finishedAt: Self.date(Self.text(statement, 5)), state: state,
          intensity: intensity,
          itemCount: sqlite3_column_int64(statement, 8),
          logicalBytes: UInt64(max(0, sqlite3_column_int64(statement, 9))),
          allocatedBytes: UInt64(max(0, sqlite3_column_int64(statement, 10))),
          inaccessibleCount: sqlite3_column_int64(statement, 11)
        ))
    }
    return scans
  }

  private func queryItems(sql: String, values: [SQLValue]) throws -> [ScannedItem] {
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(values, to: statement, sql: sql)
    var items: [ScannedItem] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let item = Self.item(statement) { items.append(item) }
    }
    return items
  }

  private func queryChanges(sql: String, values: [SQLValue], kind: ScanChange.Kind) throws
    -> [ScanChange]
  {
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(values, to: statement, sql: sql)
    var values: [ScanChange] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let bytes = UInt64(max(0, sqlite3_column_int64(statement, 1)))
      values.append(
        ScanChange(
          kind: kind, path: Self.text(statement, 0) ?? "",
          previousBytes: kind == .removed ? bytes : nil, currentBytes: kind == .added ? bytes : nil)
      )
    }
    return values
  }

  private func executeBound(_ sql: String, _ values: [SQLValue]) throws {
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(values, to: statement, sql: sql)
    try database.stepDone(statement, sql: sql)
  }

  private func scalarInt(_ sql: String, _ values: [SQLValue]) throws -> Int64 {
    let statement = try database.prepare(sql)
    defer { sqlite3_finalize(statement) }
    try database.bind(values, to: statement, sql: sql)
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return sqlite3_column_int64(statement, 0)
  }

  private func pruneCompletedHistory(rootPath: String, keeping count: Int) throws {
    try executeBound(
      """
      DELETE FROM scans
      WHERE root_path=? AND state='completed' AND id NOT IN (
        SELECT id FROM scans WHERE root_path=? AND state='completed' ORDER BY id DESC LIMIT ?
      )
      """, [.text(rootPath), .text(rootPath), .integer(Int64(count))])
    try database.execute("DELETE FROM cleanup_actions WHERE scan_id NOT IN (SELECT id FROM scans)")
  }

  private static let itemSelect = """
    SELECT id,scan_id,parent_id,path,name,depth,kind,extension,
      own_logical_bytes,own_allocated_bytes,accounted_allocated_bytes,logical_bytes,allocated_bytes,
      created_at,modified_at,device_id,file_id,link_count,is_hidden,is_package,
      safety_status,rule_id,reason,confidence,source_application,is_protected_rule,duplicate_group_id,is_deleted
    FROM items
    """

  private static func item(_ statement: OpaquePointer) -> ScannedItem? {
    guard let kind = ItemKind(rawValue: text(statement, 6) ?? ""),
      let status = SafetyStatus(rawValue: text(statement, 20) ?? ""),
      let confidence = RuleConfidence(rawValue: text(statement, 23) ?? "")
    else { return nil }
    return ScannedItem(
      id: sqlite3_column_int64(statement, 0), scanID: sqlite3_column_int64(statement, 1),
      parentID: sqlite3_column_type(statement, 2) == SQLITE_NULL
        ? nil : sqlite3_column_int64(statement, 2),
      path: text(statement, 3) ?? "", name: text(statement, 4) ?? "",
      depth: Int(sqlite3_column_int64(statement, 5)), kind: kind, fileExtension: text(statement, 7),
      ownLogicalBytes: UInt64(max(0, sqlite3_column_int64(statement, 8))),
      ownAllocatedBytes: UInt64(max(0, sqlite3_column_int64(statement, 9))),
      accountedAllocatedBytes: UInt64(max(0, sqlite3_column_int64(statement, 10))),
      logicalBytes: UInt64(max(0, sqlite3_column_int64(statement, 11))),
      allocatedBytes: UInt64(max(0, sqlite3_column_int64(statement, 12))),
      createdAt: date(text(statement, 13)), modifiedAt: date(text(statement, 14)),
      deviceID: UInt64(bitPattern: sqlite3_column_int64(statement, 15)),
      fileID: UInt64(bitPattern: sqlite3_column_int64(statement, 16)),
      linkCount: UInt32(clamping: sqlite3_column_int64(statement, 17)),
      isHidden: sqlite3_column_int(statement, 18) != 0,
      isPackage: sqlite3_column_int(statement, 19) != 0,
      classification: Classification(
        status: status, ruleID: text(statement, 21), reason: text(statement, 22) ?? "",
        confidence: confidence, sourceApplication: text(statement, 24),
        isProtectedRule: sqlite3_column_int(statement, 25) != 0
      ),
      duplicateGroupID: sqlite3_column_type(statement, 26) == SQLITE_NULL
        ? nil : sqlite3_column_int64(statement, 26),
      isDeleted: sqlite3_column_int(statement, 27) != 0
    )
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: value)
  }

  private static func dateString(_ date: Date) -> String {
    iso8601Formatter.value.string(from: date)
  }

  private static func date(_ string: String?) -> Date? {
    guard let string else { return nil }
    return iso8601Formatter.value.date(from: string)
  }
}

extension Int64 {
  fileprivate init(clamping value: UInt64) {
    self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
  }
}

extension UInt32 {
  fileprivate init(clamping value: Int64) {
    self = value < 0 ? 0 : value > Int64(UInt32.max) ? UInt32.max : UInt32(value)
  }
}
