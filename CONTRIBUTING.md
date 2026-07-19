# Contributing

OpenDiskTree is a small macOS project with one non-negotiable rule: a cleanup suggestion must be explainable and conservative.

1. Open an issue before a large change.
2. Keep commits focused and include tests for scanner, rule or export changes.
3. Run `swift test` and `swift build` before opening a pull request.
4. New built-in cleanup rules need a stable source, a reason shown to the user and a regression test.

Please do not add telemetry, remote analytics or automatic permanent deletion.
