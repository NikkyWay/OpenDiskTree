import Foundation

public enum ScanIntensity: String, Codable, CaseIterable, Sendable {
  case balanced
  case turbo

  public var parallelism: Int {
    switch self {
    case .balanced: max(8, min(16, ProcessInfo.processInfo.activeProcessorCount * 2))
    case .turbo: 64
    }
  }
}

public enum ScanState: String, Codable, Sendable {
  case running
  case completed
  case cancelled
  case failed
}

public enum ScanMode: String, Codable, CaseIterable, Sendable {
  case full
  case incremental
}

public enum ItemKind: String, Codable, CaseIterable, Sendable {
  case file
  case directory
  case package
  case symbolicLink = "symbolic_link"
  case other

  public var canHaveChildren: Bool { self == .directory || self == .package }
}

public enum SafetyStatus: String, Codable, CaseIterable, Sendable {
  case safeToDelete = "safe_to_delete"
  case recreatedAutomatically = "recreated_automatically"
  case deleteViaSourceApp = "delete_via_source_app"
  case doNotTouch = "do_not_touch"
  case review
  case mixed

  public var riskRank: Int {
    switch self {
    case .safeToDelete: 0
    case .recreatedAutomatically: 1
    case .review: 2
    case .mixed: 3
    case .deleteViaSourceApp: 4
    case .doNotTouch: 5
    }
  }

  public var strictModeAllowsTrash: Bool {
    self == .safeToDelete || self == .recreatedAutomatically
  }
}

public enum RuleConfidence: String, Codable, Sendable {
  case high
  case medium
  case userDefined = "user_defined"
}

public enum PrivacyMode: String, Codable, CaseIterable, Sendable {
  case full
  case basic
  case strict
}

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
  case json
  case csv
  case sqlite
  case aiReport = "ai_report"
}

public enum ExportScope: Sendable, Equatable {
  case entireScan
  case filtered(ItemFilter)
  case selection(itemIDs: [Int64], includeDescendants: Bool)
}

public struct ItemFilter: Sendable, Equatable {
  public var search: String
  public var extensions: Set<String>
  public var statuses: Set<SafetyStatus>
  public var minimumBytes: UInt64?
  public var maximumBytes: UInt64?
  public var modifiedAfter: Date?
  public var modifiedBefore: Date?
  public var duplicatesOnly: Bool

  public init(
    search: String = "",
    extensions: Set<String> = [],
    statuses: Set<SafetyStatus> = [],
    minimumBytes: UInt64? = nil,
    maximumBytes: UInt64? = nil,
    modifiedAfter: Date? = nil,
    modifiedBefore: Date? = nil,
    duplicatesOnly: Bool = false
  ) {
    self.search = search
    self.extensions = extensions
    self.statuses = statuses
    self.minimumBytes = minimumBytes
    self.maximumBytes = maximumBytes
    self.modifiedAfter = modifiedAfter
    self.modifiedBefore = modifiedBefore
    self.duplicatesOnly = duplicatesOnly
  }

  public static let empty = ItemFilter()
}

public enum ItemSort: String, Codable, CaseIterable, Sendable {
  case allocatedSize = "allocated_size"
  case logicalSize = "logical_size"
  case name
  case modified
  case status
}

public struct Classification: Codable, Sendable, Equatable {
  public let status: SafetyStatus
  public let ruleID: String?
  public let reason: String
  public let confidence: RuleConfidence
  public let sourceApplication: String?
  public let isProtectedRule: Bool

  public init(
    status: SafetyStatus,
    ruleID: String?,
    reason: String,
    confidence: RuleConfidence,
    sourceApplication: String? = nil,
    isProtectedRule: Bool = false
  ) {
    self.status = status
    self.ruleID = ruleID
    self.reason = reason
    self.confidence = confidence
    self.sourceApplication = sourceApplication
    self.isProtectedRule = isProtectedRule
  }

  public static let review = Classification(
    status: .review,
    ruleID: nil,
    reason: "No trusted cleanup rule matched this item.",
    confidence: .medium
  )
}

public struct ScannedItem: Identifiable, Codable, Sendable, Equatable {
  public let id: Int64
  public let scanID: Int64
  public let parentID: Int64?
  public let path: String
  public let name: String
  public let depth: Int
  public let kind: ItemKind
  public let fileExtension: String?
  public let ownLogicalBytes: UInt64
  public let ownAllocatedBytes: UInt64
  public let accountedAllocatedBytes: UInt64
  public var logicalBytes: UInt64
  public var allocatedBytes: UInt64
  public let createdAt: Date?
  public let modifiedAt: Date?
  public let deviceID: UInt64
  public let fileID: UInt64
  public let linkCount: UInt32
  public let isHidden: Bool
  public let isPackage: Bool
  public let classification: Classification
  public var duplicateGroupID: Int64?
  public var isDeleted: Bool

  public init(
    id: Int64,
    scanID: Int64,
    parentID: Int64?,
    path: String,
    name: String,
    depth: Int,
    kind: ItemKind,
    fileExtension: String?,
    ownLogicalBytes: UInt64,
    ownAllocatedBytes: UInt64,
    accountedAllocatedBytes: UInt64,
    logicalBytes: UInt64,
    allocatedBytes: UInt64,
    createdAt: Date?,
    modifiedAt: Date?,
    deviceID: UInt64,
    fileID: UInt64,
    linkCount: UInt32,
    isHidden: Bool,
    isPackage: Bool,
    classification: Classification,
    duplicateGroupID: Int64? = nil,
    isDeleted: Bool = false
  ) {
    self.id = id
    self.scanID = scanID
    self.parentID = parentID
    self.path = path
    self.name = name
    self.depth = depth
    self.kind = kind
    self.fileExtension = fileExtension
    self.ownLogicalBytes = ownLogicalBytes
    self.ownAllocatedBytes = ownAllocatedBytes
    self.accountedAllocatedBytes = accountedAllocatedBytes
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.deviceID = deviceID
    self.fileID = fileID
    self.linkCount = linkCount
    self.isHidden = isHidden
    self.isPackage = isPackage
    self.classification = classification
    self.duplicateGroupID = duplicateGroupID
    self.isDeleted = isDeleted
  }
}

public struct ScanRecord: Identifiable, Codable, Sendable, Equatable {
  public let id: Int64
  public let rootPath: String
  public let volumeName: String
  public let volumeUUID: String?
  public let startedAt: Date
  public var finishedAt: Date?
  public var state: ScanState
  public let intensity: ScanIntensity
  public let mode: ScanMode
  public var reusedItemCount: Int64
  public var journalComplete: Bool
  public var itemCount: Int64
  public var logicalBytes: UInt64
  public var allocatedBytes: UInt64
  public var inaccessibleCount: Int64
}

public struct ScanProgress: Sendable, Equatable {
  public var files: Int64 = 0
  public var directories: Int64 = 0
  public var logicalBytes: UInt64 = 0
  public var allocatedBytes: UInt64 = 0
  public var inaccessible: Int64 = 0
  public var currentPath: String = ""
  public var startedAt = Date()

  public init(
    files: Int64 = 0,
    directories: Int64 = 0,
    logicalBytes: UInt64 = 0,
    allocatedBytes: UInt64 = 0,
    inaccessible: Int64 = 0,
    currentPath: String = "",
    startedAt: Date = Date()
  ) {
    self.files = files
    self.directories = directories
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
    self.inaccessible = inaccessible
    self.currentPath = currentPath
    self.startedAt = startedAt
  }

  public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}

public struct ScanErrorRecord: Codable, Sendable, Equatable {
  public let scanID: Int64
  public let path: String
  public let code: Int32
  public let message: String
}

public struct ScannerResult: Sendable, Equatable {
  public let progress: ScanProgress
  public let cancelled: Bool
  public let bulkDirectoryCount: Int
  public let fallbackDirectoryCount: Int
  public let maximumDepth: Int
  public let reusedItemCount: Int64
  public let reusedPaths: [String]
  public let journalComplete: Bool
  public let directoryRollups: [DirectoryRollup]

  public init(
    progress: ScanProgress,
    cancelled: Bool,
    bulkDirectoryCount: Int,
    fallbackDirectoryCount: Int,
    maximumDepth: Int,
    reusedItemCount: Int64 = 0,
    reusedPaths: [String] = [],
    journalComplete: Bool = true,
    directoryRollups: [DirectoryRollup] = []
  ) {
    self.progress = progress
    self.cancelled = cancelled
    self.bulkDirectoryCount = bulkDirectoryCount
    self.fallbackDirectoryCount = fallbackDirectoryCount
    self.maximumDepth = maximumDepth
    self.reusedItemCount = reusedItemCount
    self.reusedPaths = reusedPaths
    self.journalComplete = journalComplete
    self.directoryRollups = directoryRollups
  }
}

public struct DirectoryRollup: Sendable, Equatable {
  public let itemID: Int64
  public let logicalBytes: UInt64
  public let allocatedBytes: UInt64
  public let itemCount: Int64
  public let fileCount: Int64
  public let directoryCount: Int64
  public let maximumDepth: Int
  public let containsHardLinks: Bool
  public let classification: Classification

  public init(
    itemID: Int64,
    logicalBytes: UInt64,
    allocatedBytes: UInt64,
    itemCount: Int64 = 0,
    fileCount: Int64 = 0,
    directoryCount: Int64 = 0,
    maximumDepth: Int = 0,
    containsHardLinks: Bool = false,
    classification: Classification
  ) {
    self.itemID = itemID
    self.logicalBytes = logicalBytes
    self.allocatedBytes = allocatedBytes
    self.itemCount = itemCount
    self.fileCount = fileCount
    self.directoryCount = directoryCount
    self.maximumDepth = maximumDepth
    self.containsHardLinks = containsHardLinks
    self.classification = classification
  }
}

public struct DuplicateGroup: Identifiable, Codable, Sendable, Equatable {
  public let id: Int64
  public let scanID: Int64
  public let logicalBytes: UInt64
  public let sha256: String
  public let itemIDs: [Int64]
  public let reclaimableBytes: UInt64
}

public struct ScanChange: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case added, removed, changed, grown }
  public let kind: Kind
  public let path: String
  public let previousBytes: UInt64?
  public let currentBytes: UInt64?
}

public struct StoreSummary: Codable, Sendable, Equatable {
  public let scan: ScanRecord
  public let topFiles: [ScannedItem]
  public let topDirectories: [ScannedItem]
  public let statusBytes: [SafetyStatus: UInt64]
  public let extensionBytes: [String: UInt64]
  public let duplicateGroups: [DuplicateGroup]
  public let errors: [ScanErrorRecord]
  public let changes: [ScanChange]
}
