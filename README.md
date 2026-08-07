# OpenDiskTree

OpenDiskTree is a native disk-space explorer for Apple Silicon Macs. It answers two questions without sending a directory listing anywhere: what is using the disk, and which items deserve a closer look before cleanup?

The app combines a directory outline, sortable file table and treemap. Known data receives an explainable safety label; everything else remains **Review**. Complete scans can be exported as JSON, CSV or SQLite, while the smaller AI report keeps only useful summaries and can pseudonymize private path segments.

[![Download the latest DMG](https://img.shields.io/badge/Download-latest_DMG-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/NikkyWay/OpenDiskTree/releases/latest/download/OpenDiskTree-arm64.dmg)

[View all releases](https://github.com/NikkyWay/OpenDiskTree/releases) · Apple Silicon · macOS 14+

![OpenDiskTree showing a scanned Swift project](Docs/Images/main-window.jpg)

## Highlights

- Fast metadata traversal with macOS `getattrlistbulk`, bounded concurrency and a POSIX fallback for other local filesystems.
- Logical and allocated sizes, with hard-linked blocks counted once in totals.
- Search plus filters for extension, status, size, modification date and duplicates.
- Five safety states: safe to delete, recreated automatically, delete through the source application, do not touch and review.
- Finder reveal from the inspector, table context menu or `⌘R`.
- Recoverable cleanup through the macOS Trash. There is no permanent-delete path.
- On-demand duplicate detection using size, sample hashes and full SHA-256 verification.
- The two latest successful snapshots per root, including added, removed and grown files.
- Complete JSON, CSV and SQLite exports for the full scan, current filter or selected subtree.
- Compact AI reports with configurable limits and full, basic or strict path privacy.
- English and Russian interface, local custom rules and no telemetry.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Xcode 16 or newer when building from source

## Build from source

Open the package in Xcode, or build entirely from the terminal:

```sh
swift build
swift test
./Scripts/build-app.sh
open dist/OpenDiskTree.app
```

`build-app.sh` creates an ad-hoc signed application. Release ZIP, DMG and SHA-256 manifest are built with:

```sh
./Scripts/release.sh 1.0.3
```

The command creates `OpenDiskTree-arm64.dmg`, `OpenDiskTree-arm64.zip` and `SHA256SUMS.txt`. GitHub release artifacts are unsigned. On first launch, macOS may require **Control-click → Open**. Developer ID signing and notarization can be added later without changing the application targets.

## First scan

Use **Scan Folder** for a normal directory or external local disk. **Scan Full Disk** starts at `/` and avoids mounted external, network and APFS backing volumes so the same data is not counted twice.

macOS protects Mail, Messages, browser data and several other directories. To include them, open **Full Disk Access…**, enable OpenDiskTree in System Settings, quit the app and launch it again. The scanner never installs a privileged helper; paths that remain inaccessible are counted and exported as scan errors.

When you choose a folder through **Scan Folder**, OpenDiskTree stores a macOS security-scoped bookmark for that folder and reuses it on the next launch. The first access still requires the normal macOS confirmation. Scanning the entire `/` volume is governed by the separate Full Disk Access setting; rebuilding an ad-hoc local copy can make macOS treat it as a new app identity and ask again.

Balanced mode limits I/O pressure. Turbo mode uses larger batches and more parallel directory reads. Both modes read file metadata with the same native bulk request used for directory names, defer nonessential SQLite indexes until the scan finishes, and refresh the visible table at a controlled cadence so a large scan does not repeatedly sort the same root rows. Folder totals and safety labels are finalized with an indexed bottom-up rollup rather than repeated full-table passes. A full-disk scan stops at nested mounted volumes such as Simulator runtimes instead of walking the same operating-system data again. A cancelled scan stays marked partial and never replaces a successful comparison snapshot.

The app can show the first useful rows while a scan is still running, but a complete scan must still enumerate every visible filesystem object. macOS does not expose a Windows-MFT equivalent for an exact, permission-aware disk tree, so a laptop with hundreds of thousands or millions of entries cannot be guaranteed to finish in a few seconds. The optimized path removes avoidable database/UI work; SSD speed, permissions and the number of files remain the limiting factors.

While a scan is running, the status bar shows elapsed time, processing rate and the current path. Folder totals and the treemap settle after the final aggregation pass; until then the interface labels them as calculating rather than displaying a misleading zero.

## Understanding the labels

- **Safe to delete** is reserved for disposable data such as diagnostic logs, with a reason visible in the inspector.
- **Recreated automatically** covers caches and build products that may cost time or network traffic to rebuild.
- **Delete through application** marks managed data such as Docker storage, Simulator devices and Xcode archives.
- **Do not touch** covers protected system locations.
- **Review** means OpenDiskTree does not have enough evidence. It is not a hidden recommendation to delete.

Folders are classified conservatively. A protected child cannot be hidden by a safer parent label. Strict cleanup mode blocks application-managed and protected data, while review and mixed folders require an explicit risk confirmation. Advanced settings can relax this, but every action still goes through the Trash and validates that the file identity has not changed since the scan.

Built-in rules and their sources are described in [Docs/Rules.md](Docs/Rules.md). Custom rules can be previewed against the current view and transferred as versioned JSON.

## Exports and privacy

The complete formats share schema version 1:

- JSON is convenient for scripts and smaller scans.
- CSV is a flat UTF-8 table for spreadsheets.
- SQLite is the practical choice for millions of rows.
- `ai-report.json` contains top files and folders, status/extension totals, inaccessible paths, duplicate groups and snapshot changes.

Full paths preserve everything. Basic privacy replaces the home and volume identity. Strict privacy keeps useful system names and extensions while replacing personal path segments with stable tokens for that export. Strict exports also omit content hashes. File contents are never exported.

See [Docs/ExportFormat.md](Docs/ExportFormat.md) for the stable fields. Automated labels and AI suggestions are context, not a backup strategy or a guarantee that deletion is harmless.

## Size accounting

Logical size is the length applications see. Allocated size comes from filesystem blocks and is closer to immediately occupied storage. Sparse files, compression and hard links can make the numbers differ substantially.

Hard links are identified by volume and file ID and counted once in aggregate allocated totals. APFS clones can share physical blocks, but macOS does not expose enough public information to calculate their unique contribution exactly. OpenDiskTree states this limitation instead of presenting a false exact result.

## Development

The Swift package contains three layers:

- `OpenDiskTreeNative` performs batch directory reads.
- `OpenDiskTreeCore` owns scanning, SQLite, rules, duplicate detection and exports.
- `OpenDiskTreeApp` contains the SwiftUI shell and virtualized AppKit outline/table views.

`swift test` covers real temporary directory scans, Unicode paths, packages, symlinks, history, protected aggregation, privacy, exports and duplicate hashing. The quick scanner benchmark creates and scans 2,000 files; it completes in roughly 0.6 seconds on the development Mac. CI also exercises a reduced streaming-persistence benchmark. Before a release, run the million-row profile with `./Scripts/benchmark.sh`; pass another count to reproduce a 1–2 million metadata-row test. One million rows completed in 15.2 seconds on the development Mac. Large-disk timings still depend heavily on filesystem state, permissions and SSD performance.

Contributions are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first. Security and privacy reports belong in [SECURITY.md](SECURITY.md).

## License

MIT. Copyright (c) 2026 NikkyWay.
