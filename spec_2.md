# spec_2.md — Data Checks Feature

## Context

On-call engineers need to validate data pipeline health beyond SQL Agent job execution. A query might succeed but produce stale or lagged data. This feature adds configurable T-SQL checks to `config.json` that query arbitrary data (e.g., sent vs. received timestamps) and surface a pass/fail indicator per check in the UI, displayed above the SQL Agent job list for each instance.

---

## Config Schema

Add an optional `dataChecks` array to each instance object in `config.json`. Instances without it are unaffected.

```jsonc
{
  "instances": [
    {
      "name": "MDA Clarity PROD",
      "server": "EHRCLRDBPRDQ",
      "jobs": [...],
      "dataChecks": [
        {
          "name": "HL7 Feed Latency",
          "query": "SELECT TOP 1 sent_time, received_time FROM feed_log ORDER BY sent_time DESC",
          "operation": "subtract",        // subtract | divide | absSubtract | col1Only
          "threshold": 30,               // minutes for DateTime cols, raw number for numeric
          "thresholdDirection": "lte",   // lte | gte
          "col1Label": "Sent",
          "col2Label": "Received",
          "resultLabel": "Delta",
          "noDataIsFailure": true
        }
      ]
    }
  ]
}
```

### Field reference

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Display name for the check |
| `query` | string | yes | T-SQL SELECT returning exactly 2 columns |
| `operation` | string | yes | `subtract` (col2−col1), `divide` (col1÷col2), `absSubtract` (\|col1−col2\|), `col1Only` (use col1 directly) |
| `threshold` | number | yes | Limit to compare against; minutes for DateTime, raw for numeric |
| `thresholdDirection` | string | yes | `lte` (result ≤ threshold = pass) or `gte` (result ≥ threshold = pass) |
| `col1Label` | string | yes | Display label for column 1 in detail view |
| `col2Label` | string | yes | Display label for column 2 in detail view (unused for `col1Only`) |
| `resultLabel` | string | yes | Display label for the computed result |
| `noDataIsFailure` | bool | yes | `true` → red when no rows; `false` → gray "NO DATA" when no rows |

---

## Status States

| Status | Color | Pill Text | Condition |
|---|---|---|---|
| OK | Green `#2E7D32` | OK | Computed value passes threshold |
| Failed | Red `#C62828` | FAILED | Computed value fails threshold |
| NoData | Red `#C62828` | NO DATA | No rows returned, `noDataIsFailure: true` |
| NoData | Gray `#757575` | NO DATA | No rows returned, `noDataIsFailure: false` |
| Error | Red `#C62828` | ERROR | SQL exception; message shown in detail |

---

## New Files

### `src\DataCheck.ps1`
Database execution layer — mirrors the pattern in `src\Database.ps1`.

- `Invoke-DataCheckQuery(connection, checkConfig)` → returns a single result row (PSCustomObject with Col1, Col2) or `$null` if no rows.

### `src\DataCheckAnalysis.ps1`
Pure analysis logic — mirrors `src\JobAnalysis.ps1` pattern (no DB calls, fully testable).

- `Invoke-DataCheckAnalysis(checkConfig, row)` → computes result, compares threshold, returns a status object:
  ```
  {
    Name, Status, IsProblem,
    Col1Label, Col1Value,
    Col2Label, Col2Value,
    ResultLabel, ResultValue,   # computed number (minutes or raw)
    Threshold, ThresholdDirection,
    ErrorMessage                # populated on SQL error
  }
  ```

**Type handling:**
- If both columns are `[DateTime]`, compute `(col2 - col1).TotalMinutes` (or reverse for `subtract`) and round to 1 decimal.
- If either column is numeric, apply the operation directly as a raw number.
- For `col1Only`, Col2Value is not displayed.

**Operation logic:**
```
subtract    → col2 - col1  (or TotalMinutes for DateTime)
divide      → col1 / col2
absSubtract → |col1 - col2|  (or Abs(TotalMinutes))
col1Only    → col1
```

**Threshold comparison:**
```
lte → resultValue <= threshold  → OK
gte → resultValue >= threshold  → OK
```

---

## Modified Files

### `src\Config.ps1`
Add `Convert-ConfigDataCheck` (mirrors `Convert-ConfigJob`):
- Validate required fields present
- Validate `operation` ∈ {subtract, divide, absSubtract, col1Only}
- Validate `thresholdDirection` ∈ {lte, gte}
- Validate `threshold` is a number > 0
- Return normalized PSCustomObject

Update `Convert-ConfigInstance` to call `Convert-ConfigDataCheck` for each item in `dataChecks` (if present).

Also,
Make sure the instance's Jobs are optional
Make sure the instance's Datachecks are optional.
Not every instance will have both Jobs or Datachecks.

### `CogitoOnCall.ps1`
Inside `Invoke-CogitoScan`, within the per-instance loop — after fetching job data, add:

```powershell
$dataCheckResults = @()
if ($instance.dataChecks) {
    foreach ($check in $instance.dataChecks) {
        try {
            $row = Invoke-DataCheckQuery -Connection $conn -Check $check
            $dataCheckResults += Invoke-DataCheckAnalysis -Check $check -Row $row
        } catch {
            $dataCheckResults += [PSCustomObject]@{
                Name = $check.name; Status = 'Error'; IsProblem = $true
                ErrorMessage = $_.Exception.Message
            }
        }
    }
}
```

Include `DataCheckResults` in the per-instance result object returned to the UI.

Load `src\DataCheck.ps1` and `src\DataCheckAnalysis.ps1` at startup (alongside existing module loads).

### `src\UI.ps1`
Add two new UI functions:

**`New-DataCheckRow(result)`** — returns a WPF `Expander`:
- Header: `StatusPill` + bold check name + one-line summary (e.g., "Delta: 47.2 min | threshold: 30 min")
- Content (always shown, even when green):
  - `col1Label: col1Value`
  - `col2Label: col2Value` (omit if `col1Only`)
  - `resultLabel: resultValue (threshold: N, direction)`
  - Error message (red text, if `Status = 'Error'`)

**`New-DataChecksSection(dataCheckResults)`** — returns a `Border` wrapping a `StackPanel` of `New-DataCheckRow` calls. Header label: "Data Checks" (same font style as instance title, smaller). Returns `$null` if `dataCheckResults` is empty so callers can skip it.

Update **`New-InstanceSection`**:
- After building the instance header, call `New-DataChecksSection` and add it to the instance stack panel **before** the jobs expanders.

---

## Verification

1. Add one `dataChecks` entry to `config.json` using `SELECT GETDATE(), GETDATE()` with `subtract`, threshold `1`, `lte` — should always be green.
2. Run the app: `pwsh -ExecutionPolicy Bypass -File .\CogitoOnCall.ps1`
3. Click **Scan** and confirm:
   - "Data Checks" subsection appears **above** jobs for that instance
   - Green pill displays for the always-passing check
   - Expanded row shows col1/col2/result values
4. Change threshold to `0` — verify pill turns red.
5. Use a query returning no rows with `noDataIsFailure: true` — confirm red "NO DATA" pill.
6. Same with `noDataIsFailure: false` — confirm gray "NO DATA" pill.
7. Introduce a SQL syntax error — confirm red "ERROR" pill with message in detail.
