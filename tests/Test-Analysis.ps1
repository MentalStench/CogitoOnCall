# Test-Analysis.ps1 - Standalone smoke test for the pure analysis + config layers.
# No SQL Server required: feeds mock msdb-shaped data through the flag logic.
#   pwsh -NoProfile -File .\tests\Test-Analysis.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/Config.ps1')
. (Join-Path $root 'src/JobAnalysis.ps1')

$script:Pass = 0
$script:Fail = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:Fail++; Write-Host "  FAIL  $Name  (expected '$Expected', got '$Actual')" -ForegroundColor Red
    }
}

# Fixed "now": 2026-05-29 09:00:00
$now = [datetime]::new(2026, 5, 29, 9, 0, 0)
$todayInt = [int]$now.ToString('yyyyMMdd')
$todayAbbr = @('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[[int]$now.DayOfWeek]
$otherDay = if ($todayAbbr -eq 'Mon') { 'Tue' } else { 'Mon' }

function New-HistRow {
    param([string]$JobName, [int]$Time, [int]$Duration, [int]$Status, [string]$Message = '')
    [PSCustomObject]@{
        JobName = $JobName; RunStatus = $Status; RunDate = $todayInt
        RunTime = $Time; RunDuration = $Duration; Message = $Message; InstanceId = 1
    }
}

Write-Host "`n== Conversion helpers ==" -ForegroundColor Cyan
$dt = ConvertFrom-AgentDateTime -RunDate 20260529 -RunTime 20000
Assert-Equal '2026-05-29 02:00:00' $dt.ToString('yyyy-MM-dd HH:mm:ss') 'ConvertFrom-AgentDateTime'
$ts = ConvertFrom-AgentDuration -RunDuration 13045
Assert-Equal '01:30:45' $ts.ToString() 'ConvertFrom-AgentDuration'

Write-Host "`n== Schedule evaluation ==" -ForegroundColor Cyan
Assert-Equal $true (Test-ScheduledToday -Schedule 'daily' -ReferenceDate $now) 'daily is scheduled'
Assert-Equal $true (Test-ScheduledToday -Schedule @($todayAbbr) -ReferenceDate $now) 'today in array'
Assert-Equal $false (Test-ScheduledToday -Schedule @($otherDay) -ReferenceDate $now) 'other day not scheduled'

# --- Build config jobs covering every flag ---
$cfgJobs = @(
    [PSCustomObject]@{ Name='JobOK';        Schedule='daily'; ExpectedStartTime='02:00'; EstimatedDurationMinutes=45; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobFailed';    Schedule='daily'; ExpectedStartTime='02:00'; EstimatedDurationMinutes=30; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobLate';      Schedule='daily'; ExpectedStartTime='02:00'; EstimatedDurationMinutes=30; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobDidNotRun'; Schedule='daily'; ExpectedStartTime='02:00'; EstimatedDurationMinutes=30; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobPending';   Schedule='daily'; ExpectedStartTime='23:00'; EstimatedDurationMinutes=30; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobOverdue';   Schedule='daily'; ExpectedStartTime='08:00'; EstimatedDurationMinutes=30; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobRunning';   Schedule='daily'; ExpectedStartTime='08:50'; EstimatedDurationMinutes=30; LookbackHours=12 }
    [PSCustomObject]@{ Name='JobNotSched';  Schedule=@($otherDay); ExpectedStartTime='02:00'; EstimatedDurationMinutes=30; LookbackHours=12 }
)
$instConfig = [PSCustomObject]@{ Name='Test'; Server='localhost'; Jobs=$cfgJobs }

$history = @(
    New-HistRow -JobName 'JobOK'     -Time 20000 -Duration 3000  -Status 1               # 02:00 +30m -> 02:30 OK
    New-HistRow -JobName 'JobFailed' -Time 20000 -Duration 500   -Status 0 -Message 'Step 1 failed: timeout'
    New-HistRow -JobName 'JobLate'   -Time 20000 -Duration 10000 -Status 1               # 02:00 +1h -> 03:00 > 02:30 LATE
    # JobDidNotRun: no row
    # JobPending: no row
    # JobOverdue / JobRunning: running, no completed row
    New-HistRow -JobName 'UnlistedFailing' -Time 10000 -Duration 200 -Status 0 -Message 'boom'
    New-HistRow -JobName 'UnlistedOK'      -Time 10000 -Duration 200 -Status 1
)
$running = @(
    [PSCustomObject]@{ JobName='JobOverdue'; StartExecutionDate=$now.AddHours(-2) }
    [PSCustomObject]@{ JobName='JobRunning'; StartExecutionDate=$now.AddMinutes(-5) }
)
$catalog = @(
    [PSCustomObject]@{ JobName='JobOK';           JobEnabled=1; HasEnabledSchedule=1 }
    [PSCustomObject]@{ JobName='UnlistedFailing'; JobEnabled=1; HasEnabledSchedule=1 }  # not in config -> checked
    [PSCustomObject]@{ JobName='UnlistedOK';      JobEnabled=1; HasEnabledSchedule=1 }
    [PSCustomObject]@{ JobName='DisabledJob';     JobEnabled=0; HasEnabledSchedule=1 }  # excluded
    [PSCustomObject]@{ JobName='NoScheduleJob';   JobEnabled=1; HasEnabledSchedule=0 }  # excluded
)

Write-Host "`n== Config job flags ==" -ForegroundColor Cyan
$statuses = Get-InstanceJobStatuses -InstanceConfig $instConfig -Catalog $catalog -History $history -RunningJobs $running -Now $now -RunHistoryCount 5
$byName = @{}
foreach ($s in $statuses) { $byName[$s.JobName] = $s }

Assert-Equal 'OK'            $byName['JobOK'].Status        'JobOK -> OK'
Assert-Equal 'Failed'        $byName['JobFailed'].Status    'JobFailed -> Failed'
Assert-Equal 'SucceededLate' $byName['JobLate'].Status      'JobLate -> SucceededLate'
Assert-Equal 'DidNotRun'     $byName['JobDidNotRun'].Status 'JobDidNotRun -> DidNotRun'
Assert-Equal 'Pending'       $byName['JobPending'].Status   'JobPending -> Pending'
Assert-Equal 'Overdue'       $byName['JobOverdue'].Status   'JobOverdue -> Overdue'
Assert-Equal 'Running'       $byName['JobRunning'].Status   'JobRunning -> Running'
Assert-Equal 'NotScheduled'  $byName['JobNotSched'].Status  'JobNotSched -> NotScheduled'

Write-Host "`n== Unlisted job checks (Check 2) ==" -ForegroundColor Cyan
Assert-Equal 'Failed' $byName['UnlistedFailing'].Status 'UnlistedFailing -> Failed'
Assert-Equal 'OK'     $byName['UnlistedOK'].Status      'UnlistedOK -> OK'
Assert-Equal $false   ($byName.ContainsKey('DisabledJob'))   'DisabledJob excluded'
Assert-Equal $false   ($byName.ContainsKey('NoScheduleJob')) 'NoScheduleJob excluded'
Assert-Equal $false   $byName['UnlistedFailing'].Listed 'Unlisted job marked Listed=false'

Write-Host "`n== Config loading + validation ==" -ForegroundColor Cyan
$sample = Read-CogitoConfig -Path (Join-Path $root 'config.sample.json')
Assert-Equal 2 $sample.Instances.Count 'sample has 2 instances'
Assert-Equal 5 $sample.RunHistoryCount 'sample runHistoryCount = 5'

function Test-Throws { param([scriptblock]$Block, [string]$Name)
    $threw = $false; try { & $Block } catch { $threw = $true }
    Assert-Equal $true $threw $Name
}
$tmp = Join-Path $env:TEMP 'cogito-bad.json'
'{ "instances": [ { "server": "s", "jobs": [ { "name": "j", "schedule": "weekly", "expectedStartTime": "02:00" } ] } ] }' | Set-Content $tmp
Test-Throws { Read-CogitoConfig -Path $tmp } 'invalid string schedule rejected'
'{ "instances": [ { "server": "s", "jobs": [ { "name": "j", "schedule": "daily", "expectedStartTime": "2am" } ] } ] }' | Set-Content $tmp
Test-Throws { Read-CogitoConfig -Path $tmp } 'invalid time format rejected'
'{ "instances": [ { "server": "s", "jobs": [ { "name": "j", "schedule": ["Funday"], "expectedStartTime": "02:00" } ] } ] }' | Set-Content $tmp
Test-Throws { Read-CogitoConfig -Path $tmp } 'invalid day name rejected'
Remove-Item $tmp -ErrorAction SilentlyContinue

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass   Failed: $script:Fail" -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 }
