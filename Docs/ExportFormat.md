# Export format

Every export has `schemaVersion = 1`. Byte counts are unsigned integers. JSON and CSV dates use RFC 3339 UTC. SQLite stores the same dates as text for straightforward interoperability.

Stable status values are `safe_to_delete`, `recreated_automatically`, `delete_via_source_app`, `do_not_touch`, `review` and `mixed`.

Full exports contain metadata only. The compact AI report contains summaries and selected top rows. Neither format includes file contents.

## Scope

The export dialog offers three scopes:

- **Complete scan** includes every item recorded for the selected snapshot.
- **Current filter** applies the same text, extension, status, size, date and duplicate filters visible in the results view.
- **Selected subtree** includes the selected item and all descendants.

Exports are written to a temporary sibling file and replace the destination only after a successful close. Cancelling or failing an export leaves the previous destination untouched.

## Item fields

JSON items, CSV rows and SQLite `items` rows use the same meanings:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | integer | Item ID within the scan. |
| `parentId` | integer or null | Parent item ID; null for the selected root. |
| `path`, `name` | string | Exported path and final path component after the selected privacy transform. |
| `kind` | string | `file`, `directory`, `symlink`, `package` or `other`. |
| `extension` | string or null | Lowercase filename extension when present. |
| `logicalBytes` | integer | File length visible to applications, or an aggregate for directories. |
| `allocatedBytes` | integer | Allocated filesystem blocks, with hard-linked content counted once in aggregates. |
| `createdAt`, `modifiedAt` | RFC 3339 string or null | Filesystem timestamps when available. |
| `isHidden`, `isSymlink`, `isPackage` | boolean | Stable presentation flags. |
| `volumeId`, `fileId`, `linkCount` | string/integer | Filesystem identity used for hard-link accounting and stale-action checks. |
| `status` | string | One of the stable status values above. |
| `ruleId`, `reason` | string or null | Explainability data for the matching built-in or custom rule. |
| `error` | string or null | Per-item metadata error, if any. |

JSON additionally contains `manifest`, `scan`, `volumes`, `errors`, `rules`, `duplicateGroups` and `items`. CSV is intentionally flat and has one header row. The SQLite export contains `scans`, `volumes`, `items`, `scan_errors`, `duplicate_groups` and `duplicate_members`, including foreign keys and indexes for parent, path, size, status and duplicate lookups.

The `scan` object also records `mode` (`full` or `incremental`), `reusedItemCount` and `journalComplete`. These fields explain how much of the local index was reused; they never relax the cleanup safety rules.

## AI report

`ai-report.json` is a bounded summary rather than a database dump. Its manifest records the requested scope and privacy mode. It contains scan context, size-accounting caveats, inaccessible paths, totals by status and extension, recent snapshot changes, duplicate groups and ranked files and folders.

Defaults are 500 files, 200 folders and directory depth 4. The UI previews the estimated output size and lets the user reduce or increase each limit. Every report includes a warning that classifications and AI suggestions are not guarantees and must not trigger automatic deletion.

## Privacy modes

- **Full** preserves paths, volume labels and duplicate hashes.
- **Basic** replaces the home prefix with `$HOME` and volume roots with stable `$VOLUME_n` labels.
- **Strict** also replaces personal path segments with stable random tokens scoped to that export. Known system segments and extensions stay readable, while hashes are replaced by duplicate-group IDs.

The random token map is created independently for every strict export. It is not stored in the scan database or written alongside the report.

## Compatibility

Readers should reject unknown major schema versions and ignore unknown fields within schema version 1. New optional fields may be added without changing the version; removing a field, changing its meaning or changing a stable wire value requires a new schema version.
