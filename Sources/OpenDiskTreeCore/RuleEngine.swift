import Darwin
import Foundation

public enum RuleMatchKind: String, Codable, Sendable {
  case prefix
  case contains
  case suffix
  case glob
}

public struct CleanupRule: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public var title: String
  public var priority: Int
  public var pattern: String
  public var matchKind: RuleMatchKind
  public var kinds: Set<ItemKind>
  public var status: SafetyStatus
  public var reason: String
  public var sourceApplication: String?
  public var sourceURL: String?
  public var isProtected: Bool
  public var isEnabled: Bool
  public var isUserRule: Bool

  public init(
    id: String,
    title: String,
    priority: Int,
    pattern: String,
    matchKind: RuleMatchKind,
    kinds: Set<ItemKind> = [],
    status: SafetyStatus,
    reason: String,
    sourceApplication: String? = nil,
    sourceURL: String? = nil,
    isProtected: Bool = false,
    isEnabled: Bool = true,
    isUserRule: Bool = false
  ) {
    self.id = id
    self.title = title
    self.priority = priority
    self.pattern = pattern
    self.matchKind = matchKind
    self.kinds = kinds
    self.status = status
    self.reason = reason
    self.sourceApplication = sourceApplication
    self.sourceURL = sourceURL
    self.isProtected = isProtected
    self.isEnabled = isEnabled
    self.isUserRule = isUserRule
  }
}

public struct RuleDocument: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let rules: [CleanupRule]

  public init(schemaVersion: Int = 1, rules: [CleanupRule]) {
    self.schemaVersion = schemaVersion
    self.rules = rules
  }
}

public struct RuleEngine: Sendable {
  private struct CompiledRule: Sendable {
    let rule: CleanupRule
    let pattern: String
    let suffixExtension: String?
  }

  public let rules: [CleanupRule]
  private let compiledRules: [CompiledRule]
  private let homePath: String

  public init(
    userRules: [CleanupRule] = [], homePath: String = NSHomeDirectory(),
    allowProtectedOverrides: Bool = false
  ) {
    let sortedRules = (userRules + Self.builtInRules).sorted {
      if !allowProtectedOverrides && $0.isProtected != $1.isProtected { return $0.isProtected }
      if $0.isUserRule != $1.isUserRule { return $0.isUserRule }
      return $0.priority > $1.priority
    }
    self.homePath = homePath
    self.rules = sortedRules
    self.compiledRules = sortedRules.map {
      let pattern = Self.expandHome(in: $0.pattern, homePath: homePath)
      let suffixExtension =
        $0.matchKind == .suffix && pattern.hasPrefix(".") && !pattern.dropFirst().contains("/")
        ? String(pattern.dropFirst()).lowercased() : nil
      return CompiledRule(rule: $0, pattern: pattern, suffixExtension: suffixExtension)
    }
  }

  public func classify(path: String, kind: ItemKind, fileExtension: String? = nil) -> Classification
  {
    guard
      let rule = compiledRules.first(where: {
        matches($0, path: path, kind: kind, fileExtension: fileExtension)
      })?.rule
    else {
      return .review
    }
    return Classification(
      status: rule.status,
      ruleID: rule.id,
      reason: rule.reason,
      confidence: rule.isUserRule ? .userDefined : .high,
      sourceApplication: rule.sourceApplication,
      isProtectedRule: rule.isProtected
    )
  }

  public func matchingItems(for rule: CleanupRule, in items: [ScannedItem]) -> [ScannedItem] {
    let compiled = CompiledRule(
      rule: rule,
      pattern: Self.expandHome(in: rule.pattern, homePath: homePath),
      suffixExtension: rule.matchKind == .suffix && rule.pattern.hasPrefix(".")
        && !rule.pattern.dropFirst().contains("/")
        ? String(rule.pattern.dropFirst()).lowercased() : nil
    )
    return items.filter {
      matches(compiled, path: $0.path, kind: $0.kind, fileExtension: $0.fileExtension)
    }
  }

  public static func aggregate(_ classifications: [Classification]) -> Classification {
    guard let first = classifications.first else { return .review }
    if classifications.allSatisfy({ $0.status == .safeToDelete }) { return first }
    if classifications.allSatisfy({
      $0.status == .safeToDelete || $0.status == .recreatedAutomatically
    }) {
      return Classification(
        status: .recreatedAutomatically,
        ruleID: "aggregate.recreated",
        reason: "All contents are disposable or can be rebuilt automatically.",
        confidence: .high
      )
    }
    let strictest = classifications.max { $0.status.riskRank < $1.status.riskRank } ?? .review
    return Classification(
      status: .mixed,
      ruleID: "aggregate.mixed",
      reason:
        "The folder contains mixed safety statuses. The strictest child is \(strictest.status.rawValue).",
      confidence: .high,
      isProtectedRule: classifications.contains(where: \.isProtectedRule)
    )
  }

  private static func expandHome(in pattern: String, homePath: String) -> String {
    if pattern == "~" { return homePath }
    if pattern.hasPrefix("~/") { return homePath + pattern.dropFirst() }
    return pattern
  }

  private func matches(
    _ compiled: CompiledRule,
    path: String,
    kind: ItemKind,
    fileExtension: String?
  ) -> Bool {
    let rule = compiled.rule
    guard rule.isEnabled, rule.kinds.isEmpty || rule.kinds.contains(kind) else { return false }
    return switch rule.matchKind {
    case .prefix: path == compiled.pattern || path.hasPrefix(compiled.pattern + "/")
    case .contains:
      path.range(of: compiled.pattern, options: [.caseInsensitive]) != nil
    case .suffix:
      if let suffixExtension = compiled.suffixExtension, let fileExtension {
        fileExtension == suffixExtension
      } else {
        path.hasSuffix(compiled.pattern)
          || path.range(
            of: compiled.pattern,
            options: [.caseInsensitive, .anchored, .backwards]
          ) != nil
      }
    case .glob:
      compiled.pattern.withCString { pattern in path.withCString { fnmatch(pattern, $0, 0) == 0 } }
    }
  }

  public static let builtInRules: [CleanupRule] = [
    CleanupRule(
      id: "macos.system.sealed", title: "macOS system files", priority: 1_000,
      pattern: "/System", matchKind: .prefix, status: .doNotTouch,
      reason: "This path belongs to the macOS system volume and should not be removed manually.",
      sourceApplication: "macOS",
      sourceURL:
        "https://support.apple.com/guide/security/signed-system-volume-security-secd698747c9/web",
      isProtected: true
    ),
    CleanupRule(
      id: "macos.unix.core", title: "Core Unix files", priority: 990,
      pattern: "/bin", matchKind: .prefix, status: .doNotTouch,
      reason: "Core command-line tools are required by macOS.", isProtected: true
    ),
    CleanupRule(
      id: "macos.unix.sbin", title: "Core system tools", priority: 990,
      pattern: "/sbin", matchKind: .prefix, status: .doNotTouch,
      reason: "Core system tools are required by macOS.", isProtected: true
    ),
    CleanupRule(
      id: "macos.private", title: "Private system data", priority: 980,
      pattern: "/private", matchKind: .prefix, status: .doNotTouch,
      reason: "This is system-managed data. Remove it only through a documented macOS workflow.",
      sourceApplication: "macOS", isProtected: true
    ),
    CleanupRule(
      id: "macos.user.caches", title: "User caches", priority: 800,
      pattern: "~/Library/Caches", matchKind: .prefix, status: .recreatedAutomatically,
      reason: "Applications normally recreate files in the user cache directory.",
      sourceApplication: "macOS", sourceURL: "https://support.apple.com/en-us/102624"
    ),
    CleanupRule(
      id: "macos.user.logs", title: "User logs", priority: 790,
      pattern: "~/Library/Logs", matchKind: .prefix, status: .safeToDelete,
      reason:
        "These diagnostic logs are not user documents. Keep recent logs while troubleshooting.",
      sourceApplication: "macOS",
      sourceURL:
        "https://support.apple.com/guide/mac-help/find-and-delete-files-on-your-mac-syspf5a64aa6/mac"
    ),
    CleanupRule(
      id: "xcode.derived-data", title: "Xcode Derived Data", priority: 900,
      pattern: "~/Library/Developer/Xcode/DerivedData", matchKind: .prefix,
      status: .recreatedAutomatically,
      reason: "Xcode rebuilds Derived Data when projects are compiled again.",
      sourceApplication: "Xcode",
      sourceURL:
        "https://developer.apple.com/documentation/xcode/maintaining-a-local-copy-of-source-code"
    ),
    CleanupRule(
      id: "xcode.archives", title: "Xcode archives", priority: 910,
      pattern: "~/Library/Developer/Xcode/Archives", matchKind: .prefix,
      status: .deleteViaSourceApp,
      reason:
        "Archives can contain signed release builds. Review and remove them through Xcode Organizer.",
      sourceApplication: "Xcode", isProtected: true
    ),
    CleanupRule(
      id: "simulator.devices", title: "Simulator devices", priority: 900,
      pattern: "~/Library/Developer/CoreSimulator/Devices", matchKind: .prefix,
      status: .deleteViaSourceApp,
      reason:
        "Simulator device data should be removed through Xcode or simctl to keep device state consistent.",
      sourceApplication: "Xcode", isProtected: true
    ),
    CleanupRule(
      id: "npm.cache", title: "npm cache", priority: 850,
      pattern: "~/.npm/_cacache", matchKind: .prefix, status: .recreatedAutomatically,
      reason: "npm can download or rebuild its content-addressed cache.", sourceApplication: "npm",
      sourceURL: "https://docs.npmjs.com/cli/commands/npm-cache"
    ),
    CleanupRule(
      id: "gradle.cache", title: "Gradle cache", priority: 850,
      pattern: "~/.gradle/caches", matchKind: .prefix, status: .recreatedAutomatically,
      reason: "Gradle recreates dependency and build caches as needed.",
      sourceApplication: "Gradle",
      sourceURL: "https://docs.gradle.org/current/userguide/directory_layout.html"
    ),
    CleanupRule(
      id: "docker.data", title: "Docker data", priority: 920,
      pattern: "~/Library/Containers/com.docker.docker", matchKind: .prefix,
      status: .deleteViaSourceApp,
      reason:
        "Docker manages images, containers and volumes here. Use Docker's cleanup tools to avoid data loss.",
      sourceApplication: "Docker",
      sourceURL: "https://docs.docker.com/engine/manage-resources/pruning/",
      isProtected: true
    ),
    CleanupRule(
      id: "opendisktree.data", title: "OpenDiskTree history", priority: 930,
      pattern: "~/Library/Application Support/OpenDiskTree", matchKind: .prefix,
      status: .deleteViaSourceApp,
      reason:
        "This directory contains OpenDiskTree scan history. Remove history from OpenDiskTree rather than deleting an active database.",
      sourceApplication: "OpenDiskTree", isProtected: true
    ),
    CleanupRule(
      id: "browser.chrome.cache", title: "Chrome cache", priority: 870,
      pattern: "~/Library/Caches/Google/Chrome", matchKind: .prefix,
      status: .recreatedAutomatically, reason: "Chrome recreates its browser cache.",
      sourceApplication: "Google Chrome",
      sourceURL: "https://support.google.com/accounts/answer/32050"
    ),
    CleanupRule(
      id: "browser.firefox.cache", title: "Firefox cache", priority: 870,
      pattern: "~/Library/Caches/Firefox", matchKind: .prefix,
      status: .recreatedAutomatically, reason: "Firefox recreates its browser cache.",
      sourceApplication: "Firefox",
      sourceURL: "https://support.mozilla.org/kb/how-clear-firefox-cache"
    ),
    CleanupRule(
      id: "downloaded.disk-image", title: "Downloaded disk image", priority: 200,
      pattern: ".dmg", matchKind: .suffix, kinds: [.file], status: .review,
      reason:
        "This may be an installer you no longer need, but OpenDiskTree cannot know whether it is your only copy."
    ),
  ]
}
