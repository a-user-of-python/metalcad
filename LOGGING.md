# MetalCAD — Logging Design

Logging is a feature, not an afterthought: every error code in
[ERRORS.md](ERRORS.md) reaches the log, and a user can hand us a log bundle
that actually reproduces their problem.

## Principles
1. **Everything diagnosable, nothing private.** Logs contain operation names,
   error codes, timings, sizes, counts, DOF numbers — never document content,
   never file paths with the user's name, never typed text beyond numeric
   parameter values involved in a failure.
2. **Structured, not string soup.** Every entry: timestamp, level, category,
   code (nullable), message, and a small context dictionary.
3. **Cheap when nothing's wrong.** Release builds log at `info` and up; the
   ring buffer costs microseconds per entry.
4. **The log survives the crash.** Entries are appended to a file, not held in
   memory only. A fatal path flushes and snapshots before exit.

## Levels
`trace` (per-iteration solver detail) · `debug` (feature-tree rebuild steps) ·
`info` (operations, saves, exports) · `warn` (every W-code) · `error` (every
E/F code) · `fatal`.

## Categories
Mirror the error domains: `general, document, sketch, solver, feature,
thread, kernel, io, assembly, drawing, render, ui` — plus `perf` (timings)
and `lifecycle` (launch, background, memory warnings).

## Implementation (`MCLog`, in MetalCADKit)
- Pure-Swift, no dependencies, so it compiles and is unit-tested on any
  platform (including Linux CI).
- Sinks: in-memory ring buffer (2,000 entries, for the in-app Log viewer),
  file sink (JSON Lines, `Documents/Logs/metalcad-YYYYMMDD.log`, rotates at
  5 MB, keeps 4 files), and `os_log` on Apple platforms (compiled in via
  `#if canImport(os)` — the core stays platform-pure).
- API: `MCLog.info(.feature, "pad rebuilt", ctx: ["ms": "3.2"])`,
  `MCLog.error(CADError…, …)`. Throwing a `CADError` anywhere in a rebuild
  automatically logs it at its severity with its code — enforced by the
  rebuild loop, not by each call site remembering.
- **Automatic coverage:**
  - Rebuild: start/finish, duration per feature, first failure + its code.
  - Solver: constraint count, DOF before/after, iterations, final residual
    (trace carries per-iteration residuals).
  - Kernel: operation name, input shape counts, duration, result validity.
  - IO: format, file size, triangle/shape counts, duration.
  - Perf: any operation > 100 ms logs a `perf` entry with its duration.

## In-app surfaces
- **Settings → Diagnostics:** log level picker (release default `info`),
  "View log" (last 200 entries, large text), "Export log bundle"
  (zip: logs + app/build version + device model + iOS version; **no document
  unless the user ticks "include current document"**), "Copy last error code".
- Any error alert shows its code in small text under the plain-words message —
  quote it and we can find the exact log line.

## What "done" means for v1
Ring buffer + file sink + JSONL format + auto-logging in the rebuild loop +
solver/kernel summaries + the Diagnostics screen. `os_log` bridging and the
zip bundle are v1.1.
