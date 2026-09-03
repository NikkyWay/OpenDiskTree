import AppKit
import CoreServices
import Foundation
import OpenDiskTreeCore
import SwiftUI

private actor ScanLiveRefreshGate {
  private var lastRefresh = Date.distantPast
  private let interval: TimeInterval

  init(interval: TimeInterval = 0.75) {
    self.interval = interval
  }

  func shouldRefresh() -> Bool {
    let now = Date()
    guard now.timeIntervalSince(lastRefresh) >= interval else { return false }
    lastRefresh = now
    return true
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var recentScans: [ScanRecord] = []
  @Published var currentScan: ScanRecord?
  @Published var items: [ScannedItem] = []
  @Published var directoryItems: [ScannedItem] = []
  @Published var selectedItems: [ScannedItem] = []
  @Published var showingLargestItems = false
  @Published var progress = ScanProgress()
  @Published var isScanning = false
  @Published var isLoadingResults = false
  @Published var isPreliminary = false
  @Published var isPaused = false
  @Published var isFindingDuplicates = false
  @Published var isExporting = false
  @Published var exportProgress: ExportProgress?
  @Published var duplicateProgress: DuplicateProgress?
  @Published var scanErrors: [ScanErrorRecord] = []
  @Published var showScanErrors = false
  @Published var isLoadingScanErrors = false
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
  @Published var pendingTrashItems: [ScannedItem] = []
  @Published var pendingTrashNeedsRiskConfirmation = false
  @Published var pendingHistoryDeletion: ScanRecord?
  @Published var userRules: [CleanupRule] = []
  @Published var showRuleEditor = false
  @Published var lastScanWasIncremental = false
  @Published var incrementalUnavailableReason: String?

  @AppStorage("scanIntensity") private var intensityRaw = ScanIntensity.turbo.rawValue
  @AppStorage("strictDeletion") var strictDeletion = true
  @AppStorage("advancedRuleOverrides") var advancedRuleOverrides = false
  @AppStorage("aiTopFiles") var aiTopFiles = 500
  @AppStorage("aiTopDirectories") var aiTopDirectories = 200
  @AppStorage("aiAggregateDepth") var aiAggregateDepth = 4

  private(set) var store: ScanStore?
  private var scanner: DiskScanner?
  private var scanTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var overviewTask: Task<FastOverviewResult, Never>?
  private var maintenanceTask: Task<Void, Never>?
  private var activeSecurityScopedURL: URL?
  private var loadedDirectoryIDs = Set<Int64>()
  private var resultsReloadGeneration: UInt64 = 0
  private let bookmarkDefaultsKey = "securityScopedScanBookmarks"
  private let journalDefaultsKey = "fseventsBaselineIDs"
  private let duplicateFinder = DuplicateFinder()
  private let automaticIncrementalPathLimit = 25_000
  private let changeJournal: FSEventsChangeJournal
  private var journalBaselineIDs: [String: UInt64]

  init() {
    let storedJournalBaselines =
      UserDefaults.standard.dictionary(forKey: "fseventsBaselineIDs") ?? [:]
    journalBaselineIDs = storedJournalBaselines.compactMapValues {
      ($0 as? NSNumber)?.uint64Value
    }
    let oldestBaseline = journalBaselineIDs.values.min()
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("OpenDiskTree", isDirectory: true).path
    changeJournal = FSEventsChangeJournal(
      sinceEventID: oldestBaseline ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      ignoredRootPaths: applicationSupport.map { [$0] } ?? [])
    do {
      store = try ScanStore()
      Task { await bootstrap() }
    } catch {
      errorMessage = error.localizedDescription
      statusMessage = "Database could not be opened."
    }
  }

  var intensity: ScanIntensity {
    get { ScanIntensity(rawValue: intensityRaw) ?? .turbo }
    set { intensityRaw = newValue.rawValue }
  }

  var selectedItem: ScannedItem? { selectedItems.first }
  var selectedItemIDs: Set<Int64> { Set(selectedItems.map(\.id)) }

  var pendingTrashTitle: String {
    if pendingTrashNeedsRiskConfirmation {
      return pendingTrashItems.count == 1
        ? "This item is not classified as safe"
        : "Some selected items are not classified as safe"
    }
    return pendingTrashItems.count == 1
      ? "Move this item to the Trash?"
      : "Move \(pendingTrashItems.count.formatted()) items to the Trash?"
  }

  var pendingTrashSummary: String {
    guard !pendingTrashItems.isEmpty else { return "" }
    if let item = pendingTrashItems.first, pendingTrashItems.count == 1 {
      return "\(item.path)\n\n\(item.classification.reason)"
    }
    let bytes = pendingTrashItems.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes }
    let statuses = Dictionary(grouping: pendingTrashItems, by: \.classification.status)
      .sorted { $0.key.riskRank > $1.key.riskRank }
      .map { "\($0.key.localizedTitle): \($0.value.count.formatted())" }
      .joined(separator: "\n")
    return "Total on disk: \(HumanFormat.size(bytes))\n\n\(statuses)"
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
    guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
    saveSecurityScopedBookmark(for: selectedURL)
    startScan(url: resolveSecurityScopedBookmark(for: selectedURL) ?? selectedURL)
  }

  func scanFullDisk() { startScan(url: URL(fileURLWithPath: "/", isDirectory: true)) }

  func repeatCurrentScan(mode: ScanMode) {
    guard let currentScan else { return }
    startScan(url: URL(fileURLWithPath: currentScan.rootPath, isDirectory: true), mode: mode)
  }

  func startScan(url: URL, mode requestedMode: ScanMode? = nil) {
    guard !isScanning, let store else { return }
    maintenanceTask?.cancel()
    maintenanceTask = nil
    if (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false {
      errorMessage =
        "Network volumes are not supported. Choose a folder on a local or directly attached disk."
      return
    }
    let securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    activeSecurityScopedURL = securityScopedURL
    let rootPath = url.standardizedFileURL.path
    isScanning = true
    isPreliminary = false
    showingLargestItems = false
    currentScan = nil
    currentParentID = 1
    navigationStack = []
    selectedItems = []
    scanErrors = []
    items = []
    directoryItems = []
    loadedDirectoryIDs.removeAll(keepingCapacity: true)
    progress = ScanProgress(currentPath: url.path)
    statusMessage = "Quick overview…"
    scanTask = Task {
      defer {
        if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
        activeSecurityScopedURL = nil
        overviewTask?.cancel()
        overviewTask = nil
      }
      do {
        let previous = try await store.latestCompletedScan(rootPath: rootPath)
        let baselineEventID = journalBaselineIDs[rootPath]
        let journalSnapshot = changeJournal.snapshot(
          for: url, sinceEventID: baselineEventID)
        let incrementalAllowed =
          previous != nil && baselineEventID != nil
          && journalSnapshot.complete && previous?.journalComplete == true
        let mode: ScanMode
        if requestedMode == .full {
          mode = .full
        } else if incrementalAllowed
          && (requestedMode == .incremental
            || journalSnapshot.paths.count <= automaticIncrementalPathLimit)
        {
          mode = .incremental
        } else {
          mode = .full
          if requestedMode == .incremental {
            incrementalUnavailableReason =
              journalSnapshot.complete
              ? "Быстрый повторный скан недоступен: непрерывный журнал ещё не создан. Выполните полный скан один раз."
              : "Быстрый повторный скан недоступен: macOS сообщила о потерянных событиях."
          } else if incrementalAllowed {
            statusMessage =
              "Large change set detected — using a faster clean Turbo scan…"
          }
        }
        // Keep this sorted once for the whole scan. Subtree reuse can then
        // check a directory with a binary search instead of walking every
        // FSEvents path for every directory on disk.
        let changedPaths = mode == .incremental ? journalSnapshot.paths.sorted() : []
        if mode == .incremental, changedPaths.isEmpty, let previous {
          currentScan = previous
          lastScanWasIncremental = true
          statusMessage = "Fast update complete — no filesystem changes were recorded."
          persistJournalBaseline(rootPath: rootPath, eventID: journalSnapshot.latestEventID)
          try await reloadResults()
          await loadRecentScans()
          isScanning = false
          return
        }
        let reuseCatalog: SubtreeReuseCatalog?
        if mode == .incremental, let previous {
          statusMessage = "Loading local update index…"
          reuseCatalog = try await store.makeReuseCatalog(scanID: previous.id)
        } else {
          reuseCatalog = nil
        }
        isPaused = false
        if mode == .full {
          let pendingOverview = Task.detached(priority: .userInitiated) {
            await FastOverviewScanner.scan(rootURL: url)
          }
          overviewTask = pendingOverview
          Task { [weak self] in
            let overview = await pendingOverview.value
            guard let self, self.isScanning, self.currentScan == nil else { return }
            self.applyFastOverview(overview, rootURL: url)
          }
        }

        statusMessage = "Preparing exact scan…"
        let rules = try await store.loadUserRules()
        userRules = rules
        let engine = RuleEngine(userRules: rules, allowProtectedOverrides: advancedRuleOverrides)
        let activeScanner = DiskScanner(ruleEngine: engine)
        scanner = activeScanner
        let record = try await store.beginScan(rootURL: url, intensity: intensity, mode: mode)
        currentScan = record
        isPreliminary = false
        currentParentID = 1
        navigationStack = []
        selectedItems = []
        let root = try DiskScanner.makeRootItem(scanID: record.id, id: 1, url: url, engine: engine)
        try await store.insert([root])
        let batchWriter = ScanBatchWriter(store: store)
        if mode == .full {
          items = []
          directoryItems = [root]
        }
        let liveRefreshGate = ScanLiveRefreshGate()

        let startingID: Int64
        if mode == .incremental, let previous {
          startingID = try await store.maximumItemID(scanID: previous.id) + 1
        } else {
          startingID = 2
        }
        let result = try await activeScanner.scan(
          scanID: record.id,
          rootItemID: 1,
          options: ScanOptions(
            rootURL: url, intensity: intensity, mode: mode, startingItemID: startingID),
          onBatch: { [weak self] batch, update in
            try await batchWriter.submit(batch)
            let liveItems: [ScannedItem]?
            if mode == .full, await liveRefreshGate.shouldRefresh() {
              liveItems = try await store.fetchChildren(
                scanID: record.id, parentID: 1, sort: .allocatedSize)
            } else {
              liveItems = nil
            }
            if mode == .full {
              Task { @MainActor [weak self] in
                self?.progress = update
                self?.statusMessage = self?.isPaused == true ? "Scan paused." : "Scanning…"
                guard self?.currentScan?.id == record.id else { return }
                guard let liveItems, self?.currentParentID == 1 else { return }
                self?.items = liveItems
                self?.directoryItems = [root] + liveItems.filter(\.kind.canHaveChildren)
              }
            }
          },
          onErrors: { [weak self] errors in
            try await store.insert(errors: errors)
            Task { @MainActor [weak self] in
              guard self?.currentScan?.id == record.id else { return }
              self?.scanErrors.append(contentsOf: errors)
            }
          },
          onProgress: { [weak self] update in
            // The core scan must never wait for a complex SwiftUI layout pass.
            // Updates are coalesced naturally by the main run loop.
            Task { @MainActor [weak self] in
              self?.progress = update
              if self?.isScanning == true {
                self?.statusMessage =
                  mode == .incremental ? "Applying filesystem changes…" : "Scanning…"
              }
            }
          },
          reuseCatalog: reuseCatalog,
          changedPaths: changedPaths
        )
        try await batchWriter.finish()
        statusMessage = "Finalizing scan…"
        // Commit the event boundary captured before traversal. Events that
        // arrive while scanning stay queued and are handled by the next fast
        // update instead of invalidating the complete on-disk index.
        let journalComplete = result.journalComplete && journalSnapshot.complete
        let finalResult = ScannerResult(
          progress: result.progress, cancelled: result.cancelled,
          bulkDirectoryCount: result.bulkDirectoryCount,
          fallbackDirectoryCount: result.fallbackDirectoryCount,
          maximumDepth: result.maximumDepth,
          reusedItemCount: result.reusedItemCount,
          reusedPaths: result.reusedPaths,
          journalComplete: journalComplete,
          directoryRollups: result.directoryRollups)
        if mode == .incremental, let previous, !finalResult.cancelled {
          currentScan = try await store.finishIncrementalOverlay(
            baseScanID: previous.id, overlayScanID: record.id, result: finalResult)
        } else {
          currentScan = try await store.finishScan(record.id, result: finalResult)
        }
        lastScanWasIncremental = mode == .incremental
        if !finalResult.cancelled && journalComplete {
          persistJournalBaseline(
            rootPath: rootPath, eventID: journalSnapshot.latestEventID)
        }
        statusMessage =
          finalResult.cancelled
          ? "Scan cancelled; partial results were kept."
          : mode == .incremental
            ? "Fast update complete — unchanged folders were reused."
            : "Scan complete."
        try await reloadResults()
        await loadRecentScans()
        if !finalResult.cancelled {
          scheduleHistoryMaintenance(rootPath: rootPath, store: store)
        }
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

  private func applyFastOverview(_ result: FastOverviewResult, rootURL: URL) {
    guard isScanning, currentScan == nil else { return }
    let engine = RuleEngine()
    let rootInfo = result.root
    let rootBytes =
      rootInfo?.allocatedBytes ?? result.children.reduce(0) { $0 &+ $1.allocatedBytes }
    let root = ScannedItem(
      id: 1, scanID: 0, parentID: nil, path: rootURL.path,
      name: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent,
      depth: 0, kind: .directory, fileExtension: nil,
      ownLogicalBytes: 0, ownAllocatedBytes: 0, accountedAllocatedBytes: rootBytes,
      logicalBytes: rootInfo?.logicalBytes ?? rootBytes, allocatedBytes: rootBytes,
      createdAt: nil, modifiedAt: nil, deviceID: 0, fileID: 0, linkCount: 1,
      isHidden: false, isPackage: false,
      classification: engine.classify(path: rootURL.path, kind: .directory))
    let children = result.children.enumerated().map { offset, entry in
      ScannedItem(
        id: -Int64(offset + 1), scanID: 0, parentID: 1, path: entry.path, name: entry.name,
        depth: 1, kind: entry.kind, fileExtension: nil,
        ownLogicalBytes: 0, ownAllocatedBytes: 0, accountedAllocatedBytes: entry.allocatedBytes,
        logicalBytes: entry.logicalBytes, allocatedBytes: entry.allocatedBytes,
        createdAt: nil, modifiedAt: nil, deviceID: 0, fileID: 0, linkCount: 1,
        isHidden: entry.name.hasPrefix("."), isPackage: entry.kind == .package,
        classification: Classification(
          status: .review, ruleID: nil,
          reason: "Preliminary top-level listing. The exact scan is still running.",
          confidence: .medium))
    }
    items = children
    directoryItems = [root] + children
    currentParentID = 1
    isPreliminary = true
    progress.logicalBytes = root.logicalBytes
    progress.allocatedBytes = root.allocatedBytes
    progress.inaccessible = result.inaccessibleCount
    statusMessage = "Quick overview ready — top-level sizes are partial; exact scan continues…"
  }

  private func saveSecurityScopedBookmark(for url: URL) {
    guard
      let data = try? url.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    else { return }
    var bookmarks =
      UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
    bookmarks[url.standardizedFileURL.path] = data
    UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
  }

  private func resolveSecurityScopedBookmark(for url: URL) -> URL? {
    let key = url.standardizedFileURL.path
    guard
      let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey)
        as? [String: Data],
      let data = bookmarks[key]
    else { return nil }
    var isStale = false
    guard
      let resolved = try? URL(
        resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
        bookmarkDataIsStale: &isStale)
    else { return nil }
    if isStale { saveSecurityScopedBookmark(for: resolved) }
    return resolved
  }

  private func persistJournalBaseline(
    rootPath: String, eventID: FSEventStreamEventId
  ) {
    journalBaselineIDs[rootPath] = eventID
    changeJournal.advanceBaseline(to: eventID)
    UserDefaults.standard.set(
      journalBaselineIDs.mapValues { NSNumber(value: $0) },
      forKey: journalDefaultsKey)
  }

  private func scheduleHistoryMaintenance(rootPath: String, store: ScanStore) {
    maintenanceTask?.cancel()
    maintenanceTask = Task { [weak self] in
      // A user commonly checks the result and immediately requests an update.
      // Keep retention out of that interaction window; WAL maintenance is idle work.
      try? await Task.sleep(for: .seconds(60))
      guard !Task.isCancelled, let self, !self.isScanning else { return }
      try? await store.pruneCompletedHistoryInBackground(rootPath: rootPath)
      guard !Task.isCancelled else { return }
      await self.loadRecentScans()
      self.maintenanceTask = nil
    }
  }

  func togglePause() {
    guard let scanner else { return }
    isPaused.toggle()
    statusMessage = isPaused ? "Scan paused." : "Scanning…"
    Task { if isPaused { await scanner.control.pause() } else { await scanner.control.resume() } }
  }

  func cancelScan() {
    guard isScanning else { return }
    statusMessage = "Cancelling…"
    overviewTask?.cancel()
    scanTask?.cancel()
    if let scanner {
      Task { await scanner.control.cancel() }
    }
  }

  func selectScan(_ scan: ScanRecord) {
    guard !isScanning, currentScan?.id != scan.id else { return }
    currentScan = scan
    showingLargestItems = false
    currentParentID = 1
    navigationStack = []
    selectedItems = []
    scanErrors = []
    loadedDirectoryIDs.removeAll(keepingCapacity: true)
    Task { try? await reloadResults() }
  }

  func requestDeleteHistory(_ scan: ScanRecord) { pendingHistoryDeletion = scan }

  func presentScanErrors() {
    guard currentScan != nil else { return }
    showScanErrors = true
    guard !isScanning, let store, let scanID = currentScan?.id else { return }
    isLoadingScanErrors = true
    Task {
      defer { isLoadingScanErrors = false }
      do {
        let loaded = try await store.errors(scanID: scanID)
        guard currentScan?.id == scanID else { return }
        scanErrors = loaded
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func revealParent(of error: ScanErrorRecord) {
    var url = URL(fileURLWithPath: error.path)
    if !FileManager.default.fileExists(atPath: error.path) {
      url.deleteLastPathComponent()
    }
    while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
      url.deleteLastPathComponent()
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

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
          selectedItems = []
        }
        await loadRecentScans()
        statusMessage = "Scan snapshot removed. Files on disk were not changed."
      } catch { errorMessage = error.localizedDescription }
    }
  }

  func reloadResults() async throws {
    guard let store, let scanID = currentScan?.id else { return }
    resultsReloadGeneration &+= 1
    let generation = resultsReloadGeneration
    isLoadingResults = true
    defer {
      if resultsReloadGeneration == generation { isLoadingResults = false }
    }
    let parent = currentParentID ?? 1
    let requestedFilter = filter
    let requestedSort = sort
    let requestedLargestItems = showingLargestItems
    let loadedItems: [ScannedItem]
    if requestedLargestItems {
      loadedItems = try await store.fetchLargest(
        scanID: scanID, containers: false, filter: requestedFilter, sort: requestedSort, limit: 2_000)
    } else {
      loadedItems = try await store.fetchChildren(
        scanID: scanID, parentID: parent, filter: requestedFilter, sort: requestedSort)
    }
    guard resultsRequestIsCurrent(
      generation: generation, scanID: scanID, parentID: parent,
      filter: requestedFilter, sort: requestedSort, showingLargestItems: requestedLargestItems
    ) else { return }
    if items != loadedItems { items = loadedItems }
    if !requestedLargestItems && (directoryItems.isEmpty || parent == 1) {
      // Do not decode thousands of directory rows just to open the last snapshot.
      // The outline starts with the root and its immediate children; deeper
      // branches are reached through the table and are loaded on demand.
      let loadedDirectories: [ScannedItem]
      if let root = try await store.fetchItem(scanID: scanID, itemID: 1) {
        let topLevel = try await store.fetchChildren(
          scanID: scanID, parentID: 1, sort: .allocatedSize, limit: 2_000)
        loadedDirectories = [root] + topLevel.filter(\.kind.canHaveChildren)
        loadedDirectoryIDs.insert(root.id)
      } else {
        loadedDirectories = []
      }
      guard resultsRequestIsCurrent(
        generation: generation, scanID: scanID, parentID: parent,
        filter: requestedFilter, sort: requestedSort, showingLargestItems: requestedLargestItems
      ) else { return }
      if directoryItems != loadedDirectories { directoryItems = loadedDirectories }
    }
    if !selectedItems.isEmpty {
      let loadedByID = Dictionary(uniqueKeysWithValues: loadedItems.map { ($0.id, $0) })
      let refreshedSelection = selectedItems.compactMap { loadedByID[$0.id] }
      if refreshedSelection != selectedItems { selectedItems = refreshedSelection }
    }
  }

  func applyFilter() { Task { try? await reloadResults() } }

  /// NSOutlineView asks for children only when a row is expanded. This keeps
  /// startup and steady-state memory bounded even for a root with hundreds of
  /// thousands of directories.
  func loadDirectoryChildren(_ item: ScannedItem) {
    guard !isPreliminary, item.kind.canHaveChildren, item.scanID > 0,
      let store, loadedDirectoryIDs.insert(item.id).inserted
    else { return }
    Task {
      do {
        let children = try await store.fetchChildren(
          scanID: item.scanID, parentID: item.id, sort: .allocatedSize, limit: 2_000
        )
        .filter(\.kind.canHaveChildren)
        let existingIDs = Set(directoryItems.map(\.id))
        directoryItems.append(contentsOf: children.filter { !existingIDs.contains($0.id) })
      } catch {
        loadedDirectoryIDs.remove(item.id)
        errorMessage = error.localizedDescription
      }
    }
  }

  func showLargestItems() {
    guard currentScan != nil, !isScanning else { return }
    showingLargestItems = true
    currentParentID = 1
    navigationStack = []
    selectedItems = []
    items = []
    isLoadingResults = true
    statusMessage = "Showing the largest files in this scan."
    Task { try? await reloadResults() }
  }

  func navigate(into item: ScannedItem) {
    showingLargestItems = false
    guard item.kind.canHaveChildren else {
      selectedItems = [item]
      return
    }
    navigationStack.append(item)
    currentParentID = item.id
    selectedItems = []
    items = []
    isLoadingResults = true
    Task { try? await reloadResults() }
  }

  func navigateFromTree(_ item: ScannedItem) {
    showingLargestItems = false
    guard currentParentID != item.id else {
      if selectedItems != [item] { selectedItems = [item] }
      if items.isEmpty {
        isLoadingResults = true
        Task { try? await reloadResults() }
      }
      return
    }
    currentParentID = item.id
    navigationStack = [item]
    selectedItems = [item]
    items = []
    isLoadingResults = true
    Task { try? await reloadResults() }
  }

  func selectItem(_ item: ScannedItem?) {
    selectItems(item.map { [$0] } ?? [])
  }

  func selectItems(_ items: [ScannedItem]) {
    if selectedItems != items { selectedItems = items }
  }

  func navigateBack() {
    if !navigationStack.isEmpty { navigationStack.removeLast() }
    currentParentID = navigationStack.last?.id ?? 1
    selectedItems = []
    items = []
    isLoadingResults = true
    Task { try? await reloadResults() }
  }

  private func resultsRequestIsCurrent(
    generation: UInt64,
    scanID: Int64,
    parentID: Int64,
    filter requestedFilter: ItemFilter,
    sort requestedSort: ItemSort,
    showingLargestItems requestedLargestItems: Bool
  ) -> Bool {
    resultsReloadGeneration == generation
      && currentScan?.id == scanID
      && (currentParentID ?? 1) == parentID
      && filter == requestedFilter
      && sort.rawValue == requestedSort.rawValue
      && showingLargestItems == requestedLargestItems
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

  func requestTrash(_ item: ScannedItem) { requestTrash([item]) }

  func requestTrash(_ requestedItems: [ScannedItem]) {
    var seen = Set<Int64>()
    let uniqueItems = requestedItems.filter { seen.insert($0.id).inserted }
    guard !uniqueItems.isEmpty else { return }

    var needsRiskConfirmation = false
    for item in uniqueItems {
      switch FileActionPolicy.trashAuthorization(for: item, strictMode: strictDeletion) {
      case .allowed:
        break
      case .requiresRiskConfirmation:
        needsRiskConfirmation = true
      case .blocked(let reason):
        errorMessage = uniqueItems.count == 1 ? reason : "\(item.name): \(reason)"
        return
      }
    }
    pendingTrashNeedsRiskConfirmation = needsRiskConfirmation
    pendingTrashItems = uniqueItems
  }

  func confirmTrash() {
    let requestedItems = pendingTrashItems
    guard !requestedItems.isEmpty, let store, let scanID = currentScan?.id else { return }
    pendingTrashItems = []
    Task {
      var trashedIDs: [Int64] = []
      var failures: [String] = []
      for item in requestedItems {
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
          trashedIDs.append(item.id)
        } catch {
          try? await store.recordCleanupAction(
            scanID: scanID, item: item, outcome: "failed", message: error.localizedDescription)
          failures.append("\(item.name): \(error.localizedDescription)")
        }
      }
      if !trashedIDs.isEmpty {
        do {
          try await store.markTrashed(scanID: scanID, itemIDs: trashedIDs)
        } catch {
          failures.append("Could not update the scan snapshot: \(error.localizedDescription)")
        }
      }
      selectedItems.removeAll { trashedIDs.contains($0.id) }
      if let refreshedScan = try? await store.fetchScan(scanID), currentScan?.id == scanID {
        currentScan = refreshedScan
      }
      if failures.isEmpty {
        statusMessage = trashedIDs.count == 1
          ? "Moved one item to the Trash."
          : "Moved \(trashedIDs.count.formatted()) items to the Trash."
      } else {
        statusMessage = "Moved \(trashedIDs.count.formatted()) of \(requestedItems.count.formatted()) items to the Trash."
        errorMessage = failures.prefix(8).joined(separator: "\n")
      }
      do {
        try await reloadResults()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func cancelPendingTrash() {
    pendingTrashItems = []
    pendingTrashNeedsRiskConfirmation = false
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
    guard !isExporting, let store, let scanID = currentScan?.id else { return }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    switch format {
    case .json: panel.nameFieldStringValue = "opendisktree-scan.json"
    case .csv: panel.nameFieldStringValue = "opendisktree-scan.csv"
    case .sqlite: panel.nameFieldStringValue = "opendisktree-scan.sqlite"
    case .aiReport: panel.nameFieldStringValue = "ai-report.json"
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    isExporting = true
    exportProgress = ExportProgress(exportedItems: 0, bytesWritten: 0)
    statusMessage = "Exporting…"
    exportTask = Task {
      defer {
        isExporting = false
        exportTask = nil
      }
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
          await MainActor.run {
            self?.exportProgress = update
            self?.statusMessage = "Exported \(update.exportedItems) items…"
          }
        }
        statusMessage = "Export saved to \(url.lastPathComponent)."
      } catch is CancellationError {
        statusMessage = "Export cancelled."
      } catch {
        errorMessage = error.localizedDescription
        statusMessage = "Export failed."
      }
    }
  }

  func cancelExport() {
    guard isExporting else { return }
    statusMessage = "Cancelling export…"
    exportTask?.cancel()
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
    if let store {
      do {
        try await store.reconcileInterruptedCleanupActions()
      } catch {
        errorMessage = "Could not finish a previous Trash update: \(error.localizedDescription)"
      }
      userRules = (try? await store.loadUserRules()) ?? []
    }
    await loadRecentScans()
  }

  private func loadRecentScans() async {
    guard let store else { return }
    do {
      recentScans = try await store.recentScans()
      // A process can be terminated while SQLite is preparing a scan, leaving
      // a running record with no items. Never select that incomplete record on
      // launch; keep the last usable snapshot visible instead.
      if currentScan == nil, let first = recentScans.first(where: { $0.state != .running }) {
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
