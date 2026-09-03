import AppKit
import Darwin
import OpenDiskTreeCore
import SwiftUI

struct ScanErrorsView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var selectedID: Int?

  private struct Row: Identifiable {
    let id: Int
    let error: ScanErrorRecord
  }

  private var rows: [Row] {
    model.scanErrors.enumerated().compactMap { offset, error in
      guard searchText.isEmpty
        || error.path.localizedCaseInsensitiveContains(searchText)
        || error.message.localizedCaseInsensitiveContains(searchText)
        || String(error.code).contains(searchText)
      else { return nil }
      return Row(id: offset, error: error)
    }
  }

  private var selectedError: ScanErrorRecord? {
    guard let selectedID, model.scanErrors.indices.contains(selectedID) else { return nil }
    return model.scanErrors[selectedID]
  }

  private var likelyMissingFullDiskAccess: Bool {
    model.scanErrors.lazy.filter {
      $0.code == EPERM && $0.path.contains("/Library/")
    }.prefix(10).count == 10
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Label("Paths not scanned", systemImage: "exclamationmark.triangle.fill")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.orange)
          Spacer()
          Text(model.scanErrors.count.formatted())
            .font(.title3.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(
          "OpenDiskTree could not list these locations. The rest of the scan is valid, but folder totals below an inaccessible path may be incomplete."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        if likelyMissingFullDiskAccess {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
              .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
              Text("Full Disk Access is probably not active for this build.")
                .fontWeight(.semibold)
              Text(
                "Most failures are privacy-protected user data. Enable the installed /Applications/OpenDiskTree.app, quit and reopen it, then run a full rescan."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings…", action: model.openFullDiskAccessSettings)
          }
          .padding(10)
          .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
        TextField("Search path, reason or error code", text: $searchText)
          .textFieldStyle(.roundedBorder)
      }
      .padding(16)

      Divider()

      if model.isLoadingScanErrors && model.scanErrors.isEmpty {
        ProgressView("Loading errors…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if rows.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No inaccessible paths" : "No matching paths",
          systemImage: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
      } else {
        List(rows, selection: $selectedID) { row in
          VStack(alignment: .leading, spacing: 5) {
            Text(row.error.path)
              .font(.body.monospaced())
              .lineLimit(2)
              .truncationMode(.middle)
            HStack(spacing: 8) {
              Text("Error \(row.error.code)")
                .font(.caption.monospacedDigit().weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: Capsule())
              Text(row.error.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .padding(.vertical, 4)
          .tag(row.id)
          .contextMenu {
            Button("Copy path") { copy(row.error.path) }
            Button("Show parent in Finder") { model.revealParent(of: row.error) }
          }
        }
        .listStyle(.inset)
      }

      Divider()

      HStack(spacing: 10) {
        Button("Copy all") {
          copy(
            model.scanErrors.map { "\($0.path)\t\($0.code)\t\($0.message)" }
              .joined(separator: "\n"))
        }
        .disabled(model.scanErrors.isEmpty)
        Button("Copy path") {
          if let selectedError { copy(selectedError.path) }
        }
        .disabled(selectedError == nil)
        Button("Show parent in Finder") {
          if let selectedError { model.revealParent(of: selectedError) }
        }
        .disabled(selectedError == nil)
        Spacer()
        Button("Done", action: dismiss.callAsFunction)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(minWidth: 720, idealWidth: 860, minHeight: 460, idealHeight: 600)
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
