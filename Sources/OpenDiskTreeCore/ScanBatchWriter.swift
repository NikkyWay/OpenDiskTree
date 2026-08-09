import Foundation

/// A small bounded pipeline that lets APFS metadata readers continue while the
/// previous batch is being encoded into SQLite. Writes stay strictly ordered,
/// and backpressure caps retained metadata instead of allowing an unbounded
/// queue on very fast volumes.
public actor ScanBatchWriter {
  private let store: ScanStore
  private let maximumPendingBatches: Int
  private var pending: [Task<Void, Error>] = []

  public init(store: ScanStore, maximumPendingBatches: Int = 3) {
    self.store = store
    self.maximumPendingBatches = max(1, maximumPendingBatches)
  }

  public func submit(_ items: [ScannedItem]) async throws {
    guard !items.isEmpty else { return }
    if pending.count >= maximumPendingBatches {
      let oldest = pending.removeFirst()
      try await oldest.value
    }

    let predecessor = pending.last
    let store = self.store
    let task = Task {
      if let predecessor { try await predecessor.value }
      try Task.checkCancellation()
      try await store.insert(items)
    }
    pending.append(task)
  }

  public func finish() async throws {
    defer { pending.removeAll(keepingCapacity: true) }
    for task in pending { try await task.value }
  }

  public func cancel() {
    for task in pending { task.cancel() }
  }
}
