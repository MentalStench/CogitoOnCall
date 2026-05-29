# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Cogito On Call Helper** — a PowerShell 7 desktop application for on-call engineers to monitor SQL Server Agent jobs across multiple SQL Server instances.

## Running the App

```powershell
pwsh -ExecutionPolicy Bypass -File .\CogitoOnCall.ps1
```

## Architecture

The app is a single `.ps1` entry point that loads a .NET WPF or WinForms UI. Its three logical layers:

### Configuration Layer (`config.json`)
JSON file defining each SQL Server instance and its monitored jobs:
- Instance connection details
- Agent job names per instance (only enabled jobs)
- Job schedule (specific days or patterns like `"daily"`)
- Estimated completion time per job

### Database Layer
PowerShell functions that connect to each SQL Server instance via the `SqlServer` module (or ADO.NET) and query the `msdb` system tables for Agent job history and last run status.

### UI Layer (WPF or WinForms via `Add-Type`)
.NET form rendered from PowerShell using `[System.Windows.Forms.*]` or XAML. The UI shows per-instance job status and surfaces errors so the on-call engineer can immediately see what needs attention. A **Scan** button triggers the entire workflow.

## Core Workflow (triggered by Scan button)

1. Parse `config.json`
2. For each instance → for each enabled scheduled job:
   - Connect to the SQL Server instance
   - Query `msdb.dbo.sysjobhistory` / `msdb.dbo.sysjobs` for last run outcome and time
   - Compare against the expected schedule window and estimated completion time
   - Flag jobs that are overdue, failed, or haven't run
3. Populate the UI with per-job status (success / failed / not-run / overdue)

## Key SQL Server Tables

| Table | Purpose |
|---|---|
| `msdb.dbo.sysjobs` | Job definitions and enabled flag |
| `msdb.dbo.sysjobhistory` | Run history including outcome and duration |
| `msdb.dbo.sysjobschedules` / `msdb.dbo.sysschedules` | Schedule metadata |

## PowerShell Conventions

- Target **PowerShell 7** (`pwsh`) — use modern syntax (ternary, null-coalescing, etc.)
- Use `try/catch` around each SQL Server connection; surface connection failures in the UI rather than crashing
- Keep SQL query logic in separate functions, not inline in UI event handlers
