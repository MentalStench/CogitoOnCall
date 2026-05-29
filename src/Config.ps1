# Config.ps1 - Loading and validation of config.json
# See spec.md for the schema. Errors here are surfaced to the UI rather than thrown blindly.

$script:ValidDayNames = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')

function Read-CogitoConfig {
    <#
        .SYNOPSIS
            Reads and validates config.json, returning a normalized config object.
        .OUTPUTS
            PSCustomObject with .Instances (array) and .RunHistoryCount (int).
            Throws on missing file or invalid structure with a clear message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "config.json is not valid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $parsed.instances -or $parsed.instances.Count -eq 0) {
        throw "config.json must contain a non-empty 'instances' array."
    }

    $runHistoryCount = 5
    if ($null -ne $parsed.runHistoryCount) {
        $runHistoryCount = [int]$parsed.runHistoryCount
        if ($runHistoryCount -lt 1) { $runHistoryCount = 1 }
    }

    $instances = foreach ($inst in $parsed.instances) {
        Convert-ConfigInstance -Instance $inst
    }

    [PSCustomObject]@{
        RunHistoryCount = $runHistoryCount
        Instances       = @($instances)
    }
}

function Convert-ConfigInstance {
    param([Parameter(Mandatory)]$Instance)

    if ([string]::IsNullOrWhiteSpace($Instance.server)) {
        throw "Each instance must have a non-empty 'server'."
    }
    $displayName = if ([string]::IsNullOrWhiteSpace($Instance.name)) { $Instance.server } else { $Instance.name }

    $jobs = @()
    if ($Instance.jobs) {
        $jobs = foreach ($job in $Instance.jobs) {
            Convert-ConfigJob -Job $job -ServerName $displayName
        }
    }

    [PSCustomObject]@{
        Name   = $displayName
        Server = $Instance.server
        Jobs   = @($jobs)
    }
}

function Convert-ConfigJob {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$ServerName
    )

    if ([string]::IsNullOrWhiteSpace($Job.name)) {
        throw "A job under instance '$ServerName' is missing 'name'."
    }

    # Normalize schedule: either the string "daily" or an array of 3-letter day names.
    $schedule = $null
    if ($Job.schedule -is [string]) {
        if ($Job.schedule -ne 'daily') {
            throw "Job '$($Job.name)': string schedule must be 'daily' (got '$($Job.schedule)'). Use an array for specific days."
        }
        $schedule = 'daily'
    }
    elseif ($Job.schedule) {
        $days = @($Job.schedule)
        foreach ($d in $days) {
            if ($d -notin $script:ValidDayNames) {
                throw "Job '$($Job.name)': invalid day '$d'. Use: $($script:ValidDayNames -join ', ')."
            }
        }
        $schedule = $days
    }
    else {
        throw "Job '$($Job.name)': missing 'schedule'."
    }

    if ($Job.expectedStartTime -notmatch '^\d{1,2}:\d{2}$') {
        throw "Job '$($Job.name)': 'expectedStartTime' must be 'HH:mm' (got '$($Job.expectedStartTime)')."
    }

    [PSCustomObject]@{
        Name                     = $Job.name
        Schedule                 = $schedule
        ExpectedStartTime        = $Job.expectedStartTime
        EstimatedDurationMinutes = [int]$Job.estimatedDurationMinutes
        LookbackHours            = if ($Job.lookbackHours) { [int]$Job.lookbackHours } else { 24 }
    }
}
