# DataCheckAnalysis.ps1 - Pure analysis: evaluates a data check row against its config.
# No DB calls. Mirrors the pattern in JobAnalysis.ps1.

function Invoke-DataCheckAnalysis {
    param(
        [Parameter(Mandatory)]$Check,
        $Row   # PSCustomObject with Col1/Col2, or $null for no rows
    )

    if ($null -eq $Row) {
        $status = if ($Check.noDataIsFailure) { 'NoData' } else { 'NoDataGray' }
        return [PSCustomObject]@{
            Name               = $Check.name
            Status             = $status
            IsProblem          = $Check.noDataIsFailure
            Col1Label          = $Check.col1Label
            Col1Value          = $null
            Col2Label          = $Check.col2Label
            Col2Value          = $null
            ResultLabel        = $Check.resultLabel
            ResultValue        = $null
            Threshold          = $Check.threshold
            ThresholdDirection = $Check.thresholdDirection
            ErrorMessage       = $null
        }
    }

    $col1 = $Row.Col1
    $col2 = $Row.Col2

    $resultValue = $null
    try {
        $bothDateTime = ($col1 -is [datetime]) -and ($col2 -is [datetime])

        switch ($Check.operation) {
            'subtract' {
                $resultValue = if ($bothDateTime) {
                    [math]::Round(($col2 - $col1).TotalMinutes, 1)
                } else {
                    [math]::Round([double]$col2 - [double]$col1, 1)
                }
            }
            'divide' {
                $resultValue = [math]::Round([double]$col1 / [double]$col2, 1)
            }
            'absSubtract' {
                $resultValue = if ($bothDateTime) {
                    [math]::Round([math]::Abs(($col1 - $col2).TotalMinutes), 1)
                } else {
                    [math]::Round([math]::Abs([double]$col1 - [double]$col2), 1)
                }
            }
            'col1Only' {
                $resultValue = [math]::Round([double]$col1, 1)
            }
        }
    }
    catch {
        return [PSCustomObject]@{
            Name               = $Check.name
            Status             = 'Error'
            IsProblem          = $true
            Col1Label          = $Check.col1Label
            Col1Value          = $col1
            Col2Label          = $Check.col2Label
            Col2Value          = $col2
            ResultLabel        = $Check.resultLabel
            ResultValue        = $null
            Threshold          = $Check.threshold
            ThresholdDirection = $Check.thresholdDirection
            ErrorMessage       = $_.Exception.Message
        }
    }

    $passes = switch ($Check.thresholdDirection) {
        'lte' { $resultValue -le $Check.threshold }
        'gte' { $resultValue -ge $Check.threshold }
    }

    [PSCustomObject]@{
        Name               = $Check.name
        Status             = if ($passes) { 'OK' } else { 'Failed' }
        IsProblem          = (-not $passes)
        Col1Label          = $Check.col1Label
        Col1Value          = $col1
        Col2Label          = $Check.col2Label
        Col2Value          = $col2
        ResultLabel        = $Check.resultLabel
        ResultValue        = $resultValue
        Threshold          = $Check.threshold
        ThresholdDirection = $Check.thresholdDirection
        ErrorMessage       = $null
    }
}
