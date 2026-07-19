import Foundation

public struct PathRedactor {
  public let mode: PrivacyMode
  private let homePath: String
  private var volumeTokens: [String: String] = [:]
  private var segmentTokens: [String: String] = [:]
  private var nextVolume = 1
  private var nextSegment = 1

  private static let preservedSegments: Set<String> = [
    "System", "Library", "Caches", "Logs", "Developer", "Xcode", "DerivedData", "Archives",
    "CoreSimulator", "Devices", "Applications", "Containers", "Application Support", "usr", "bin",
    "sbin", "private", "var", "tmp", "Users", "Volumes", "Google", "Chrome", "Firefox", "Docker",
  ]

  public init(mode: PrivacyMode, homePath: String = NSHomeDirectory()) {
    self.mode = mode
    self.homePath = homePath
  }

  public mutating func redact(_ path: String) -> String {
    guard mode != .full else { return path }
    var normalized = path
    if normalized == homePath || normalized.hasPrefix(homePath + "/") {
      normalized = "$HOME" + normalized.dropFirst(homePath.count)
    } else if normalized.hasPrefix("/Volumes/") {
      let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(
        String.init)
      if components.count >= 2 {
        let volume = components[1]
        let token =
          volumeTokens[volume]
          ?? {
            let value = "$VOLUME_\(nextVolume)"
            volumeTokens[volume] = value
            nextVolume += 1
            return value
          }()
        normalized =
          "/Volumes/" + token
          + (components.count > 2 ? "/" + components.dropFirst(2).joined(separator: "/") : "")
      }
    }
    guard mode == .strict else { return normalized }

    let hasLeadingSlash = normalized.hasPrefix("/")
    let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let redacted = parts.map { segment -> String in
      if segment == "$HOME" || segment.hasPrefix("$VOLUME_")
        || Self.preservedSegments.contains(segment)
      {
        return segment
      }
      let ext = URL(fileURLWithPath: segment).pathExtension
      let base = ext.isEmpty ? segment : String(segment.dropLast(ext.count + 1))
      let key = base.lowercased()
      let token =
        segmentTokens[key]
        ?? {
          let value = String(format: "item_%04d", nextSegment)
          segmentTokens[key] = value
          nextSegment += 1
          return value
        }()
      return ext.isEmpty ? token : "\(token).\(ext.lowercased())"
    }
    return (hasLeadingSlash ? "/" : "") + redacted.joined(separator: "/")
  }
}
