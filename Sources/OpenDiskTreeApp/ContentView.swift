import OpenDiskTreeCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel
  @State private var privacy = PrivacyMode.basic
  @State private var showFilters = false

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
    } detail: {
      VStack(spacing: 0) {
        toolbar
        Divider()
        if model.currentScan == nil && !model.isScanning {
          welcome
        } else {
          mainResults
        }
        Divider()
        statusBar
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .alert(
      "OpenDiskTree",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .confirmationDialog(
      model.pendingTrashNeedsRiskConfirmation
        ? "This item is not classified as safe" : "Move this item to the Trash?",
      isPresented: Binding(
        get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
      titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) { model.confirmTrash() }
      Button("Cancel", role: .cancel) { model.pendingTrash = nil }
    } message: {
      if let item = model.pendingTrash {
        Text("\(item.path)\n\n\(item.classification.reason)")
      }
    }
    .confirmationDialog(
      "Remove this scan snapshot?",
      isPresented: Binding(
        get: { model.pendingHistoryDeletion != nil },
        set: { if !$0 { model.pendingHistoryDeletion = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Snapshot", role: .destructive) { model.confirmDeleteHistory() }
      Button("Cancel", role: .cancel) { model.pendingHistoryDeletion = nil }
    } message: {
      Text("Only OpenDiskTree history is removed. Files on disk are not changed.")
    }
    .sheet(isPresented: $model.showRuleEditor) {
      RuleEditorView(rules: model.userRules, previewItems: model.items, onSave: model.saveRules)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(
        selection: Binding<Int64?>(
          get: { model.currentScan?.id },
          set: { id in
            if let scan = model.recentScans.first(where: { $0.id == id }) { model.selectScan(scan) }
          })
      ) {
        if model.isScanning {
          Section("Scanning") {
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                ProgressView().controlSize(.small)
                Text(model.isPaused ? "Paused" : (model.isPreliminary ? "Quick overview…" : "Reading disk…"))
                  .fontWeight(.medium)
              }
              Text(model.currentScan?.rootPath ?? model.progress.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Text(model.isPreliminary
                ? "\(max(0, model.directoryItems.count - 1).formatted()) top-level entries estimated"
                : "\((model.progress.files + model.progress.directories).formatted()) items found")
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
        }
        Section("History") {
          ForEach(model.recentScans) { scan in
            VStack(alignment: .leading, spacing: 2) {
              Text(
                URL(fileURLWithPath: scan.rootPath).lastPathComponent.isEmpty
                  ? scan.rootPath : URL(fileURLWithPath: scan.rootPath).lastPathComponent
              )
              .lineLimit(1)
              HStack {
                Text(HumanFormat.size(scan.allocatedBytes))
                Spacer()
                Text(scan.mode == .incremental ? String(localized: "scan.fastUpdate.short") : String(localized: "scan.full.short"))
                Text(scan.startedAt, style: .relative)
              }.font(.caption).foregroundStyle(.secondary)
            }
            .tag(scan.id)
            .contextMenu {
              Button("Remove Snapshot", role: .destructive) { model.requestDeleteHistory(scan) }
            }
          }
        }
      }
      Divider()
      VStack(spacing: 9) {
        Button(action: model.chooseFolder) {
          Label(String(localized: "scan.folder"), systemImage: "folder.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning)
        Button(action: model.scanFullDisk) {
          Label(String(localized: "scan.disk"), systemImage: "internaldrive")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(model.isScanning)
        Button("Full Disk Access…", action: model.openFullDiskAccessSettings)
          .font(.caption)
        Text("OpenDiskTree \(appVersion)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding()
    }
  }

  private var toolbar: some View {
    VStack(spacing: 9) {
      HStack(spacing: 10) {
        if model.currentScan != nil && model.currentParentID != 1 {
          Button(action: model.navigateBack) { Image(systemName: "chevron.left") }
            .help("Back")
        }
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
        Text(model.showingLargestItems
          ? "Largest files on disk"
          : (model.navigationStack.last?.path ?? model.currentScan?.rootPath ?? "OpenDiskTree"))
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
        if model.isScanning {
          Label(
            model.isPaused ? "Paused" : (model.isPreliminary ? "Quick overview" : "Scanning"),
            systemImage: model.isPaused ? "pause.fill" : (model.isPreliminary ? "bolt.fill" : "waveform.path")
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(model.isPaused ? .orange : (model.isPreliminary ? .purple : .blue))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background((model.isPaused ? Color.orange : (model.isPreliminary ? Color.purple : Color.blue)).opacity(0.12))
          .clipShape(Capsule())
        }
        Spacer(minLength: 12)
        if model.isScanning {
          Button(action: model.togglePause) {
            Label(
              String(localized: model.isPaused ? "scan.resume" : "scan.pause"),
              systemImage: model.isPaused ? "play.fill" : "pause.fill")
          }
          Button(role: .destructive, action: model.cancelScan) {
            Label(String(localized: "scan.cancel"), systemImage: "stop.fill")
          }
        } else {
          if model.isExporting {
            ProgressView().controlSize(.small)
            if let progress = model.exportProgress {
              Text("\(String(localized: "export.progress")) \(progress.exportedItems.formatted())")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(String(localized: "export.cancel"), action: model.cancelExport)
              .buttonStyle(.bordered)
          }
          Menu {
            Button("Scan Folder", action: model.chooseFolder)
            Button("Scan Full Disk", action: model.scanFullDisk)
            if model.currentScan != nil {
              Divider()
              Button(String(localized: "scan.fastUpdate"), action: { model.repeatCurrentScan(mode: .incremental) })
              Button(String(localized: "scan.fullRescan"), action: { model.repeatCurrentScan(mode: .full) })
            }
          } label: {
            Label("New scan", systemImage: "plus.magnifyingglass")
          }
          .help("Start a new scan")
          .menuStyle(.borderedButton)
          if let reason = model.incrementalUnavailableReason, !reason.isEmpty {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .help(reason)
          }
          Button(action: model.showLargestItems) {
            Label("Largest files", systemImage: "arrow.down.right.and.arrow.up.left")
          }
          .disabled(model.currentScan == nil)
          Button(action: model.findDuplicates) {
            Label("Duplicates", systemImage: "square.on.square")
          }
          .disabled(model.currentScan == nil || model.isFindingDuplicates)
          exportMenu
        }
      }
      HStack(spacing: 10) {
        TextField("Search name or path", text: $model.searchText)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 260, maxWidth: 520)
          .onSubmit(model.applyFilter)
        Button {
          showFilters.toggle()
        } label: {
          HStack(spacing: 6) {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            if model.activeFilterCount > 0 {
              Text(model.activeFilterCount.formatted())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
          }
        }
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
          FilterPanel(model: model)
        }
        Spacer()
        if model.currentScan != nil && !model.isScanning && !model.showingLargestItems {
          Text("Double-click a folder to open it")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Text("Size")
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("Sort", selection: $model.sort) {
          Text("On disk").tag(ItemSort.allocatedSize)
          Text("Logical").tag(ItemSort.logicalSize)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 190)
        .onChange(of: model.sort) { _, _ in model.applyFilter() }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var exportMenu: some View {
    Menu {
      Picker("Privacy", selection: $privacy) {
        Text("Full paths").tag(PrivacyMode.full)
        Text("Hide home and volume").tag(PrivacyMode.basic)
        Text("Strict pseudonyms").tag(PrivacyMode.strict)
      }
      Divider()
      Menu("Complete scan") { exportButtons(scope: .entireScan) }
      Menu("Current filter") { exportButtons(scope: .filtered(model.filter)) }
      if let item = model.selectedItem {
        Menu("Selected item") {
          exportButtons(scope: .selection(itemIDs: [item.id], includeDescendants: true))
        }
      }
    } label: {
      Label("Export", systemImage: "square.and.arrow.up")
    }
    .disabled(model.currentScan == nil || model.isScanning || model.isExporting)
  }

  @ViewBuilder
  private func exportButtons(scope: ExportScope) -> some View {
    Button("JSON") { model.export(format: .json, privacy: privacy, scope: scope) }
    Button("CSV") { model.export(format: .csv, privacy: privacy, scope: scope) }
    Button("SQLite") { model.export(format: .sqlite, privacy: privacy, scope: scope) }
    Button("Compact AI report") { model.export(format: .aiReport, privacy: privacy, scope: scope) }
  }

  private var mainResults: some View {
    HSplitView {
      DirectoryOutlineView(
        items: model.directoryItems, selectedID: model.currentParentID,
        isScanning: model.isScanning,
        onSelect: model.navigateFromTree,
        onExpand: model.loadDirectoryChildren
      )
      .frame(minWidth: 150, idealWidth: 185, maxWidth: 235, maxHeight: .infinity)
      VSplitView {
        ResultsTableView(
          items: model.items,
          selectedID: model.selectedItem?.id,
          isScanning: model.isScanning,
          onSelect: model.selectItem,
          onOpen: { $0.kind.canHaveChildren ? model.navigate(into: $0) : model.reveal($0) },
          onReveal: model.reveal,
          onTrash: model.requestTrash
        )
        .frame(minWidth: 400, minHeight: 260, idealHeight: 390, maxHeight: .infinity)
        TreemapView(
          items: model.items,
          selectedID: model.selectedItem?.id,
          isScanning: model.isScanning,
          onSelect: model.selectItem,
          onOpen: { $0.kind.canHaveChildren ? model.navigate(into: $0) : model.reveal($0) }
        )
        .frame(minHeight: 180, idealHeight: 240, maxHeight: .infinity)
        .padding(8)
      }
      .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
      InspectorView(
        item: model.selectedItem, onReveal: model.reveal, onTrash: model.requestTrash,
        onOpenSourceApp: model.openSourceApplication
      )
      .frame(minWidth: 220, idealWidth: 245, maxWidth: 285, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var statusBar: some View {
    if model.isScanning {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let elapsed = max(1, context.date.timeIntervalSince(model.progress.startedAt))
        let itemCount = model.progress.files + model.progress.directories
        let itemsPerSecond = Int64(Double(itemCount) / elapsed)
        VStack(spacing: 3) {
          HStack(spacing: 14) {
            if model.isPaused {
              Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            } else {
              ProgressView().controlSize(.small)
            }
            if model.isPreliminary {
              Label("\(model.items.count.formatted()) top-level entries", systemImage: "folder")
                .foregroundStyle(.purple)
            } else {
              Label("\(model.progress.files.formatted()) files", systemImage: "doc")
              Label("\(model.progress.directories.formatted()) folders", systemImage: "folder")
            }
            Label(HumanFormat.size(model.progress.allocatedBytes), systemImage: "internaldrive")
            Text(model.isPreliminary ? "estimated" : "\(itemsPerSecond.formatted()) items/s")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Text(HumanFormat.duration(elapsed))
              .monospacedDigit()
              .foregroundStyle(.secondary)
            if model.progress.inaccessible > 0 {
              Label(
                "\(model.progress.inaccessible.formatted()) inaccessible",
                systemImage: "exclamationmark.triangle"
              )
              .foregroundStyle(.orange)
            }
            Spacer()
            Text(model.statusMessage).foregroundStyle(.secondary)
          }
          HStack(spacing: 6) {
            Image(systemName: "location")
              .foregroundStyle(.tertiary)
            Text(model.progress.currentPath)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(.secondary)
            Spacer()
          }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 48)
      }
    } else {
      HStack(spacing: 12) {
        if let scan = model.currentScan {
          Label("\(scan.itemCount.formatted()) items", systemImage: "doc.on.doc")
          Label(HumanFormat.size(scan.allocatedBytes), systemImage: "internaldrive")
          if scan.inaccessibleCount > 0 {
            Label("\(scan.inaccessibleCount) inaccessible", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
        Text(model.statusMessage)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "info.circle")
          .foregroundStyle(.tertiary)
          .help("Logical and allocated sizes may differ on APFS.")
      }
      .font(.caption)
      .padding(.horizontal, 12)
      .frame(height: 34)
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }

  private var welcome: some View {
    ContentUnavailableView {
      Label("See what is using your disk", systemImage: "internaldrive")
    } description: {
      Text("Choose a folder for a quick scan, or grant Full Disk Access and scan the whole Mac.")
    } actions: {
      Button(String(localized: "scan.folder"), action: model.chooseFolder).buttonStyle(
        .borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Picker(
        "Scan intensity",
        selection: Binding(get: { model.intensity }, set: { model.intensity = $0 })
      ) {
        Text("Balanced").tag(ScanIntensity.balanced)
        Text("Turbo").tag(ScanIntensity.turbo)
      }
      Toggle("Strict cleanup restrictions", isOn: $model.strictDeletion)
      Text(
        "Turning this off allows a risk-confirmed Trash action for any accessible item. Permanent deletion is never available."
      )
      .font(.caption).foregroundStyle(.secondary)
      Toggle("Allow user rules to override protected rules", isOn: $model.advancedRuleOverrides)
      Text(
        "Advanced overrides are applied only to future scans and are always marked as user-defined."
      )
      .font(.caption).foregroundStyle(.orange)
      Button("Edit cleanup rules…") { model.showRuleEditor = true }
      Section("AI report defaults") {
        Stepper(
          "Top files: \(model.aiTopFiles)", value: $model.aiTopFiles, in: 50...5_000, step: 50)
        Stepper(
          "Top folders: \(model.aiTopDirectories)", value: $model.aiTopDirectories, in: 25...2_000,
          step: 25)
        Stepper(
          "Aggregate depth: \(model.aiAggregateDepth)", value: $model.aiAggregateDepth, in: 1...12)
      }
    }.padding(24)
  }
}

private struct FilterPanel: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Filters").font(.headline)
          Text("Narrow the current folder without rescanning.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.activeFilterCount > 0 {
          Text("\(model.activeFilterCount.formatted()) active")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(18)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          filterSection("Statuses") {
            VStack(alignment: .leading, spacing: 9) {
              ForEach(SafetyStatus.allCases, id: \.self) { status in
                Toggle(
                  isOn: Binding(
                    get: { model.selectedStatuses.contains(status) },
                    set: { enabled in
                      if enabled {
                        model.selectedStatuses.insert(status)
                      } else {
                        model.selectedStatuses.remove(status)
                      }
                    })
                ) {
                  HStack(spacing: 8) {
                    Image(systemName: status.symbol)
                      .foregroundStyle(status.color)
                      .frame(width: 16)
                    Text(status.localizedTitle)
                  }
                }
                .toggleStyle(.checkbox)
              }
            }
          }

          filterSection("File type") {
            VStack(alignment: .leading, spacing: 6) {
              Text("Extensions, comma-separated")
                .font(.caption)
                .foregroundStyle(.secondary)
              TextField("zip, dmg, mov", text: $model.extensionFilter)
                .textFieldStyle(.roundedBorder)
            }
          }

          filterSection("Size on disk") {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 5) {
                Text("Minimum (MB)").font(.caption).foregroundStyle(.secondary)
                TextField("0", text: $model.minimumSizeMB)
                  .textFieldStyle(.roundedBorder)
              }
              VStack(alignment: .leading, spacing: 5) {
                Text("Maximum (MB)").font(.caption).foregroundStyle(.secondary)
                TextField("Any", text: $model.maximumSizeMB)
                  .textFieldStyle(.roundedBorder)
              }
            }
          }

          filterSection("Other") {
            VStack(alignment: .leading, spacing: 10) {
              Toggle("Duplicates only", isOn: $model.duplicatesOnly)
                .toggleStyle(.checkbox)
              dateFilter(
                title: "Modified after", enabled: $model.useModifiedAfter,
                date: $model.modifiedAfter)
              dateFilter(
                title: "Modified before", enabled: $model.useModifiedBefore,
                date: $model.modifiedBefore)
            }
          }
        }
        .padding(18)
      }

      Divider()

      HStack {
        Button("Reset", action: reset)
          .disabled(model.activeFilterCount == 0)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Apply") {
          model.applyFilter()
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(width: 420, height: 590)
  }

  private func filterSection<Content: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func dateFilter(
    title: LocalizedStringKey,
    enabled: Binding<Bool>,
    date: Binding<Date>
  ) -> some View {
    HStack {
      Toggle(title, isOn: enabled)
        .toggleStyle(.checkbox)
      Spacer()
      if enabled.wrappedValue {
        DatePicker("", selection: date, displayedComponents: .date)
          .labelsHidden()
          .datePickerStyle(.field)
      }
    }
  }

  private func reset() {
    model.selectedStatuses = []
    model.extensionFilter = ""
    model.minimumSizeMB = ""
    model.maximumSizeMB = ""
    model.duplicatesOnly = false
    model.useModifiedAfter = false
    model.useModifiedBefore = false
    model.applyFilter()
  }
}
