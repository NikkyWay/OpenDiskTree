import OpenDiskTreeCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel
  @State private var privacy = PrivacyMode.basic
  @State private var tableHeight: CGFloat = 330
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
      VStack(spacing: 8) {
        Button(action: model.chooseFolder) {
          Label(String(localized: "scan.folder"), systemImage: "folder.badge.plus")
        }.buttonStyle(.borderedProminent)
        Button(action: model.scanFullDisk) {
          Label(String(localized: "scan.disk"), systemImage: "internaldrive")
        }
        Button("Full Disk Access…", action: model.openFullDiskAccessSettings).font(.caption)
      }.padding()
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      if model.currentScan != nil && model.currentParentID != 1 {
        Button(action: model.navigateBack) { Image(systemName: "chevron.left") }.help("Back")
      }
      Text(model.navigationStack.last?.path ?? model.currentScan?.rootPath ?? "OpenDiskTree")
        .font(.headline).lineLimit(1).truncationMode(.middle)
      Spacer()
      TextField("Search name or path", text: $model.searchText)
        .textFieldStyle(.roundedBorder).frame(width: 240)
        .onSubmit(model.applyFilter)
      Button {
        showFilters.toggle()
      } label: {
        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
      }
      .popover(isPresented: $showFilters, arrowEdge: .bottom) {
        FilterPanel(model: model).frame(width: 330).padding()
      }
      Picker("Sort", selection: $model.sort) {
        Text("On disk").tag(ItemSort.allocatedSize)
        Text("Logical").tag(ItemSort.logicalSize)
      }.frame(width: 110).onChange(of: model.sort) { _, _ in model.applyFilter() }
      if model.isScanning {
        Button(action: model.togglePause) {
          Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
        }
        Button(role: .destructive, action: model.cancelScan) { Image(systemName: "xmark") }
      } else {
        Button(action: model.findDuplicates) {
          Label("Duplicates", systemImage: "square.on.square")
        }
        .disabled(model.currentScan == nil || model.isFindingDuplicates)
      }
      exportMenu
    }.padding(10)
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
    .disabled(model.currentScan == nil || model.isScanning)
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
        onSelect: model.navigateFromTree
      )
      .frame(minWidth: 190, idealWidth: 240, maxWidth: 360)
      VSplitView {
        ResultsTableView(
          items: model.items,
          selectedID: model.selectedItem?.id,
          onSelect: model.selectItem,
          onOpen: { $0.kind.canHaveChildren ? model.navigate(into: $0) : model.reveal($0) },
          onReveal: model.reveal,
          onTrash: model.requestTrash
        ).frame(minHeight: 240, idealHeight: tableHeight)
        TreemapView(
          items: model.items,
          selectedID: model.selectedItem?.id,
          onSelect: model.selectItem,
          onOpen: { $0.kind.canHaveChildren ? model.navigate(into: $0) : model.reveal($0) }
        ).frame(minHeight: 180).padding(8)
      }
      InspectorView(
        item: model.selectedItem, onReveal: model.reveal, onTrash: model.requestTrash,
        onOpenSourceApp: model.openSourceApplication)
    }
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      if model.isScanning {
        ProgressView().controlSize(.small)
        Text(
          "\(model.progress.files.formatted()) files, \(model.progress.directories.formatted()) folders"
        )
        Text(HumanFormat.size(model.progress.allocatedBytes))
      } else if let scan = model.currentScan {
        Text("\(scan.itemCount.formatted()) items")
        Text(HumanFormat.size(scan.allocatedBytes))
        if scan.inaccessibleCount > 0 {
          Label("\(scan.inaccessibleCount) inaccessible", systemImage: "exclamationmark.triangle")
        }
      }
      Text(model.statusMessage).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
      Spacer()
      Text("Logical and allocated sizes may differ on APFS.").font(.caption).foregroundStyle(
        .tertiary)
    }.font(.caption).padding(.horizontal, 10).frame(height: 28)
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

  var body: some View {
    Form {
      Section("Statuses") {
        ForEach(SafetyStatus.allCases, id: \.self) { status in
          Toggle(
            status.localizedTitle,
            isOn: Binding(
              get: { model.selectedStatuses.contains(status) },
              set: { enabled in
                if enabled {
                  model.selectedStatuses.insert(status)
                } else {
                  model.selectedStatuses.remove(status)
                }
              }
            ))
        }
      }
      TextField("Extensions, comma-separated", text: $model.extensionFilter)
      HStack {
        TextField("Min MB", text: $model.minimumSizeMB)
        TextField("Max MB", text: $model.maximumSizeMB)
      }
      Toggle("Duplicates only", isOn: $model.duplicatesOnly)
      Toggle("Modified after", isOn: $model.useModifiedAfter)
      if model.useModifiedAfter {
        DatePicker("", selection: $model.modifiedAfter, displayedComponents: .date).labelsHidden()
      }
      Toggle("Modified before", isOn: $model.useModifiedBefore)
      if model.useModifiedBefore {
        DatePicker("", selection: $model.modifiedBefore, displayedComponents: .date).labelsHidden()
      }
      HStack {
        Button("Reset") {
          model.selectedStatuses = []
          model.extensionFilter = ""
          model.minimumSizeMB = ""
          model.maximumSizeMB = ""
          model.duplicatesOnly = false
          model.useModifiedAfter = false
          model.useModifiedBefore = false
          model.applyFilter()
        }
        Spacer()
        Button("Apply") { model.applyFilter() }.buttonStyle(.borderedProminent)
      }
    }
  }
}
