# Cleanup rules

Rules are local JSON records with a stable identifier, priority, path glob, resulting status, reason and optional source-application hint. User rules are stored separately from the built-in catalogue.

A folder is safe only when all descendants considered by the scan are safe. A mixed folder carries the strongest restriction found below it. Protected built-in matches can only be overridden after Advanced mode is enabled.

## Source policy

Built-in rules carry their source URL in the exported rule catalogue. Apple documents that safe mode clears system caches which are created again as needed, and that system data such as caches and logs is managed by macOS. Docker explicitly recommends its own prune and Desktop interfaces for managed images, containers and volumes. OpenDiskTree therefore labels these paths as rebuildable or application-managed rather than silently deleting them.

Rules are reviewed when the referenced application changes its storage layout. If the match can no longer be verified, it must fall back to `review`.
