# Cogito On Call Helper — Specification

## Overview

A PowerShell 7 desktop application (.ps1 + .NET WPF or WinForms form) for on-call engineers to monitor SQL Server Agent jobs across multiple SQL Server instances. The engineer opens the app, clicks **Scan**, and immediately sees which jobs need attention.

---

## Configuration File (`config.json`)

Plain JSON, maintained manually by the developer. Text editor is sufficient — no in-app editor.

### Schema

```json
{
  "instances": [
    {
      "name": "display name for the UI",
      "server": "SERVERNAME\\INSTANCE",
      "jobs": [
        {
          "name": "ExactAgentJobName",
          "schedule": "daily",
          "expectedStartTime": "02:00",
          "estimatedDurationMinutes": 30,
          "lookbackHours": 12
        },
        {
          "name": "AnotherJob",
          "schedule": ["Mon", "Wed", "Fri"],
          "expectedStartTime": "06:00",
          "estimatedDurationMinutes": 15,
          "lookbackHours": 8
        }
      ]
    }
  ]
}
```

### Field Definitions

| Field | Type | Description |
|---|---|---|
| `server` | string | SQL Server connection string (instance name or IP\instance) |
| `name` (instance) | string | Display label shown in the UI |
| `name` (job) | string | Must match the Agent job name exactly |
| `schedule` | `"daily"` or `string[]` | `"daily"` = every day; array = days of week using 3-letter abbreviations (`"Mon"`, `"Tue"`, `"Wed"`, `"Thu"`, `"Fri"`, `"Sat"`, `"Sun"`) |
| `expectedStartTime` | `"HH:mm"` | 24-hour local time the job is expected to begin |
| `estimatedDurationMinutes` | integer | How long the job normally takes. Used to compute the overdue threshold: `expectedStartTime + estimatedDurationMinutes` |
| `lookbackHours` | integer | How far back from the scan time to look for a run record |

---

## Authentication

Windows authentication only. The app connects as the current Windows user — no credentials are stored in the config or the app.

---

## Scan Behavior

Triggered manually by clicking the **Scan** button. Results persist until the next scan. No auto-refresh.

### Steps

1. Read and parse `config.json`.
2. For each instance:
   a. Attempt to connect to the SQL Server instance.
   b. On failure: retry once, then mark the instance as **Unreachable** and continue to the next instance.
   c. On success: run two checks (see below).
3. Populate the UI with results.

### Check 1 — Config Jobs

For each job listed in the config for this instance:

- Determine whether the job is scheduled to run today based on its `schedule` field and today's day of week.
- If not scheduled today: skip (show as **Not Scheduled**).
- If scheduled today:
  - Query `msdb` for run records within the `lookbackHours` window.
  - Apply the problem flags below.

### Check 2 — Unlisted Enabled Jobs

Query every Agent job on the instance that is both:
- Enabled (`sysjobs.enabled = 1`)
- Has at least one enabled schedule (`sysschedules.enabled = 1`)
- **Not** already listed in the config for this instance

For each such job: retrieve its last run outcome and flag it if the last run failed. No schedule or duration expectations are applied (since there is no config entry).

---

## Problem Flags

| Flag | Condition |
|---|---|
| **Failed** | The most recent run in the lookback window has a failed outcome (SQL Agent outcome ≠ succeeded) |
| **Did Not Run** | Job was scheduled today, lookback window has elapsed past `expectedStartTime`, and there is no run record in the window |
| **Overdue** | Job started but has not completed, and current time > `expectedStartTime + estimatedDurationMinutes` |
| **Succeeded Late** | Job completed successfully, but completion time > `expectedStartTime + estimatedDurationMinutes` |
| **OK** | Job ran, succeeded, and completed on time |
| **Not Scheduled** | Today's day of week is not in the job's `schedule` |
| **Unreachable** | Instance-level flag — connection could not be established after one retry |

A job can have multiple flags simultaneously (e.g., **Overdue** while still running, then becomes **Succeeded Late** once it finishes).

---

## UI

### Layout

- Grouped by instance (one section/panel per instance)
- Each instance section shows:
  - Instance display name
  - Connection status (connected / unreachable)
  - A list of jobs with their flags and basic info

### Job Row (collapsed)

Each row shows:
- Job name
- Flag / status (color-coded: red = problem, green = OK, gray = not scheduled)
- Last run start time
- Last run duration

### Job Row (expanded — click to toggle)

Clicking a job row expands it in place to show:
- Full error message (if failed)
- Recent run history (last N runs): start time, duration, outcome

### Colors

| State | Color |
|---|---|
| OK | Green |
| Not Scheduled | Gray |
| Unreachable | Orange |
| Any problem flag | Red |

---

## Key SQL Server Tables

| Table | Used For |
|---|---|
| `msdb.dbo.sysjobs` | Job names, enabled flag |
| `msdb.dbo.sysjobhistory` | Run records, outcomes, messages, durations |
| `msdb.dbo.sysjobschedules` | Links jobs to schedules |
| `msdb.dbo.sysschedules` | Schedule enabled flag |

---

## Out of Scope

- In-app config editor
- SQL authentication / stored credentials
- Auto-refresh / scheduled polling
- Notifications or alerts (email, SMS, etc.)
- Editing or re-running jobs from the UI
- Monthly or specific-date schedule patterns
