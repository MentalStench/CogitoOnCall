# JobAnalysis.ps1 - Pure analysis: msdb integer conversion, schedule evaluation,
# and problem-flag determination. These functions take already-fetched data so they
# can be unit-tested without a live SQL Server.

# SQL Agent run_status codes (sysjobhistory)
$script:RunStatus = @{
    0 = 'Failed'
    1 = 'Succeeded'
    2 = 'Retry'
    3 = 'Canceled'
    4 = 'In Progress'
}

$script:DayAbbr = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat') # index = [int][DayOfWeek]

function ConvertFrom-AgentDateTime {
    <# Converts msdb integer run_date (yyyymmdd) + run_time (hhmmss) to a DateTime. #>
    param([int]$RunDate, [int]$RunTime)
    if ($RunDate -le 0) { return $null }
    $year = [math]::Floor($RunDate / 10000)
    $month = [math]::Floor(($RunDate % 10000) / 100)
    $day = $RunDate % 100
    $hour = [math]::Floor($RunTime / 10000)
    $min = [math]::Floor(($RunTime % 10000) / 100)
    $sec = $RunTime % 100
    try {
        [datetime]::new([int]$year, [int]$month, [int]$day, [int]$hour, [int]$min, [int]$sec)
    }
    catch {
        $null
    }
}

function ConvertFrom-AgentDuration {
    <# Converts msdb integer run_duration (HHMMSS) to a TimeSpan. #>
    param([int]$RunDuration)
    if ($RunDuration -lt 0) { $RunDuration = 0 }
    $hours = [math]::Floor($RunDuration / 10000)
    $mins = [math]::Floor(($RunDuration % 10000) / 100)
    $secs = $RunDuration % 100
    New-TimeSpan -Hours $hours -Minutes $mins -Seconds $secs
}

function Get-RunStatusName {
    param([int]$Code)
    if ($script:RunStatus.ContainsKey($Code)) { $script:RunStatus[$Code] } else { "Unknown ($Code)" }
}

function Test-ScheduledToday {
    <# Returns $true if the schedule covers the reference date's day of week. #>
    param(
        [Parameter(Mandatory)]$Schedule,   # 'daily' or array of 3-letter day names
        [datetime]$ReferenceDate = (Get-Date)
    )
    if ($Schedule -is [string] -and $Schedule -eq 'daily') { return $true }
    $today = $script:DayAbbr[[int]$ReferenceDate.DayOfWeek]
    return ($today -in @($Schedule))
}

function ConvertTo-RunRecord {
    <# Normalizes a raw history row into a record with a real DateTime/TimeSpan/outcome. #>
    param([Parameter(Mandatory)]$Row)
    $start = ConvertFrom-AgentDateTime -RunDate ([int]$Row.RunDate) -RunTime ([int]$Row.RunTime)
    $duration = ConvertFrom-AgentDuration -RunDuration ([int]$Row.RunDuration)
    [PSCustomObject]@{
        Start    = $start
        Duration = $duration
        End      = if ($start) { $start.Add($duration) } else { $null }
        Status   = [int]$Row.RunStatus
        Outcome  = Get-RunStatusName -Code ([int]$Row.RunStatus)
        Message  = $Row.Message
    }
}

function Get-JobRunRecords {
    <# Returns this job's runs (newest first), converted, optionally bounded by a window start. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$History,
        [Parameter(Mandatory)][string]$JobName,
        [datetime]$Since
    )
    $rows = $History | Where-Object { $_.JobName -eq $JobName }
    $records = foreach ($r in $rows) {
        $rec = ConvertTo-RunRecord -Row $r
        if ($null -eq $rec.Start) { continue }
        if ($PSBoundParameters.ContainsKey('Since') -and $rec.Start -lt $Since) { continue }
        $rec
    }
    @($records | Sort-Object Start -Descending)
}

function New-JobStatus {
    # Internal helper to build a uniform status object consumed by the UI.
    param(
        [string]$JobName,
        [string]$Status,
        [bool]$IsProblem,
        [bool]$Listed,
        $LastRun,
        [string]$Detail,
        [AllowEmptyCollection()][object[]]$History
    )
    [PSCustomObject]@{
        JobName   = $JobName
        Status    = $Status
        IsProblem = $IsProblem
        Listed    = $Listed
        LastRun   = $LastRun          # a run record (Start/Duration/End/Outcome/Message) or $null
        Detail    = $Detail           # short human-readable explanation
        History   = @($History)       # recent run records for the expandable view
    }
}

function Get-ConfigJobStatus {
    <#
        .SYNOPSIS
            Evaluates a single configured job against its schedule, expected timing,
            current run state, and recent history. Returns a job status object.
    #>
    param(
        [Parameter(Mandatory)]$JobConfig,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$History,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunningJobs,
        [datetime]$Now = (Get-Date),
        [int]$RunHistoryCount = 5
    )

    $name = $JobConfig.Name
    $allRuns = Get-JobRunRecords -History $History -JobName $name
    $recent = @($allRuns | Select-Object -First $RunHistoryCount)

    if (-not (Test-ScheduledToday -Schedule $JobConfig.Schedule -ReferenceDate $Now)) {
        return New-JobStatus -JobName $name -Status 'NotScheduled' -IsProblem $false -Listed $true `
            -LastRun ($allRuns | Select-Object -First 1) -Detail 'Not scheduled to run today.' -History $recent
    }

    # Expected window for today.
    $parts = $JobConfig.ExpectedStartTime.Split(':')
    $expectedStart = $Now.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    $expectedCompletion = $expectedStart.AddMinutes($JobConfig.EstimatedDurationMinutes)

    # Currently running?
    $running = $RunningJobs | Where-Object { $_.JobName -eq $name } | Select-Object -First 1
    if ($running) {
        if ($Now -gt $expectedCompletion) {
            return New-JobStatus -JobName $name -Status 'Overdue' -IsProblem $true -Listed $true -LastRun $null `
                -Detail "Still running; expected to finish by $($expectedCompletion.ToString('HH:mm'))." -History $recent
        }
        return New-JobStatus -JobName $name -Status 'Running' -IsProblem $false -Listed $true -LastRun $null `
            -Detail 'Currently running, within expected window.' -History $recent
    }

    # Most recent completed run inside the lookback window.
    $windowStart = $Now.AddHours(-$JobConfig.LookbackHours)
    $lastRun = $allRuns | Where-Object { $_.Start -ge $windowStart } | Select-Object -First 1

    if (-not $lastRun) {
        if ($Now -ge $expectedStart) {
            return New-JobStatus -JobName $name -Status 'DidNotRun' -IsProblem $true -Listed $true -LastRun $null `
                -Detail "No run found in the last $($JobConfig.LookbackHours)h; expected start was $($expectedStart.ToString('HH:mm'))." -History $recent
        }
        return New-JobStatus -JobName $name -Status 'Pending' -IsProblem $false -Listed $true -LastRun $null `
            -Detail "Not due until $($expectedStart.ToString('HH:mm'))." -History $recent
    }

    if ($lastRun.Status -ne 1) {
        return New-JobStatus -JobName $name -Status 'Failed' -IsProblem $true -Listed $true -LastRun $lastRun `
            -Detail "Last run $($lastRun.Outcome) at $($lastRun.Start.ToString('yyyy-MM-dd HH:mm'))." -History $recent
    }

    # Succeeded - on time or late?
    if ($lastRun.End -gt $expectedCompletion) {
        return New-JobStatus -JobName $name -Status 'SucceededLate' -IsProblem $true -Listed $true -LastRun $lastRun `
            -Detail "Finished $($lastRun.End.ToString('HH:mm')), past expected $($expectedCompletion.ToString('HH:mm'))." -History $recent
    }

    New-JobStatus -JobName $name -Status 'OK' -IsProblem $false -Listed $true -LastRun $lastRun `
        -Detail "Succeeded at $($lastRun.End.ToString('HH:mm'))." -History $recent
}

function Get-UnlistedJobStatus {
    <#
        .SYNOPSIS
            Evaluates an enabled+scheduled Agent job that is NOT in the config.
            Per spec, only the last-run-failed condition is a problem; no schedule
            or duration expectations apply.
    #>
    param(
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$History,
        [int]$RunHistoryCount = 5
    )
    $allRuns = Get-JobRunRecords -History $History -JobName $JobName
    $recent = @($allRuns | Select-Object -First $RunHistoryCount)
    $lastRun = $allRuns | Select-Object -First 1

    if (-not $lastRun) {
        return New-JobStatus -JobName $JobName -Status 'NoRecentRuns' -IsProblem $false -Listed $false -LastRun $null `
            -Detail 'No runs found in the fetched window.' -History $recent
    }
    if ($lastRun.Status -ne 1) {
        return New-JobStatus -JobName $JobName -Status 'Failed' -IsProblem $true -Listed $false -LastRun $lastRun `
            -Detail "Last run $($lastRun.Outcome) at $($lastRun.Start.ToString('yyyy-MM-dd HH:mm'))." -History $recent
    }
    New-JobStatus -JobName $JobName -Status 'OK' -IsProblem $false -Listed $false -LastRun $lastRun `
        -Detail "Last run succeeded at $($lastRun.Start.ToString('yyyy-MM-dd HH:mm'))." -History $recent
}

function Get-InstanceJobStatuses {
    <#
        .SYNOPSIS
            Combines Check 1 (config jobs) and Check 2 (unlisted enabled+scheduled jobs)
            for one instance. Pure: takes already-fetched catalog/history/running data.
    #>
    param(
        [Parameter(Mandatory)]$InstanceConfig,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$History,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RunningJobs,
        [datetime]$Now = (Get-Date),
        [int]$RunHistoryCount = 5
    )

    $configNames = @($InstanceConfig.Jobs | ForEach-Object { $_.Name })
    $results = New-Object System.Collections.Generic.List[object]

    # Check 1: configured jobs
    foreach ($jobCfg in $InstanceConfig.Jobs) {
        $results.Add((Get-ConfigJobStatus -JobConfig $jobCfg -History $History -RunningJobs $RunningJobs -Now $Now -RunHistoryCount $RunHistoryCount))
    }

    # Check 2: enabled jobs with an enabled schedule that are not in the config
    $unlisted = $Catalog | Where-Object {
        [int]$_.JobEnabled -eq 1 -and [int]$_.HasEnabledSchedule -eq 1 -and ($_.JobName -notin $configNames)
    }
    foreach ($cat in $unlisted) {
        $results.Add((Get-UnlistedJobStatus -JobName $cat.JobName -History $History -RunHistoryCount $RunHistoryCount))
    }

    # Return as a fixed array. Note: @($list) on a Generic.List[object] can throw
    # "Argument types do not match" on some PowerShell builds; .ToArray() is safe.
    , $results.ToArray()
}
