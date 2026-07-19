import Darwin
import Foundation

public enum TrashAuthorization: Sendable, Equatable {
  case allowed
  case requiresRiskConfirmation
  case blocked(reason: String)
}

public enum FileActionPolicy {
  public static func trashAuthorization(for item: ScannedItem, strictMode: Bool)
    -> TrashAuthorization
  {
    guard !item.isDeleted else {
      return .blocked(reason: "This item has already been moved or removed.")
    }
    guard item.path != "/" && item.path != NSHomeDirectory() else {
      return .blocked(reason: "OpenDiskTree never moves a scan root to the Trash.")
    }
    if !strictMode { return .requiresRiskConfirmation }
    switch item.classification.status {
    case .safeToDelete, .recreatedAutomatically:
      return .allowed
    case .review, .mixed:
      return .requiresRiskConfirmation
    case .deleteViaSourceApp:
      return .blocked(reason: "Use the source application to remove this managed data.")
    case .doNotTouch:
      return .blocked(reason: "A protected rule marked this item as unsafe for direct cleanup.")
    }
  }

  public static func currentIdentityMatches(_ item: ScannedItem) -> Bool {
    var info = stat()
    let result = item.path.withCString { lstat($0, &info) }
    guard result == 0 else { return false }
    return UInt64(info.st_dev) == item.deviceID && UInt64(info.st_ino) == item.fileID
  }
}
