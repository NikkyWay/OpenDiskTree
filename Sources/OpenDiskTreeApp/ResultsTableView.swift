import AppKit
import OpenDiskTreeCore
import SwiftUI

struct ResultsTableView: NSViewRepresentable {
  let items: [ScannedItem]
  let selectedIDs: Set<Int64>
  let isScanning: Bool
  let onSelect: ([ScannedItem]) -> Void
  let onOpen: (ScannedItem) -> Void
  let onReveal: (ScannedItem) -> Void
  let onTrash: ([ScannedItem]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSScrollView {
    let table = NSTableView()
    table.usesAlternatingRowBackgroundColors = true
    table.allowsMultipleSelection = true
    table.rowHeight = 24
    table.intercellSpacing = NSSize(width: 8, height: 1)
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.doubleClick)

    let columns: [(String, String, CGFloat)] = [
      ("name", "Name", 260), ("status", "Status", 170), ("allocated", "On disk", 100),
      ("logical", "Logical", 100), ("modified", "Modified", 145), ("path", "Path", 360),
    ]
    for (id, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = id == "path" ? 180 : 80
      column.resizingMask = .autoresizingMask
      table.addTableColumn(column)
    }
    let menu = NSMenu()
    menu.addItem(
      withTitle: String(localized: "action.reveal"), action: #selector(Coordinator.reveal),
      keyEquivalent: "r")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: String(localized: "action.trash"), action: #selector(Coordinator.trash),
      keyEquivalent: "")
    for item in menu.items {
      item.target = context.coordinator
    }
    table.menu = menu

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table
    context.coordinator.table = table
    context.coordinator.renderedItems = items
    context.coordinator.renderedIsScanning = isScanning
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let itemsChanged = context.coordinator.renderedItems != items
    let scanStateChanged = context.coordinator.renderedIsScanning != isScanning
    context.coordinator.parent = self
    guard let table = scroll.documentView as? NSTableView else { return }
    context.coordinator.synchronize(
      table: table, reloadCells: itemsChanged || scanStateChanged)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: ResultsTableView
    weak var table: NSTableView?
    fileprivate var renderedItems: [ScannedItem] = []
    fileprivate var renderedIsScanning = false
    private var isSynchronizingSelection = false
    private let dateFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      return formatter
    }()

    init(parent: ResultsTableView) { self.parent = parent }
    func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

    fileprivate func synchronize(table: NSTableView, reloadCells: Bool) {
      isSynchronizingSelection = true
      defer { isSynchronizingSelection = false }
      if reloadCells {
        renderedItems = parent.items
        renderedIsScanning = parent.isScanning
        table.reloadData()
      }
      let desiredRows = IndexSet(
        parent.items.indices.filter { parent.selectedIDs.contains(parent.items[$0].id) })
      if !desiredRows.isEmpty {
        if table.selectedRowIndexes != desiredRows {
          table.selectRowIndexes(desiredRows, byExtendingSelection: false)
        }
      } else if !table.selectedRowIndexes.isEmpty {
        table.deselectAll(nil)
      }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard row < parent.items.count, let identifier = tableColumn?.identifier else { return nil }
      let item = parent.items[row]
      let cellID = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
      let cell =
        tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        ?? {
          let value = NSTableCellView()
          value.identifier = cellID
          let field = NSTextField(labelWithString: "")
          field.lineBreakMode = .byTruncatingMiddle
          field.translatesAutoresizingMaskIntoConstraints = false
          value.addSubview(field)
          value.textField = field
          NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: value.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: value.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: value.centerYAnchor),
          ])
          return value
        }()
      let text: String =
        switch identifier.rawValue {
        case "name": item.name
        case "status": item.classification.status.localizedTitle
        case "allocated":
          parent.isScanning && item.kind.canHaveChildren
            ? String(localized: "Calculating…") : HumanFormat.size(item.allocatedBytes)
        case "logical":
          parent.isScanning && item.kind.canHaveChildren
            ? String(localized: "Calculating…") : HumanFormat.size(item.logicalBytes)
        case "modified": item.modifiedAt.map(dateFormatter.string) ?? "—"
        case "path": item.path
        default: ""
        }
      cell.textField?.stringValue = text
      cell.textField?.toolTip = identifier.rawValue == "status" ? item.classification.reason : text
      if identifier.rawValue == "status" {
        cell.textField?.textColor = NSColor(item.classification.status.color)
      } else {
        cell.textField?.textColor = .labelColor
      }
      return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !isSynchronizingSelection else { return }
      guard let table else { return }
      let selection = table.selectedRowIndexes.compactMap { row in
        row < parent.items.count ? parent.items[row] : nil
      }
      if Set(selection.map(\.id)) != parent.selectedIDs { parent.onSelect(selection) }
    }

    @objc func doubleClick() {
      guard let item = selectedItem else { return }
      parent.onOpen(item)
    }

    @objc func reveal() { if let item = selectedItem { parent.onReveal(item) } }
    @objc func trash() {
      let items = contextualItems
      if !items.isEmpty { parent.onTrash(items) }
    }

    private var selectedItem: ScannedItem? {
      guard let row = table?.clickedRow ?? table?.selectedRow, row >= 0, row < parent.items.count
      else { return nil }
      return parent.items[row]
    }

    private var contextualItems: [ScannedItem] {
      guard let table else { return [] }
      let clickedRow = table.clickedRow
      if clickedRow >= 0, clickedRow < parent.items.count,
        !table.selectedRowIndexes.contains(clickedRow)
      {
        return [parent.items[clickedRow]]
      }
      return table.selectedRowIndexes.compactMap { row in
        row < parent.items.count ? parent.items[row] : nil
      }
    }
  }
}
