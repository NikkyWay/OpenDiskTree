import OpenDiskTreeCore
import SwiftUI

struct InspectorView: View {
  let items: [ScannedItem]
  let onReveal: (ScannedItem) -> Void
  let onTrash: ([ScannedItem]) -> Void
  let onOpenSourceApp: (ScannedItem) -> Void

  var body: some View {
    Group {
      if items.count == 1, let item = items.first {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Label(
              item.classification.status.localizedTitle,
              systemImage: item.classification.status.symbol
            )
            .font(.headline)
            .foregroundStyle(item.classification.status.color)
            Text(item.name).font(.title3).textSelection(.enabled)
            Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            LabeledContent("On disk", value: HumanFormat.size(item.allocatedBytes))
            LabeledContent("Logical", value: HumanFormat.size(item.logicalBytes))
            if item.linkCount > 1 { LabeledContent("Hard links", value: String(item.linkCount)) }
            Text(item.classification.reason).font(.callout)
            if let rule = item.classification.ruleID { LabeledContent("Rule", value: rule) }
            if let app = item.classification.sourceApplication {
              LabeledContent("Managed by", value: app)
              Button("Open \(app)") { onOpenSourceApp(item) }
            }
            Divider()
            Button {
              onReveal(item)
            } label: {
              Label(String(localized: "action.reveal"), systemImage: "finder")
            }
            Button(role: .destructive) {
              onTrash(items)
            } label: {
              Label(String(localized: "action.trash"), systemImage: "trash")
            }
          }
          .padding()
        }
      } else if !items.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Label("\(items.count.formatted()) items selected", systemImage: "checkmark.circle")
              .font(.headline)
            LabeledContent("On disk", value: HumanFormat.size(totalAllocatedBytes))
            LabeledContent("Logical", value: HumanFormat.size(totalLogicalBytes))
            Divider()
            ForEach(statusCounts, id: \.status) { entry in
              HStack {
                Label(entry.status.localizedTitle, systemImage: entry.status.symbol)
                  .foregroundStyle(entry.status.color)
                Spacer()
                Text(entry.count.formatted()).monospacedDigit()
              }
            }
            Divider()
            Button(role: .destructive) {
              onTrash(items)
            } label: {
              Label("Move selected to Trash", systemImage: "trash")
            }
          }
          .padding()
        }
      } else {
        ContentUnavailableView(
          "No selection", systemImage: "cursorarrow.click",
          description: Text("Select a file or folder to inspect it."))
      }
    }
    .frame(minWidth: 220, idealWidth: 250)
  }

  private var totalAllocatedBytes: UInt64 {
    items.reduce(0) { $0 &+ $1.allocatedBytes }
  }

  private var totalLogicalBytes: UInt64 {
    items.reduce(0) { $0 &+ $1.logicalBytes }
  }

  private var statusCounts: [(status: SafetyStatus, count: Int)] {
    Dictionary(grouping: items, by: \.classification.status)
      .map { (status: $0.key, count: $0.value.count) }
      .sorted { $0.status.riskRank > $1.status.riskRank }
  }
}
