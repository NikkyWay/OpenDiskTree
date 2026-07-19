# Architecture

OpenDiskTree is split into a small native metadata reader, a Swift core module and a SwiftUI application. The boundary is intentional: directory reads stay cheap, while policy and presentation remain testable Swift code.

SQLite is the live model. Scan batches are committed as they arrive, and views query only the rows they need. A completed snapshot is immutable; cancelled scans remain marked partial and never replace history.

## Data flow

1. `OpenDiskTreeNative` reads directory names in batches with `getattrlistbulk`; unsupported filesystems fall back to `readdir` and `fstatat`.
2. `DiskScanner` applies bounded concurrency, package and mount-boundary policy, hard-link accounting and cooperative pause or cancellation.
3. `ScanStore` commits batches in WAL mode and derives folder aggregates in SQL. The UI never retains an entire large scan.
4. The rules engine adds a conservative status, reason, source rule and confidence. A folder cannot hide a stricter child status.
5. SwiftUI coordinates the application while `NSOutlineView` and `NSTableView` virtualize large result sets. The treemap receives only the current visible slice.

Duplicate hashing and export are explicit secondary jobs. They page through SQLite independently of the scanner. Hashing refuses iCloud placeholders unless the user accepts the download risk.

File actions re-read device and inode identity before using the macOS Trash API. This prevents an item replaced after the scan from being acted on under stale metadata. There is deliberately no permanent-delete function or privileged helper.

## Snapshot lifecycle

A scan starts as `running`, may become `cancelled` or `failed`, and becomes comparison history only after it reaches `completed`. OpenDiskTree keeps the two latest completed snapshots for each root, which is enough to calculate added, removed, changed and grown items without allowing an interrupted scan to corrupt the baseline.

## Process boundaries

OpenDiskTree has one local process and no server component. It does not initiate network requests, load file contents for classification or send telemetry. SQLite databases and user rules live in the application support directory. Exports leave that boundary only through a user-selected save panel.

See `Docs/ExportFormat.md` and `Docs/Rules.md` for the two public data contracts.
