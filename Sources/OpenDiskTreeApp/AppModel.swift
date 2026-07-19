import AppKit
import Foundation
import OpenDiskTreeCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  @Published var recentScans: [ScanRecord] = []
  @Published var currentScan: ScanRecord?
  @Published var items: [ScannedItem] = []
  @Published var directoryItems: [ScannedItem] = []
  @Published var selectedItem: ScannedItem?
  @Published var progress = ScanProgress()
  @Published var isScanning = false
  @Published var isPaused = false
  @Published var isFindingDuplicates = false
  @Published var duplicateProgress: DuplicateProgress?
  @Published var statusMessage = "Choose a folder or disk to begin."
  @Published var errorMessage: String?
  @Published var searchText = ""
  @Published var selectedStatuses = Set<SafetyStatus>()
  @Published var extensionFilter = ""
  @Published var minimumSizeMB = ""
  @Published var maximumSizeMB = ""
  @Published var duplicatesOnly = false
  @Published var useModifiedAfter = false
  @Published var modifiedAfter =
    Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
  @Published var useModifiedBefore = false
  @Published var modifiedBefore = Date()
  @Published var sort: ItemSort = .allocatedSize
  @Published var currentParentID: Int64?
  @Published var navigationStack: [ScannedItem] = []
  @Published var pendingTrash: ScannedItem?
  @Published var pendingTrashNeedsRiskConfirmation = false
  @Published var pendingHistoryDeletion: ScanRecord?
  @Published var userRules: [CleanupRule] = []
  @Published var showRuleEditor = false

  @AppStorage("scanIntensity") private var intensityRaw = ScanIntensity.balanced.rawValue
  @AppStorage("strictDeletion") var strictDeletion = true
  @AppStorage("advancedRuleOverrides") var advancedRuleOverrides = false
  @AppStorage("aiTopFiles") var aiTopFiles = 500
  @AppStorage("aiTopDirectories") var aiTopDirectories = 200
  @AppStorage("aiAggregateDepth") var aiAggregateDepth = 4

  private(set) var store: ScanStore?
  private var scanner: DiskScanner?
  private var scanTask: Task<Void, Never>?
  private let duplicateFinder = DuplicateFinder()

  init() {
    do {
      store = try ScanStore()
      Task { await bootstrap() }
    } catch {
      errorMessage = error.localizedDescription
      statusMessage = "Database could not be opened."
    }
  }

  var intensity: ScanIntensity {
    get { ScanIntensity(rawValue: intensityRaw) ?? .balanced }
    set { intensityRaw = newValue.rawValue }
  }

  var filter: ItemFilter {
    let extensions = Set(
      extensionFilter.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(
          in: CharacterSet(charactersIn: "."))
      }.filter { !$0.isEmpty })
    let minimum = Self.bytesFromMegabytes(minimumSizeMB)
    let maximum = Self.bytesFromMegabytes(maximumSizeMB)
    return ItemFilter(
      search: searchText, extensions: extensions, statuses: selectedStatuses,
      minimumBytes: minimum, maximumBytes: maximum,
      modifiedAfter: useModifiedAfter ? modifiedAfter : nil,
      modifiedBefore: useModifiedBefore ? modifiedBefore : nil,
      duplicatesOnly: duplicatesOnly
    )
  }

  var activeFilterCount: Int {
    selectedStatuses.count
      + (extensionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
      + (minimumSizeMB.isEmpty ? 0 : 1)
      + (maximumSizeMB.isEmpty ? 0 : 1)
      + (duplicatesOnly ? 1 : 0)
      + (useModifiedAfter ? 1 : 0)
      + (useModifiedBefore ? 1 : 0)
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = String(localized: "scan.folder")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    if panel.runModal() == .OK, let url = panel.url { startScan(url: url) }
  }

  func scanFullDisk() { startScan(url: URL(fileURLWithPath: "/", isDirectory: true)) }

  func startScan(url: URL) {
    guard !isScanning, let store else { return }
    if (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false {
      errorMessage =
        "Network volumes are not supported. Choose a folder on a local or directly attached disk."
      return
    }
    scanTask = Task {
      do {
        isScanning = true
        isPaused = false
        progress = ScanProgress(currentPath: url.path)
        statusMessage = "Preparing scan…"
        let rules = try await store.loadUserRules()
        userRules = rules
        let engine = RuleEngine(userRules: rules, allowProtectedOverrides: advancedRuleOverrides)
        let activeScanner = DiskScanner(ruleEngine: engine)
        scanner = activeScanner
        let record = try await store.beginScan(rootURL: url, intensity: intensity)
        currentScan = record
        currentParentID = 1
        navigationStack = []
        selectedItem = nil
        let root = try DiskScanner.makeRootItem(scanID: record.id, id: 1, url: url, engine: engine)
        try await store.insert([root])
        items = []
        directoryItems = [root]

        let result = try await activeScanner.scan(
          scanID: record.id,
          rootItemID: 1,
          options: ScanOptions(rootURL: url, intensity: intensity),
          onBatch: { [weak self] batch, update in
            try await store.insert(batch)
            let liveItems = try await store.fetchChildren(
              scanID: record.id, parentID: 1, sort: .allocatedSize)
            await MainActor.run {
              self?.progress = update
              self?.statusMessage = self?.isPaused == true ? "Scan paused." : "Scanning…"
              guard self?.currentScan?.id == record.id else { return }
              if self?.currentParentID == 1 { self?.items = liveItems }
              self?.directoryItems = [root] + liveItems.filter(\.kind.canHaveChildren)
            }
          },
          onErrors: { errors in try await store.insert(errors: errors) }
        )
        currentScan = try await store.finishScan(record.id, result: result)
        statusMessage =
          result.cancelled ? "Scan cancelled; partial results were kept." : "Scan complete."
        try await reloadResults()
        await loadRecentScans()
      } catch {
        if let id = currentScan?.id {
          try? await store.failScan(id, message: error.localizedDescription)
        }
        errorMessage = error.localizedDescription
        statusMessage = "Scan failed."
      }
      isScanning = false
      isPaused = false
      scanner = nil
    }
  }

  func togglePause() {
    guard let scanner else { return }
    isPaused.toggle()
    statusMessage = isPaused ? "Scan paused." : "Scanning…"
    Task { if isPaused { await scanner.control.pause() } else { await scanner.control.resume() } }
  }

  func cancelScan() {
    guard let scanner else { return }
    statusMessage = "Cancelling…"
    Task { await scanner.control.cancel() }
  }

  func selectScan(_ scan: ScanRecord) {
    guard !isScanning, currentScan?.id != scan.id else { return }
    currentScan = scan
    currentParentID = 1
    navigationStack = []
    selectedItem = nil
    Task { try? await reloadResults() }
  }

  func requestDeleteHistory(_ scan: ScanRecord) { pendingHistoryDeletion = scan }

  func confirmDeleteHistory() {
    guard let scan = pendingHistoryDeletion, let store else { return }
    pendingHistoryDeletion = nil
    Task {
      do {
        try await store.deleteScan(scan.id)
        if currentScan?.id == scan.id {
          currentScan = nil
          items = []
          directoryItems = []
          selectedItem = nil
        }
        await loadRecentScans()
        statusMessage = "Scan snapshot removed. Files on disk were not changed."
      } catch { errorMessage = error.localizedDescription }
    }
  }

  func reloadResults() async throws {
    guard let store, let scanID = currentScan?.id else { return }
    let parent = currentParentID ?? 1
    let loadedItems = try await store.fetchChildren(
      scanID: scanID, parentID: parent, filter: filter, sort: sort)
    if items != loadedItems { items = loadedItems }
    if directoryItems.isEmpty || parent == 1 {
      let loadedDirectories = try await store.fetchDirectoryTree(scanID: scanID)
      if directoryItems != loadedDirectories { directoryItems = loadedDirectories }
    }
    if let selectedItem {
      if let refreshed = loadedItems.first(where: { $0.id == selectedItem.id }) {
        if refreshed != selectedItem { self.selectedItem = refreshed }
      } else {
        self.selectedItem = nil
      }
    }
  }

  func applyFilter() { Task { try? await reloadResults() } }

  func navigate(into item: ScannedItem) {
    guard item.kind.canHaveChildren else {
      selectedItem = item
      return
    }
    navigationStack.append(item)
    currentParentID = item.id
    selectedItem = nil
    Task { try? await reloadResults() }
  }

  func navigateFromTree(_ item: ScannedItem) {
    guard currentParentID != item.id else {
      if selectedItem != item { selectedItem = item }
      return
    }
    currentParentID = item.id
    navigationStack = [item]
    selectedItem = item
    Task { try? await reloadResults() }
  }

  func selectItem(_ item: ScannedItem?) {
    if selectedItem != item { selectedItem = item }
  }

  func navigateBack() {
    if !navigationStack.isEmpty { navigationStack.removeLast() }
    currentParentID = navigationStack.last?.id ?? 1
    selectedItem = nil
    Task { try? await reloadResults() }
  }

  func reveal(_ item: ScannedItem) {
    let url = URL(fileURLWithPath: item.path)
    if FileManager.default.fileExists(atPath: item.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
      errorMessage = "The item no longer exists at the scanned path."
    }
  }

  func requestTrash(_ item: ScannedItem) {
    switch FileActionPolicy.trashAuthorization(for: item, strictMode: strictDeletion) {
    case .allowed:
      pendingTrashNeedsRiskConfirmation = false
      pendingTrash = item
    case .requiresRiskConfirmation:
      pendingTrashNeedsRiskConfirmation = true
      pendingTrash = item
    case .blocked(let reason):
      errorMessage = reason
    }
  }

  func confirmTrash() {
    guard let item = pendingTrash, let store, let scanID = currentScan?.id else { return }
    pendingTrash = nil
    Task {
      var resultingURL: NSURL?
      do {
        guard FileActionPolicy.currentIdentityMatches(item) else {
          throw CocoaError(
            .fileNoSuchFile,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The item changed after the scan. Scan again before moving it to the Trash."
            ])
        }
        try FileManager.default.trashItem(
          at: URL(fileURLWithPath: item.path), resultingItemURL: &resultingURL)
        try await store.recordCleanupAction(
          scanID: scanID, item: item, outcome: "trashed", message: resultingURL?.path)
        try await store.markTrashed(scanID: scanID, itemIDs: [item.id])
        statusMessage = "Moved \(item.name) to the Trash."
        try await reloadResults()
      } catch {
        try? await store.recordCleanupAction(
          scanID: scanID, item: item, outcome: "failed", message: error.localizedDescription)
        errorMessage = error.localizedDescription
      }
    }
  }

  func findDuplicates() {
    guard let store, let scanID = currentScan?.id, !isFindingDuplicates else { return }
    isFindingDuplicates = true
    Task {
      do {
        let result = try await duplicateFinder.find(
          scanID: scanID, store: store, minimumBytes: 1_024
        ) { [weak self] update in
          await MainActor.run { self?.duplicateProgress = update }
        }
        statusMessage = "Found \(result.groups.count) duplicate groups."
        if !result.skippedCloudPlaceholders.isEmpty {
          statusMessage += " Skipped \(result.skippedCloudPlaceholders.count) cloud placeholders."
        }
        try await reloadResults()
      } catch { errorMessage = error.localizedDescription }
      isFindingDuplicates = false
    }
  }

  func cancelDuplicates() { Task { await duplicateFinder.cancel() } }

  func export(format: ExportFormat, privacy: PrivacyMode, scope: ExportScope = .entireScan) {
    guard let store, let scanID = currentScan?.id else { return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    switch format {
    case .json: panel.nameFieldStringValue = "opendisktree-scan.json"
    case .csv: panel.nameFieldStringValue = "opendisktree-scan.csv"
    case .sqlite: panel.nameFieldStringValue = "opendisktree-scan.sqlite"
    case .aiReport: panel.nameFieldStringValue = "ai-report.json"
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    statusMessage = "Exporting…"
    Task {
      do {
        let exporter = ScanExporter(store: store)
        try await exporter.export(
          scanID: scanID,
          to: url,
          options: ExportOptions(
            format: format, scope: scope, privacy: privacy,
            topFileLimit: aiTopFiles, topDirectoryLimit: aiTopDirectories,
            aggregateDepth: aiAggregateDepth
          )
        ) { [weak self] update in
          await MainActor.run { self?.statusMessage = "Exported \(update.exportedItems) items…" }
        }
        statusMessage = "Export saved to \(url.lastPathComponent)."
      } catch {
        errorMessage = error.localizedDescription
        statusMessage = "Export failed."
      }
    }
  }

  func saveRules(_ rules: [CleanupRule]) {
    guard let store else { return }
    Task {
      do {
        try await store.saveUserRules(rules)
        userRules = rules
        statusMessage = "Rules saved."
      } catch { errorMessage = error.localizedDescription }
    }
  }

  func openSourceApplication(for item: ScannedItem) {
    let identifiers = [
      "Xcode": "com.apple.dt.Xcode", "Docker": "com.docker.docker",
      "Google Chrome": "com.google.Chrome", "Firefox": "org.mozilla.firefox",
    ]
    guard let name = item.classification.sourceApplication, let identifier = identifiers[name],
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    else {
      errorMessage = "The source application could not be found."
      return
    }
    NSWorkspace.shared.openApplication(at: url, configuration: .init())
  }

  func openFullDiskAccessSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private func bootstrap() async {
    await loadRecentScans()
    if let store {
      userRules = (try? await store.loadUserRules()) ?? []
    }
  }

  private func loadRecentScans() async {
    guard let store else { return }
    do {
      recentScans = try await store.recentScans()
      if currentScan == nil, let first = recentScans.first {
        currentScan = first
        currentParentID = 1
        statusMessage =
          first.state == .cancelled
          ? "Cancelled scan; partial results were kept."
          : first.state == .failed ? "Scan failed." : "Scan complete."
        try await reloadResults()
      }
    } catch { errorMessage = error.localizedDescription }
  }

  private static func bytesFromMegabytes(_ text: String) -> UInt64? {
    guard let value = Double(text), value.isFinite, value >= 0,
      value <= Double(UInt64.max) / 1_000_000
    else { return nil }
    return UInt64(value * 1_000_000)
  }
}
