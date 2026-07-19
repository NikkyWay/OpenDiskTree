import OpenDiskTreeCore
import SwiftUI

struct InspectorView: View {
  let item: ScannedItem?
  let onReveal: (ScannedItem) -> Void
  let onTrash: (ScannedItem) -> Void
  let onOpenSourceApp: (ScannedItem) -> Void

  var body: some View {
    Group {
      if let item {
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
              onTrash(item)
            } label: {
              Label(String(localized: "action.trash"), systemImage: "trash")
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
    .frame(minWidth: 240, idealWidth: 280)
  }
}
