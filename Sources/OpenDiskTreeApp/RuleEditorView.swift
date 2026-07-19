import AppKit
import OpenDiskTreeCore
import SwiftUI
import UniformTypeIdentifiers

struct RuleEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var rules: [CleanupRule]
  @State private var selectedID: String?
  let previewItems: [ScannedItem]
  let onSave: ([CleanupRule]) -> Void

  init(rules: [CleanupRule], previewItems: [ScannedItem], onSave: @escaping ([CleanupRule]) -> Void)
  {
    _rules = State(initialValue: rules)
    self.previewItems = previewItems
    self.onSave = onSave
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedID) {
        ForEach(rules) { rule in
          VStack(alignment: .leading) {
            Text(rule.title)
            Text(rule.status.localizedTitle).font(.caption).foregroundStyle(rule.status.color)
          }.tag(rule.id)
        }
        .onDelete { rules.remove(atOffsets: $0) }
      }
      .toolbar {
        Button {
          addRule()
        } label: {
          Label("Add rule", systemImage: "plus")
        }
      }
    } detail: {
      if let index = rules.firstIndex(where: { $0.id == selectedID }) {
        Form {
          TextField("Title", text: $rules[index].title)
          TextField("Path pattern", text: $rules[index].pattern)
          Picker("Match", selection: $rules[index].matchKind) {
            ForEach([RuleMatchKind.prefix, .contains, .suffix, .glob], id: \.self) {
              Text($0.rawValue).tag($0)
            }
          }
          Picker("Status", selection: $rules[index].status) {
            ForEach(SafetyStatus.allCases.filter { $0 != .mixed }, id: \.self) {
              Text($0.localizedTitle).tag($0)
            }
          }
          TextField("Reason shown to the user", text: $rules[index].reason, axis: .vertical)
          Toggle("Enabled", isOn: $rules[index].isEnabled)
          Text(
            "User rules override matching built-in rules. Marking a protected path safe can cause data loss."
          )
          .font(.caption).foregroundStyle(.orange)
          let matches = RuleEngine().matchingItems(for: rules[index], in: previewItems)
          Section("Preview — \(matches.count) matches in the current view") {
            ForEach(matches.prefix(10)) { item in
              Text(item.path).font(.caption).lineLimit(1).truncationMode(.middle)
            }
          }
        }.padding()
      } else {
        ContentUnavailableView("Select a rule", systemImage: "checklist")
      }
    }
    .frame(minWidth: 760, minHeight: 480)
    .toolbar {
      ToolbarItem {
        Menu("Transfer") {
          Button("Import JSON…", action: importRules)
          Button("Export JSON…", action: exportRules)
        }
      }
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          onSave(rules)
          dismiss()
        }
      }
    }
  }

  private func addRule() {
    let rule = CleanupRule(
      id: "user.\(UUID().uuidString.lowercased())", title: "New rule", priority: 1_000,
      pattern: "~/", matchKind: .prefix, status: .review,
      reason: "User-defined rule.", isUserRule: true
    )
    rules.append(rule)
    selectedID = rule.id
  }

  private func importRules() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url,
      let data = try? Data(contentsOf: url),
      let document = try? JSONDecoder().decode(RuleDocument.self, from: data),
      document.schemaVersion == 1
    else { return }
    rules = document.rules.map { value in
      var rule = value
      rule.isUserRule = true
      return rule
    }
    selectedID = rules.first?.id
  }

  private func exportRules() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "opendisktree-rules.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(RuleDocument(rules: rules)) {
      try? data.write(to: url, options: .atomic)
    }
  }
}
