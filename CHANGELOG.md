# Changelog

All notable changes to OpenDiskTree are recorded here.

## 1.0.2 — 2026-07-19

- Read names, sizes, timestamps, file identity and link counts in the same native metadata batch instead of issuing a separate `stat` call for every item.
- Stop full-disk scans at nested mounted volumes, including iOS Simulator runtimes, while keeping those mount points visible in results.
- Increased SQLite insert batches and removed per-item URL construction from the scanner hot path.
- Cancelled snapshots now retain their live byte totals.

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
