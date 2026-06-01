# DataCheck.ps1 - Executes a configured data check query against an open connection.
# Mirrors the pattern in Database.ps1. Returns Col1/Col2 from the first row, or $null.

function Invoke-DataCheckQuery {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)]$Check
    )

    $rows = @(Invoke-SqlQuery -Connection $Connection -Query $Check.query)
    if ($rows.Count -eq 0) { return $null }

    $props = @($rows[0].PSObject.Properties)
    [PSCustomObject]@{
        Col1 = $props[0].Value
        Col2 = if ($props.Count -gt 1) { $props[1].Value } else { $null }
    }
}
