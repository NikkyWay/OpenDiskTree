# ADR 0001: Batch native traversal with SQLite as the live model

- Status: accepted
- Date: 2026-07-19

## Context

A full Mac disk can contain millions of entries. Foundation-only enumeration adds object-allocation overhead, while keeping every row in memory makes cancellation, live results and export unnecessarily expensive.

## Decision

Read directory names with `getattrlistbulk` where macOS supports it and use `readdir` plus `fstatat` as the portable local-filesystem fallback. Stream metadata through bounded Swift concurrency into batched SQLite WAL transactions. Treat SQLite, not an in-memory tree, as the live source for aggregates, paging, history and export.

## Consequences

The UI can show early results and stay within a predictable memory envelope. Cancellation has frequent cooperative checkpoints, and export does not depend on UI state. The cost is a small C boundary, explicit schema migration and more SQL tests. APFS clone sharing still cannot be measured exactly through public APIs, so allocated-size output carries that limitation.
