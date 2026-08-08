# Architecture

OpenDiskTree is split into a small native metadata reader, a Swift core module and a SwiftUI application. The boundary is intentional: directory reads stay cheap, while policy and presentation remain testable Swift code.

SQLite is the live model. Scan batches are committed as they arrive, and views query only the rows they need. A completed snapshot is immutable; cancelled scans remain marked partial and never replace history.

## Incremental index

OpenDiskTree does not parse private APFS on-disk structures. macOS does not provide a stable public equivalent of the Windows NTFS MFT, and reverse-engineering APFS would be fragile around FileVault, snapshots, clones and volume groups. Instead, the completed SQLite snapshot is the app's own metadata index. A public FSEvents stream records changed paths while the app is open. On a fast update, changed branches are enumerated normally and unchanged directory subtrees are copied from the previous snapshot in one SQL operation. IDs are retained for copied rows; new rows use IDs above the previous maximum.

The optimization is never allowed to silently return stale data. The app requires a continuous in-process journal baseline, rejects dropped or wrapped event streams, refuses to reuse a subtree containing hard links, and marks a scan ineligible for the next fast update when events arrive during it. A full rescan from scratch is always available from the toolbar. After an app restart, the first request is full because the in-memory FSEvents coverage window is no longer continuous.

## Data flow

1. `OpenDiskTreeNative` reads directory names in batches with `getattrlistbulk`; unsupported filesystems fall back to `readdir` and `fstatat`.
2. `DiskScanner` applies bounded concurrency, package and mount-boundary policy, hard-link accounting and cooperative pause or cancellation.
3. `ScanStore` commits batches in WAL mode and derives folder aggregates in SQL. The UI never retains an entire large scan.
4. The rules engine adds a conservative status, reason, source rule and confidence. A folder cannot hide a stricter child status.
5. SwiftUI coordinates the application while `NSOutlineView` and `NSTableView` virtualize large result sets. The treemap receives only the current visible slice.

Duplicate hashing and export are explicit secondary jobs. They page through SQLite independently of the scanner. Hashing refuses iCloud placeholders unless the user accepts the download risk.

Exports use keyset pagination by `(scan_id,id)` for complete and filtered scopes instead of repeatedly increasing `OFFSET`; this keeps JSON, CSV and SQLite export time close to linear as snapshots grow.

File actions re-read device and inode identity before using the macOS Trash API. This prevents an item replaced after the scan from being acted on under stale metadata. There is deliberately no permanent-delete function or privileged helper.

Scanner work is wrapped in a Points of Interest signpost named `Disk scan`, so Instruments can correlate traversal time with filesystem and UI activity. `Scripts/benchmark.sh` feeds one million bounded batches through the same SQLite insertion and aggregation path by default; CI uses a smaller 20,000-row run while still exercising the identical code.

## Snapshot lifecycle

A scan starts as `running`, may become `cancelled` or `failed`, and becomes comparison history only after it reaches `completed`. OpenDiskTree keeps the two latest completed snapshots for each root, which is enough to calculate added, removed, changed and grown items without allowing an interrupted scan to corrupt the baseline.

## Process boundaries

OpenDiskTree has one local process and no server component. It does not initiate network requests, load file contents for classification or send telemetry. SQLite databases and user rules live in the application support directory. Exports leave that boundary only through a user-selected save panel.

See `Docs/ExportFormat.md` and `Docs/Rules.md` for the two public data contracts.
