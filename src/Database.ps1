# Database.ps1 - SQL Server connectivity and msdb queries.
# Windows authentication only. Connection failures are retried once then surfaced
# to the caller (which marks the instance Unreachable). Raw run_date/run_time/run_duration
# integers are returned as-is; conversion to DateTime lives in JobAnalysis.ps1.

function New-SqlConnection {
    param(
        [Parameter(Mandatory)][string]$Server,
        [int]$ConnectTimeoutSeconds = 10
    )
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = 'msdb'
    $builder['Integrated Security'] = $true
    $builder['Connect Timeout'] = $ConnectTimeoutSeconds
    $builder['Application Name'] = 'Cogito On Call Helper'
    $builder['TrustServerCertificate'] = $true
    New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
}

function Invoke-SqlQuery {
    <#
        .SYNOPSIS
            Runs a query on an open connection and returns rows as PSCustomObjects.
    #>
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters,
        [int]$CommandTimeoutSeconds = 30
    )
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $CommandTimeoutSeconds
    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            [void]$cmd.Parameters.AddWithValue($key, $Parameters[$key])
        }
    }
    $table = New-Object System.Data.DataTable
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    try {
        [void]$adapter.Fill($table)
    }
    finally {
        $adapter.Dispose()
        $cmd.Dispose()
    }

    foreach ($row in $table.Rows) {
        $obj = [ordered]@{}
        foreach ($col in $table.Columns) {
            $val = $row[$col.ColumnName]
            if ($val -is [System.DBNull]) { $val = $null }
            $obj[$col.ColumnName] = $val
        }
        [PSCustomObject]$obj
    }
}

function Connect-SqlInstance {
    <#
        .SYNOPSIS
            Opens a connection, retrying once on failure (per spec).
        .OUTPUTS
            An open SqlConnection. Throws with the last error if both attempts fail.
    #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [int]$RetryCount = 1
    )
    $attempt = 0
    $lastError = $null
    while ($attempt -le $RetryCount) {
        $conn = New-SqlConnection -Server $Server
        try {
            $conn.Open()
            return $conn
        }
        catch {
            $lastError = $_
            $conn.Dispose()
            $attempt++
        }
    }
    throw "Could not connect to '$Server' after $($RetryCount + 1) attempt(s): $($lastError.Exception.Message)"
}

function Get-AgentJobCatalog {
    <#
        .SYNOPSIS
            Returns every Agent job with its enabled flag and whether it has any
            enabled schedule. Used to find unlisted enabled+scheduled jobs (Check 2).
    #>
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @'
SELECT
    j.name AS JobName,
    j.enabled AS JobEnabled,
    CAST(ISNULL(MAX(CAST(s.enabled AS int)), 0) AS int) AS HasEnabledSchedule
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
GROUP BY j.name, j.enabled
ORDER BY j.name
'@
    Invoke-SqlQuery -Connection $Connection -Query $query
}

function Get-AgentJobHistory {
    <#
        .SYNOPSIS
            Returns job-outcome history rows (step_id = 0) on or after the given date.
            run_date/run_time/run_duration are raw msdb integers.
        .PARAMETER SinceDate
            Integer yyyymmdd lower bound. Over-fetches slightly; callers filter
            precisely by each job's lookback window.
    #>
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][int]$SinceDate
    )

    $query = @'
SELECT
    j.name AS JobName,
    h.run_status AS RunStatus,
    h.run_date AS RunDate,
    h.run_time AS RunTime,
    h.run_duration AS RunDuration,
    h.message AS Message,
    h.instance_id AS InstanceId
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0
  AND h.run_date >= @sinceDate
ORDER BY j.name, h.instance_id DESC
'@
    Invoke-SqlQuery -Connection $Connection -Query $query -Parameters @{ '@sinceDate' = $SinceDate }
}

function Get-RunningAgentJobs {
    <#
        .SYNOPSIS
            Returns jobs currently executing (started, not yet stopped) in the latest
            Agent session. Used to detect Overdue/Running state.
    #>
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection)

    $query = @'
SELECT
    j.name AS JobName,
    ja.start_execution_date AS StartExecutionDate
FROM msdb.dbo.sysjobactivity ja
INNER JOIN msdb.dbo.sysjobs j ON j.job_id = ja.job_id
INNER JOIN (
    SELECT MAX(session_id) AS session_id FROM msdb.dbo.syssessions
) latest ON ja.session_id = latest.session_id
WHERE ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
'@
    Invoke-SqlQuery -Connection $Connection -Query $query
}
