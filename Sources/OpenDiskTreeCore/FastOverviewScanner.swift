import Foundation

/// A deliberately small first pass used to make a scan useful before the exact
/// metadata walk has finished. It reads only the selected directory itself, so
/// it returns in the time needed to list one directory and never materializes a
/// record for the whole disk.
public struct FastOverviewItem: Sendable, Equatable {
  public let path: String
  public let kind: ItemKind
  public let logicalBytes: UInt64
  public let allocatedBytes: UInt64

  public init(path: String, kind: ItemKind, logicalBytes: UInt64, allocatedBytes: UInt64) {
    self.path = path
    self.kind = kind
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
  }

  public var name: String {
    let value = URL(fileURLWithPath: path).lastPathComponent
    return value.isEmpty ? path : value
  }
}

public struct FastOverviewResult: Sendable, Equatable {
  public let root: FastOverviewItem?
  public let children: [FastOverviewItem]
  public let inaccessibleCount: Int64

  public init(
    root: FastOverviewItem?, children: [FastOverviewItem], inaccessibleCount: Int64
  ) {
    self.root = root
    self.children = children
    self.inaccessibleCount = inaccessibleCount
  }
}

public enum FastOverviewScanner {
  /// Lists one directory with the same bulk metadata reader as the exact scan.
  /// Folder totals are intentionally incomplete and are replaced by exact
  /// values as soon as the full scanner reaches those folders.
  public static func scan(rootURL: URL) async -> FastOverviewResult {
    let path = rootURL.standardizedFileURL.path
    return await Task.detached(priority: .userInitiated) {
      do {
        let listing = try FastDirectoryReader.read(path: path)
        let children = listing.entries.map { entry in
          let childPath = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
          let isContainer = entry.kind.canHaveChildren
          return FastOverviewItem(
            path: childPath, kind: entry.kind,
            logicalBytes: isContainer ? 0 : entry.logicalBytes,
            allocatedBytes: isContainer ? 0 : entry.allocatedBytes)
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }
        let logical = children.reduce(0) { $0 &+ $1.logicalBytes }
        let allocated = children.reduce(0) { $0 &+ $1.allocatedBytes }
        let root = FastOverviewItem(
          path: path, kind: .directory, logicalBytes: logical, allocatedBytes: allocated)
        return FastOverviewResult(root: root, children: children, inaccessibleCount: 0)
      } catch {
        return FastOverviewResult(root: nil, children: [], inaccessibleCount: 1)
      }
    }.value
  }
}
