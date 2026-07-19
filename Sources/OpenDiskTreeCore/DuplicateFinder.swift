import CryptoKit
import Foundation

public struct DuplicateProgress: Sendable, Equatable {
  public let processedFiles: Int
  public let candidateFiles: Int
  public let bytesRead: UInt64
  public let currentPath: String
}

public struct DuplicateSearchResult: Sendable, Equatable {
  public let groups: [DuplicateGroup]
  public let skippedCloudPlaceholders: [String]
}

public actor DuplicateFinder {
  private var cancelled = false

  public init() {}
  public func cancel() { cancelled = true }

  public func find(
    scanID: Int64,
    store: ScanStore,
    minimumBytes: UInt64 = 1,
    onProgress: @Sendable (DuplicateProgress) async -> Void = { _ in }
  ) async throws -> DuplicateSearchResult {
    cancelled = false
    let candidates = try await store.duplicateCandidates(scanID: scanID, minimumBytes: minimumBytes)
    let total = candidates.reduce(0) { $0 + $1.count }
    var processed = 0
    var bytesRead: UInt64 = 0
    var skipped: [String] = []
    var groups: [DuplicateGroup] = []
    var nextGroupID: Int64 = 1

    for sameSize in candidates {
      if cancelled || Task.isCancelled { break }
      let uniqueItems = Dictionary(grouping: sameSize, by: { "\($0.deviceID):\($0.fileID)" })
        .compactMap(\.value.first)
      guard uniqueItems.count > 1 else { continue }
      var quickGroups: [String: [ScannedItem]] = [:]
      for item in uniqueItems {
        if cancelled || Task.isCancelled { break }
        let url = URL(fileURLWithPath: item.path)
        if Self.isCloudPlaceholder(url) {
          skipped.append(item.path)
          continue
        }
        do {
          let (hash, read) = try Self.sampleHash(url: url, size: item.logicalBytes)
          bytesRead += read
          quickGroups[hash, default: []].append(item)
        } catch {
          continue
        }
        processed += 1
        await onProgress(
          DuplicateProgress(
            processedFiles: processed, candidateFiles: total, bytesRead: bytesRead,
            currentPath: item.path))
      }

      for quickGroup in quickGroups.values where quickGroup.count > 1 {
        var fullGroups: [String: [ScannedItem]] = [:]
        for item in quickGroup {
          if cancelled || Task.isCancelled { break }
          do {
            let (hash, read) = try Self.fullHash(url: URL(fileURLWithPath: item.path))
            bytesRead += read
            fullGroups[hash, default: []].append(item)
          } catch {
            continue
          }
          await onProgress(
            DuplicateProgress(
              processedFiles: processed, candidateFiles: total, bytesRead: bytesRead,
              currentPath: item.path))
        }
        for (hash, exactItems) in fullGroups where exactItems.count > 1 {
          let reclaimable = exactItems.dropFirst().reduce(UInt64(0)) {
            $0 &+ $1.accountedAllocatedBytes
          }
          groups.append(
            DuplicateGroup(
              id: nextGroupID, scanID: scanID, logicalBytes: exactItems[0].logicalBytes,
              sha256: hash, itemIDs: exactItems.map(\.id), reclaimableBytes: reclaimable
            ))
          nextGroupID += 1
        }
      }
    }

    groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
    if !cancelled && !Task.isCancelled {
      try await store.replaceDuplicateGroups(scanID: scanID, groups: groups)
    }
    return DuplicateSearchResult(groups: groups, skippedCloudPlaceholders: skipped)
  }

  private nonisolated static func isCloudPlaceholder(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      ]),
      values.isUbiquitousItem == true
    else { return false }
    return values.ubiquitousItemDownloadingStatus != .current
  }

  private nonisolated static func sampleHash(url: URL, size: UInt64) throws -> (String, UInt64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var read: UInt64 = 0
    let chunk = 64 * 1_024
    if let first = try handle.read(upToCount: chunk) {
      hasher.update(data: first)
      read += UInt64(first.count)
    }
    if size > UInt64(chunk * 2) {
      try handle.seek(toOffset: size - UInt64(chunk))
      if let last = try handle.read(upToCount: chunk) {
        hasher.update(data: last)
        read += UInt64(last.count)
      }
    }
    var sizeValue = size.littleEndian
    withUnsafeBytes(of: &sizeValue) { hasher.update(bufferPointer: $0) }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), read)
  }

  private nonisolated static func fullHash(url: URL) throws -> (String, UInt64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var read: UInt64 = 0
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
      read += UInt64(data.count)
    }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), read)
  }
}
