# Changelog

All notable changes to OpenDiskTree are recorded here.

## 1.3.0 — 2026-08-09

- Replace barrier-based directory batches with a continuous bounded worker pool, so one slow or protected directory no longer stalls every metadata reader.
- Raise balanced and turbo metadata concurrency for APFS while keeping the worker count bounded.
- Pipeline SQLite writes behind the scanner with ordered backpressure instead of stopping directory discovery for every transaction batch.
- Keep global query indexes in place across snapshots, avoiding a full retained-history index rebuild before and after every scan.
- Publish a completed snapshot before pruning old history; multi-million-row cascade deletion now runs transactionally on a background WAL connection.
- Disable foreground WAL auto-checkpoints during a scan; checkpoint and truncate the scan log during background retention maintenance after results are visible.
- Give SQLite a bounded metadata page cache and memory-map read-only index pages, avoiding repeated SSD reads while large retained B-trees are updated.
- Reclaim abandoned `running` snapshots and obsolete partial snapshots left by terminated older builds during background retention cleanup.
- Compute directory sizes and safety states in one in-memory bottom-up pass, replacing one SQL table scan per path depth during finalization.
- Reuse the previous directory rollup during incremental scans, avoiding the old full-table aggregation after unchanged subtrees are copied.
- Compile cleanup-rule paths once and classify suffix rules using the extension already returned by the native reader.
- Parse `getattrlistbulk` records from their returned attribute bitmap so optional metadata cannot misalign the rest of a record.
- Add a reproducible real-filesystem benchmark. On the development Mac, a 1.96-million-item `/` traversal took 19.8 seconds and a clean SQLite snapshot including finalization took 27.3 seconds, down from 431 seconds in the previous installed build.

## 1.2.3 — 2026-08-09

- Make SQLite rule export resilient when a user rule intentionally uses the same ID as a built-in rule.

## 1.2.2 — 2026-08-09

- Show export progress in the toolbar and allow cancelling a large export without leaving a partial destination file.

## 1.2.1 — 2026-08-09

- Batch JSON page writes into a single buffered filesystem write and reuse one RFC 3339 formatter during export.

## 1.2.0 — 2026-08-09

- Sample scanner pause/cancel state every 256 entries instead of paying an actor hop for every metadata row.
- Use keyset pagination for large JSON, CSV and SQLite exports.
- Make the folder outline load descendants only when a directory is expanded.
- Export a relational SQLite schema with scans, volumes, rules, errors and duplicate foreign keys.

## 1.1.1 — 2026-08-07

- Do not carry duplicate-group IDs between snapshots when copying unchanged subtrees; duplicate groups are always scoped to the snapshot that calculated them.

## 1.1.0 — 2026-08-07

- Add a local incremental metadata index backed by SQLite and the public macOS FSEvents journal.
- Reuse unchanged directory subtrees with stable item IDs instead of walking every descendant again.
- Add explicit **Fast update current scan** and **Full rescan from scratch** actions to the toolbar.
- Fall back to a full scan after app restart, dropped events, hard-link subtrees or changes during a scan; no private APFS parser is used.
- Document the APFS/MFT decision and add an end-to-end incremental-reuse test.

## 1.0.10 — 2026-08-07

- Add a persistent New scan menu to the main toolbar so starting a scan does not depend on the sidebar being visible.
- Add a Largest files view that lists the biggest files across the current snapshot without drilling through every folder.
- Add a visible double-click hint and a dedicated breadcrumb title for the largest-files view.

## 1.0.9 — 2026-08-07

- Add a composite parent/size index so opening a large snapshot does not sort the entire items table to show the root.

## 1.0.8 — 2026-08-07

- Do not reopen a scan record left in `running` state after an interrupted launch; keep the latest usable snapshot selected.

## 1.0.7 — 2026-08-07

- Keep startup responsive by loading the root outline lazily instead of decoding thousands of historical folders at once.

## 1.0.6 — 2026-08-07

- Add a fast overview pass that shows depth-limited folder totals while the exact metadata scan runs in the background.
- Mark preliminary totals and estimates explicitly; they are never mixed into the exact SQLite snapshot.
- Cancel the quick pass together with the exact scan and keep the existing exact results authoritative.

## 1.0.5 — 2026-08-07

- Keep one SQLite transaction open for the active scan; cancellation and normal completion still finalize a consistent snapshot.
- Bind item fields directly instead of allocating a 28-value temporary array for every file, and store bulk file timestamps numerically in SQLite while keeping RFC 3339 export output.
- Increase the native `getattrlistbulk` buffer to 256 KiB for wide directories such as dependency trees.

## 1.0.4 — 2026-08-07

- Defer path, status and duplicate-candidate indexes until a scan finishes, avoiding three random SQLite index writes per discovered item.
- Replace the depth-by-depth correlated folder aggregation with an indexed bottom-up rollup, so finalization scales with the number of folders instead of rescanning the full table for every depth.
- Keep the visible progress counter moving independently of SQLite batch commits and label the final index/aggregation phase as finalizing.

## 1.0.3 — 2026-08-07

- Removed repeated root-table sorting from the scan hot path; live rows refresh at a controlled cadence while every metadata batch is still persisted immediately.
- Increased scanner transaction sizes and cached each entry's extension during native metadata conversion.
- A full-disk scan now spends its time on filesystem enumeration instead of redrawing the same SQLite result hundreds of times.
- Selected folders now persist macOS security-scoped bookmarks and keep access open for the scan, so reopening the same folder does not ask for permission again.

## 1.0.2 — 2026-07-19

- Read names, sizes, timestamps, file identity and link counts in the same native metadata batch instead of issuing a separate `stat` call for every item.
- Stop full-disk scans at nested mounted volumes, including iOS Simulator runtimes, while keeping those mount points visible in results.
- Increased SQLite insert batches and removed per-item URL construction from the scanner hot path.
- Cancelled snapshots now retain their live byte totals and are identified as partial after relaunch.
- Reworked the main window so the table and treemap use all available height, live scans do not show stale directory data, and in-progress folder sizes are clearly marked as calculating.
- Added visible elapsed time, item rate, current path, pause and stop controls during scans.
- Rebuilt the filter popover with unclipped labels, grouped controls, active-filter count and a scrollable fixed-size layout.
- Added a prominent latest-DMG download button to the README and stable release artifact names for permanent download links.

## 1.0.1 — 2026-07-19

- Added an Instruments Points of Interest interval around disk scans.
- Added a bounded, reproducible 1–2 million-row SQLite performance harness; one million rows complete in 15.2 seconds on the development Mac.

## 1.0.0 — 2026-07-19

- Native Apple Silicon disk scanner using `getattrlistbulk` with a portable POSIX fallback.
- Directory outline, sortable table, treemap, search and metadata filters.
- Explainable safety labels, guarded Trash actions and Finder integration.
- Staged duplicate detection, two-snapshot history and growth comparison.
- Full JSON, CSV and SQLite exports plus a compact privacy-aware AI report.
- Russian and English localization, local rule editor and JSON rule transfer.
