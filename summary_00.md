# Build Summary — Cogito On Call Helper (Initial Build)

All 23 analysis tests pass, all scripts parse clean, and the WPF UI constructs correctly from mock data (including the unreachable-instance path).

## Structure

```
CogitoOnCall.ps1        Entry point: STA bootstrap + scan orchestration
src/Config.ps1          Load & validate config.json
src/Database.ps1        SQL Server connect (Windows auth, retry once) + msdb queries
src/JobAnalysis.ps1     Pure logic: date conversion, schedules, problem flags
src/UI.ps1              WPF window, color-coded pills, expand-in-place job rows
tests/Test-Analysis.ps1 23 tests, no SQL Server needed
config.sample.json      Copy to config.json and edit
CLAUDE.md / spec.md     Docs
```

## Two Real Bugs Found and Fixed During Testing

1. **`@($list)` on a `Generic.List[object]`** threw "Argument types do not match" and silently returned **zero** items — every scan would have come back empty. Fixed with `,$results.ToArray()` in `Get-InstanceJobStatuses`.

2. **WPF `.Children.Add()` returns the insert index**, which leaked into function output and broke the outer `.Add()` calls (panel sections=0). Fixed by prefixing all 21 `.Add(...)` calls with `[void]` in `src/UI.ps1`.

Both gotchas are documented in CLAUDE.md so they don't recur.

## What Was Not Verified

The actual SQL queries against a live `msdb` and the rendered window itself — there is no SQL Server instance or interactive desktop session in the build environment. The data layer and visual rendering are syntactically sound and the pure logic is fully tested, but a real run is needed:

```powershell
Copy-Item config.sample.json config.json   # then edit with your instances/jobs
pwsh -ExecutionPolicy Bypass -File .\CogitoOnCall.ps1
```

The most likely thing needing a tweak on first contact with live data is `Get-RunningAgentJobs` — the `syssessions`/`sysjobactivity` join for in-progress job detection.
