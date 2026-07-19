import Darwin
import Foundation
import OpenDiskTreeNative

public struct NativeDirectoryEntry: Sendable {
  public let name: String
  public let kind: ItemKind
  public let logicalBytes: UInt64
  public let allocatedBytes: UInt64
  public let fileID: UInt64
  public let deviceID: UInt64
  public let createdAt: Date?
  public let modifiedAt: Date?
  public let linkCount: UInt32
  public let isHidden: Bool
  public let isPackage: Bool
  public let isMountPoint: Bool

  public var fileExtension: String? {
    let value = URL(fileURLWithPath: name).pathExtension.lowercased()
    return value.isEmpty ? nil : value
  }
}

public struct NativeDirectoryListing: Sendable {
  public let entries: [NativeDirectoryEntry]
  public let usedBulkAPI: Bool
}

public enum DirectoryReadError: LocalizedError, Sendable {
  case posix(path: String, code: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case .posix(let path, _, let message): "\(path): \(message)"
    }
  }

  public var code: Int32 {
    switch self {
    case .posix(_, let code, _): code
    }
  }

  public var message: String {
    switch self {
    case .posix(_, _, let message): message
    }
  }
}

public enum FastDirectoryReader {
  private static let packageExtensions: Set<String> = [
    "app", "bundle", "framework", "plugin", "appex", "photoslibrary", "photolibrary",
    "musiclibrary", "rtfd",
  ]

  public static func read(path: String) throws -> NativeDirectoryListing {
    let listing = path.withCString { odt_read_directory($0) }
    defer { odt_free_directory_listing(listing) }
    if listing.error_code != 0 {
      let message = String(cString: strerror(listing.error_code))
      throw DirectoryReadError.posix(path: path, code: listing.error_code, message: message)
    }

    guard let base = listing.entries else {
      return NativeDirectoryListing(entries: [], usedBulkAPI: listing.used_bulk_api != 0)
    }
    var entries: [NativeDirectoryEntry] = []
    entries.reserveCapacity(listing.count)
    for index in 0..<listing.count {
      let raw = base[index]
      guard let pointer = raw.name else { continue }
      let name = String(cString: pointer)
      let kind = itemKind(mode: raw.mode, name: name)
      let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
      entries.append(
        NativeDirectoryEntry(
          name: name,
          kind: packageExtensions.contains(ext) && kind == .directory ? .package : kind,
          logicalBytes: raw.logical_size,
          allocatedBytes: raw.allocated_size,
          fileID: raw.file_id,
          deviceID: raw.device_id,
          createdAt: raw.created_seconds > 0
            ? Date(timeIntervalSince1970: TimeInterval(raw.created_seconds)) : nil,
          modifiedAt: raw.modified_seconds > 0
            ? Date(timeIntervalSince1970: TimeInterval(raw.modified_seconds)) : nil,
          linkCount: raw.link_count,
          isHidden: raw.is_hidden != 0,
          isPackage: packageExtensions.contains(ext) && kind == .directory,
          isMountPoint: raw.is_mount_point != 0
        ))
    }
    return NativeDirectoryListing(entries: entries, usedBulkAPI: listing.used_bulk_api != 0)
  }

  private static func itemKind(mode: UInt32, name: String) -> ItemKind {
    switch mode & UInt32(S_IFMT) {
    case UInt32(S_IFREG): .file
    case UInt32(S_IFDIR): .directory
    case UInt32(S_IFLNK): .symbolicLink
    default: .other
    }
  }
}
