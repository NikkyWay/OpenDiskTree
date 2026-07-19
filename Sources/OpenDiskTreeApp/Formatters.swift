import Foundation
import OpenDiskTreeCore
import SwiftUI

enum HumanFormat {
  static func size(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
  }

  static func duration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }
}

extension SafetyStatus {
  var localizedTitle: String {
    let key = "status.\(rawValue)"
    let packagedValue = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    if packagedValue != key { return packagedValue }
    return Bundle.module.localizedString(forKey: key, value: nil, table: nil)
  }

  var color: Color {
    switch self {
    case .safeToDelete: .green
    case .recreatedAutomatically: .cyan
    case .deleteViaSourceApp: .orange
    case .doNotTouch: .red
    case .review: .secondary
    case .mixed: .yellow
    }
  }

  var symbol: String {
    switch self {
    case .safeToDelete: "checkmark.circle.fill"
    case .recreatedAutomatically: "arrow.clockwise.circle.fill"
    case .deleteViaSourceApp: "app.badge.fill"
    case .doNotTouch: "hand.raised.fill"
    case .review: "questionmark.circle.fill"
    case .mixed: "circle.hexagongrid.fill"
    }
  }
}

extension Int64 {
  fileprivate init(clamping value: UInt64) {
    self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
  }
}
