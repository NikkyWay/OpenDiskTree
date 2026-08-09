# ADR 0002: Local metadata index instead of private APFS parsing

## Decision

Use the completed SQLite snapshot as OpenDiskTree's own metadata index and use the public FSEvents API to identify changed paths. Re-enumerate changed branches and copy unchanged subtrees into the next snapshot. Provide a full-rescan-from-scratch command at all times.

## Why

Windows WizTree can read NTFS metadata structures designed for this purpose. macOS does not expose a supported APFS metadata table with the same contract. Private APFS parsing would be tied to undocumented layouts and could miscount snapshots, clones, FileVault volumes or volume groups after a macOS update. It would also be an unsafe foundation for a public open-source app.

The index/FSEvents design still requires one authoritative full scan, but makes later scans proportional to changed branches. If FSEvents reports dropped events, the app was restarted, a hard-link subtree would make accounting ambiguous, or files change during the scan, the optimization is disabled and the next scan is full. That conservative fallback is preferable to showing a fast but incomplete tree.
