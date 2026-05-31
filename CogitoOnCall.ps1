# TOOL_NAME: Congito On Call Helper
# TOOL_DESC: Checks important SQL Agent Jobs, etc.
# TOOL_ICON:📳
# TOOL_CATEGORY: Utilities
# TOOL_TYPE: gui

# CogitoOnCall.ps1 - Entry point for the Cogito On Call Helper.
#
#   pwsh -ExecutionPolicy Bypass -File .\CogitoOnCall.ps1
#
# WPF requires an STA thread. PowerShell 7 may launch MTA (e.g. when double-clicked),
# so if we are not on STA we re-invoke this script inside an STA runspace.

param([switch]$InStaThread)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

function Start-StaIfNeeded {
    # Returns $true if it handed off to an STA runspace (caller should exit).
    if ($InStaThread -or [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        return $false
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($root)
        & (Join-Path $root 'CogitoOnCall.ps1') -InStaThread
    }).AddArgument($scriptRoot)
    try {
        $ps.Invoke()
        foreach ($e in $ps.Streams.Error) { Write-Error $e }
    }
    finally {
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
    }
    return $true
}

if (Start-StaIfNeeded) { return }

# --- Load the layers (Config -> Database -> Analysis -> UI) ---
. (Join-Path $scriptRoot 'src/Config.ps1')
. (Join-Path $scriptRoot 'src/Database.ps1')
. (Join-Path $scriptRoot 'src/JobAnalysis.ps1')
. (Join-Path $scriptRoot 'src/UI.ps1')

function Invoke-CogitoScan {
    <#
        .SYNOPSIS
            Orchestrates a full scan: for each instance, connect (retry once), fetch
            msdb data, and analyze. Unreachable instances become a result with
            Reachable=$false rather than aborting the whole scan.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [datetime]$Now = (Get-Date)
    )

    $results = foreach ($inst in $Config.Instances) {
        # Fetch window: at least 7 days (so unlisted jobs' last run is found) and never
        # shorter than the largest per-job lookback plus a day of slack.
        $maxLookback = 24
        if ($inst.Jobs -and @($inst.Jobs).Count -gt 0) {
            $maxLookback = ($inst.Jobs | Measure-Object -Property LookbackHours -Maximum).Maximum
        }
        $sinceDt = $Now.AddDays(-7)
        $lookbackFloor = $Now.AddHours(-$maxLookback).AddDays(-1)
        if ($lookbackFloor -lt $sinceDt) { $sinceDt = $lookbackFloor }
        $sinceDate = [int]$sinceDt.ToString('yyyyMMdd')

        $conn = $null
        try {
            $conn = Connect-SqlInstance -Server $inst.Server
        }
        catch {
            [PSCustomObject]@{
                Name = $inst.Name; Server = $inst.Server; Reachable = $false
                Error = $_.Exception.Message; Jobs = @()
            }
            continue
        }

        try {
            $catalog = @(Get-AgentJobCatalog -Connection $conn)
            $history = @(Get-AgentJobHistory -Connection $conn -SinceDate $sinceDate)
            $running = @(Get-RunningAgentJobs -Connection $conn)
            $jobs = Get-InstanceJobStatuses -InstanceConfig $inst -Catalog $catalog `
                -History $history -RunningJobs $running -Now $Now -RunHistoryCount $Config.RunHistoryCount
            [PSCustomObject]@{
                Name = $inst.Name; Server = $inst.Server; Reachable = $true
                Error = $null; Jobs = @($jobs)
            }
        }
        catch {
            [PSCustomObject]@{
                Name = $inst.Name; Server = $inst.Server; Reachable = $false
                Error = "Query failed: $($_.Exception.Message)"; Jobs = @()
            }
        }
        finally {
            if ($conn) { $conn.Close(); $conn.Dispose() }
        }
    }

    @($results)
}

# --- Wire the Scan button to a fresh config read + scan each time ---
$configPath = Join-Path $scriptRoot 'config.json'

$onScan = {
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "config.json not found. Copy config.sample.json to config.json and edit it. (Expected: $configPath)"
    }
    $cfg = Read-CogitoConfig -Path $configPath
    Invoke-CogitoScan -Config $cfg
}.GetNewClosure()

Show-MainWindow -OnScan $onScan -ConfigPath $configPath
