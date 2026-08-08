import AppKit
import OpenDiskTreeCore
import SwiftUI

struct DirectoryOutlineView: NSViewRepresentable {
  let items: [ScannedItem]
  let selectedID: Int64?
  let isScanning: Bool
  let onSelect: (ScannedItem) -> Void
  let onExpand: (ScannedItem) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSScrollView {
    let outline = NSOutlineView()
    outline.headerView = nil
    outline.rowHeight = 22
    outline.indentationPerLevel = 14
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
    column.title = "Folders"
    column.width = 230
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.delegate = context.coordinator
    outline.dataSource = context.coordinator
    outline.target = context.coordinator
    outline.doubleAction = #selector(Coordinator.activateSelection)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = outline
    context.coordinator.outline = outline
    context.coordinator.rebuild(items)
    context.coordinator.renderedItems = items
    context.coordinator.renderedIsScanning = isScanning
    DispatchQueue.main.async { outline.expandItem(nil, expandChildren: false) }
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let itemsChanged = context.coordinator.renderedItems != items
    let scanStateChanged = context.coordinator.renderedIsScanning != isScanning
    context.coordinator.parent = self
    guard let outline = scroll.documentView as? NSOutlineView else { return }
    context.coordinator.synchronize(
      outline: outline, rebuildItems: itemsChanged, reloadCells: itemsChanged || scanStateChanged)
  }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var parent: DirectoryOutlineView
    weak var outline: NSOutlineView?
    fileprivate var roots: [DirectoryNode] = []
    fileprivate var nodesByID: [Int64: DirectoryNode] = [:]
    fileprivate var renderedItems: [ScannedItem] = []
    fileprivate var renderedIsScanning = false
    private var isSynchronizingSelection = false

    init(parent: DirectoryOutlineView) { self.parent = parent }

    func rebuild(_ items: [ScannedItem]) {
      let ids = Set(items.map(\.id))
      nodesByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, DirectoryNode(item: $0)) })
      roots = []
      for item in items {
        guard let node = nodesByID[item.id] else { continue }
        if let parentID = item.parentID, ids.contains(parentID), let parent = nodesByID[parentID] {
          node.parent = parent
          parent.children.append(node)
        } else {
          roots.append(node)
        }
      }
      for node in nodesByID.values {
        node.children.sort {
          $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
        }
      }
    }

    fileprivate func synchronize(
      outline: NSOutlineView, rebuildItems: Bool, reloadCells: Bool
    ) {
      isSynchronizingSelection = true
      defer { isSynchronizingSelection = false }
      if rebuildItems {
        renderedItems = parent.items
        rebuild(parent.items)
      }
      if reloadCells {
        renderedIsScanning = parent.isScanning
        outline.reloadData()
      }
      guard let selectedID = parent.selectedID, let node = nodesByID[selectedID] else {
        if outline.selectedRow >= 0 { outline.deselectAll(nil) }
        return
      }
      var ancestor = node.parent
      while let current = ancestor {
        outline.expandItem(current)
        ancestor = current.parent
      }
      let row = outline.row(forItem: node)
      if row >= 0, outline.selectedRow != row {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      (item as? DirectoryNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      (item as? DirectoryNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
      (item as? DirectoryNode)?.item.kind.canHaveChildren == true
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
      guard let node = notification.userInfo?.values.compactMap({ $0 as? DirectoryNode }).first else {
        return
      }
      parent.onExpand(node.item)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
      -> NSView?
    {
      guard let node = item as? DirectoryNode else { return nil }
      let id = NSUserInterfaceItemIdentifier("directory-cell")
      let cell =
        outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        ?? {
          let cell = NSTableCellView()
          cell.identifier = id
          let image = NSImageView()
          image.image = NSImage(
            systemSymbolName: node.item.isPackage ? "shippingbox" : "folder",
            accessibilityDescription: nil)
          image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
          image.translatesAutoresizingMaskIntoConstraints = false
          let text = NSTextField(labelWithString: "")
          text.lineBreakMode = .byTruncatingMiddle
          text.translatesAutoresizingMaskIntoConstraints = false
          cell.addSubview(image)
          cell.addSubview(text)
          cell.textField = text
          cell.imageView = image
          NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          ])
          return cell
        }()
      cell.textField?.stringValue =
        parent.isScanning
        ? node.item.name
        : "\(node.item.name)  \(HumanFormat.size(node.item.allocatedBytes))"
      cell.textField?.toolTip = node.item.path
      return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !isSynchronizingSelection else { return }
      activateSelection()
    }

    @objc func activateSelection() {
      guard let row = outline?.selectedRow, row >= 0,
        let node = outline?.item(atRow: row) as? DirectoryNode
      else { return }
      if node.item.id != parent.selectedID { parent.onSelect(node.item) }
    }
  }
}

@MainActor
private final class DirectoryNode: NSObject {
  let item: ScannedItem
  weak var parent: DirectoryNode?
  var children: [DirectoryNode] = []
  init(item: ScannedItem) { self.item = item }
}
