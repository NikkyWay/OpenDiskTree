import Foundation
import OpenDiskTreeCore
import SwiftUI

enum HumanFormat {
  static func size(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
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
