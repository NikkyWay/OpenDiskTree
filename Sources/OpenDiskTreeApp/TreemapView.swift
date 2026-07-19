import OpenDiskTreeCore
import SwiftUI

struct TreemapView: View {
  let items: [ScannedItem]
  let selectedID: Int64?
  let isScanning: Bool
  let onSelect: (ScannedItem) -> Void
  let onOpen: (ScannedItem) -> Void

  var body: some View {
    GeometryReader { geometry in
      let visible = Array(items.filter { $0.allocatedBytes > 0 }.prefix(500))
      let tiles = TreemapLayout.layout(
        items: visible, in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 2, dy: 2))
      ZStack {
        Canvas { context, _ in
          for tile in tiles {
            let status = tile.item.classification.status
            let selected = tile.item.id == selectedID
            context.fill(
              Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
              with: .color(status.color.opacity(selected ? 0.95 : 0.62)))
            if selected {
              context.stroke(
                Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
                with: .color(.primary), lineWidth: 2)
            }
            if tile.rect.width > 74, tile.rect.height > 34 {
              context.draw(
                Text(tile.item.name).font(.caption2).foregroundStyle(.primary),
                in: tile.rect.insetBy(dx: 5, dy: 4))
            }
          }
        }
        .contentShape(Rectangle())
        .gesture(
          SpatialTapGesture(count: 1).onEnded { event in
            if let tile = tiles.last(where: { $0.rect.contains(event.location) }) {
              onSelect(tile.item)
            }
          }
        )
        .simultaneousGesture(
          SpatialTapGesture(count: 2).onEnded { event in
            if let tile = tiles.last(where: { $0.rect.contains(event.location) }) {
              onOpen(tile.item)
            }
          }
        )
        .accessibilityLabel("Disk treemap")
        if tiles.isEmpty {
          VStack(spacing: 8) {
            if isScanning { ProgressView().controlSize(.small) }
            Image(systemName: isScanning ? "square.3.layers.3d.down.right" : "rectangle.3.group")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text(isScanning ? "Building treemap…" : "No sized items")
              .font(.headline)
            Text(
              isScanning
                ? "Folder totals are calculated when the scan finishes."
                : "This folder has no items with an allocated size."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          }
          .padding()
        }
      }
    }
    .background(.quaternary.opacity(0.3))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct TreemapTile {
  let item: ScannedItem
  let rect: CGRect
}

private enum TreemapLayout {
  static func layout(items: [ScannedItem], in bounds: CGRect) -> [TreemapTile] {
    let sorted = items.sorted { $0.allocatedBytes > $1.allocatedBytes }
    let total = Double(sorted.reduce(UInt64(0)) { $0 &+ $1.allocatedBytes })
    guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
    var remaining = bounds
    var output: [TreemapTile] = []
    var index = 0
    while index < sorted.count, remaining.width > 1, remaining.height > 1 {
      let horizontal = remaining.width >= remaining.height
      let availableArea = remaining.width * remaining.height
      var row: [ScannedItem] = []
      var rowArea: CGFloat = 0
      let shortSide = horizontal ? remaining.height : remaining.width
      var best = CGFloat.greatestFiniteMagnitude
      while index < sorted.count {
        let item = sorted[index]
        let itemArea = CGFloat(Double(item.allocatedBytes) / total) * bounds.width * bounds.height
        let candidate = row + [item]
        let candidateArea = rowArea + itemArea
        let score = worstAspect(
          candidate, totalArea: candidateArea, side: shortSide, totalBytes: total,
          boundsArea: bounds.width * bounds.height)
        if !row.isEmpty && score > best { break }
        row = candidate
        rowArea = candidateArea
        best = score
        index += 1
      }
      guard !row.isEmpty, rowArea > 0 else { break }
      if horizontal {
        let width = min(remaining.width, rowArea / remaining.height)
        var y = remaining.minY
        for item in row {
          let area = CGFloat(Double(item.allocatedBytes) / total) * bounds.width * bounds.height
          let height = area / width
          output.append(
            TreemapTile(
              item: item, rect: CGRect(x: remaining.minX, y: y, width: width, height: height)))
          y += height
        }
        remaining.origin.x += width
        remaining.size.width -= width
      } else {
        let height = min(remaining.height, rowArea / remaining.width)
        var x = remaining.minX
        for item in row {
          let area = CGFloat(Double(item.allocatedBytes) / total) * bounds.width * bounds.height
          let width = area / height
          output.append(
            TreemapTile(
              item: item, rect: CGRect(x: x, y: remaining.minY, width: width, height: height)))
          x += width
        }
        remaining.origin.y += height
        remaining.size.height -= height
      }
      _ = availableArea
    }
    return output
  }

  private static func worstAspect(
    _ items: [ScannedItem], totalArea: CGFloat, side: CGFloat, totalBytes: Double,
    boundsArea: CGFloat
  ) -> CGFloat {
    guard let first = items.first, let last = items.last, totalArea > 0, side > 0 else {
      return .greatestFiniteMagnitude
    }
    let largest = CGFloat(Double(first.allocatedBytes) / totalBytes) * boundsArea
    let smallest = max(1, CGFloat(Double(last.allocatedBytes) / totalBytes) * boundsArea)
    let square = side * side
    return max(
      (square * largest) / (totalArea * totalArea), (totalArea * totalArea) / (square * smallest))
  }
}
