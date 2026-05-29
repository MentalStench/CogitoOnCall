# UI.ps1 - WPF presentation layer. Built programmatically so status pills, colors,
# and expand-in-place job rows are fully under our control. The UI is decoupled from
# the data layer: Show-MainWindow takes an -OnScan callback that returns instance results.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Status -> color + display label. Problems are red; OK green; transient states gray/blue.
$script:StatusVisuals = @{
    'OK'            = @{ Color = '#2E7D32'; Label = 'OK' }
    'Failed'        = @{ Color = '#C62828'; Label = 'FAILED' }
    'DidNotRun'     = @{ Color = '#C62828'; Label = 'DID NOT RUN' }
    'Overdue'       = @{ Color = '#C62828'; Label = 'OVERDUE' }
    'SucceededLate' = @{ Color = '#EF6C00'; Label = 'LATE' }
    'Running'       = @{ Color = '#1565C0'; Label = 'RUNNING' }
    'Pending'       = @{ Color = '#546E7A'; Label = 'PENDING' }
    'NotScheduled'  = @{ Color = '#757575'; Label = 'NOT SCHEDULED' }
    'NoRecentRuns'  = @{ Color = '#757575'; Label = 'NO RECENT RUNS' }
    'Unreachable'   = @{ Color = '#EF6C00'; Label = 'UNREACHABLE' }
}

function New-Brush {
    param([string]$Hex)
    [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function Get-StatusVisual {
    param([string]$Status)
    if ($script:StatusVisuals.ContainsKey($Status)) { return $script:StatusVisuals[$Status] }
    @{ Color = '#757575'; Label = $Status.ToUpper() }
}

function New-StatusPill {
    param([string]$Status, [double]$MinWidth = 120)
    $v = Get-StatusVisual -Status $Status
    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = $v.Label
    $text.Foreground = [System.Windows.Media.Brushes]::White
    $text.FontWeight = 'Bold'
    $text.FontSize = 11
    $text.HorizontalAlignment = 'Center'
    $text.TextAlignment = 'Center'

    $border = New-Object System.Windows.Controls.Border
    $border.Background = New-Brush $v.Color
    $border.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $border.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
    $border.MinWidth = $MinWidth
    $border.VerticalAlignment = 'Center'
    $border.Child = $text
    $border
}

function New-TextBlock {
    param([string]$Text, [int]$FontSize = 12, [string]$Weight = 'Normal', [string]$Foreground = '#212121', [bool]$Wrap = $false)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $FontSize
    $tb.FontWeight = $Weight
    $tb.Foreground = New-Brush $Foreground
    $tb.VerticalAlignment = 'Center'
    if ($Wrap) { $tb.TextWrapping = 'Wrap' }
    $tb
}

function New-JobExpander {
    param([Parameter(Mandatory)]$Job)

    # --- Header: pill + job name + right-aligned one-line summary ---
    $header = New-Object System.Windows.Controls.Grid
    $header.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
    $colPill = New-Object System.Windows.Controls.ColumnDefinition; $colPill.Width = 'Auto'
    $colName = New-Object System.Windows.Controls.ColumnDefinition; $colName.Width = '*'
    $colInfo = New-Object System.Windows.Controls.ColumnDefinition; $colInfo.Width = 'Auto'
    [void]$header.ColumnDefinitions.Add($colPill)
    [void]$header.ColumnDefinitions.Add($colName)
    [void]$header.ColumnDefinitions.Add($colInfo)

    $pill = New-StatusPill -Status $Job.Status
    [System.Windows.Controls.Grid]::SetColumn($pill, 0)
    [void]$header.Children.Add($pill)

    $nameWeight = if ($Job.IsProblem) { 'Bold' } else { 'Normal' }
    $name = New-TextBlock -Text $Job.JobName -FontSize 13 -Weight $nameWeight
    $name.Margin = [System.Windows.Thickness]::new(10, 0, 10, 0)
    if (-not $Job.Listed) { $name.FontStyle = 'Italic' }   # unlisted jobs shown in italic
    [System.Windows.Controls.Grid]::SetColumn($name, 1)
    [void]$header.Children.Add($name)

    $summaryText = $Job.Detail
    $summary = New-TextBlock -Text $summaryText -FontSize 11 -Foreground '#616161'
    [System.Windows.Controls.Grid]::SetColumn($summary, 2)
    [void]$header.Children.Add($summary)

    # --- Expander ---
    $exp = New-Object System.Windows.Controls.Expander
    $exp.Header = $header
    $exp.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
    $exp.Background = New-Brush '#FAFAFA'

    # --- Content: detail, error message, recent run history ---
    $content = New-Object System.Windows.Controls.StackPanel
    $content.Margin = [System.Windows.Thickness]::new(30, 6, 10, 10)

    if (-not $Job.Listed) {
        $tag = New-TextBlock -Text 'Not in config (enabled + scheduled job).' -FontSize 11 -Foreground '#9E9E9E'
        [void]$content.Children.Add($tag)
    }

    # Error message for failed runs
    if ($Job.LastRun -and $Job.LastRun.Message -and $Job.Status -eq 'Failed') {
        $errLabel = New-TextBlock -Text 'Error message:' -Weight 'Bold' -FontSize 11
        $errLabel.Margin = [System.Windows.Thickness]::new(0, 4, 0, 2)
        [void]$content.Children.Add($errLabel)

        $err = New-Object System.Windows.Controls.TextBox
        $err.Text = [string]$Job.LastRun.Message
        $err.IsReadOnly = $true
        $err.TextWrapping = 'Wrap'
        $err.BorderThickness = [System.Windows.Thickness]::new(0)
        $err.Background = New-Brush '#FFF3E0'
        $err.Foreground = New-Brush '#BF360C'
        $err.Padding = [System.Windows.Thickness]::new(6)
        $err.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        [void]$content.Children.Add($err)
    }

    # Recent run history
    $histLabel = New-TextBlock -Text 'Recent runs:' -Weight 'Bold' -FontSize 11
    $histLabel.Margin = [System.Windows.Thickness]::new(0, 4, 0, 2)
    [void]$content.Children.Add($histLabel)

    if ($Job.History -and $Job.History.Count -gt 0) {
        foreach ($run in $Job.History) {
            $line = '{0}   *   {1}   *   {2}' -f `
                $run.Start.ToString('yyyy-MM-dd HH:mm:ss'),
                $run.Duration.ToString(),
                $run.Outcome
            $color = if ($run.Status -eq 1) { '#2E7D32' } else { '#C62828' }
            [void]$content.Children.Add((New-TextBlock -Text $line -FontSize 11 -Foreground $color))
        }
    }
    else {
        [void]$content.Children.Add((New-TextBlock -Text 'No run history available.' -FontSize 11 -Foreground '#9E9E9E'))
    }

    $exp.Content = $content
    $exp
}

function New-InstanceSection {
    param([Parameter(Mandatory)]$Instance)

    $outer = New-Object System.Windows.Controls.Border
    $outer.BorderBrush = New-Brush '#E0E0E0'
    $outer.BorderThickness = [System.Windows.Thickness]::new(1)
    $outer.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $outer.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $outer.Padding = [System.Windows.Thickness]::new(10)

    $stack = New-Object System.Windows.Controls.StackPanel

    # Instance header row
    $headerRow = New-Object System.Windows.Controls.StackPanel
    $headerRow.Orientation = 'Horizontal'
    $headerRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

    $title = New-TextBlock -Text $Instance.Name -FontSize 16 -Weight 'Bold'
    [void]$headerRow.Children.Add($title)

    $server = New-TextBlock -Text "  ($($Instance.Server))" -FontSize 12 -Foreground '#757575'
    [void]$headerRow.Children.Add($server)

    if (-not $Instance.Reachable) {
        $pill = New-StatusPill -Status 'Unreachable' -MinWidth 100
        $pill.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        [void]$headerRow.Children.Add($pill)
    }
    else {
        $count = @($Instance.Jobs | Where-Object { $_.IsProblem }).Count
        $summaryColor = if ($count -gt 0) { '#C62828' } else { '#2E7D32' }
        $summaryText = if ($count -gt 0) { "  $count issue(s)" } else { '  All clear' }
        [void]$headerRow.Children.Add((New-TextBlock -Text $summaryText -FontSize 12 -Weight 'Bold' -Foreground $summaryColor))
    }
    [void]$stack.Children.Add($headerRow)

    if (-not $Instance.Reachable) {
        $errBox = New-TextBlock -Text $Instance.Error -FontSize 12 -Foreground '#BF360C' -Wrap $true
        [void]$stack.Children.Add($errBox)
    }
    else {
        # Problems first, then by name.
        $sorted = $Instance.Jobs | Sort-Object @{ Expression = { -not $_.IsProblem } }, JobName
        foreach ($job in $sorted) {
            [void]$stack.Children.Add((New-JobExpander -Job $job))
        }
        if (@($Instance.Jobs).Count -eq 0) {
            [void]$stack.Children.Add((New-TextBlock -Text 'No jobs to report.' -FontSize 12 -Foreground '#9E9E9E'))
        }
    }

    $outer.Child = $stack
    $outer
}

function Update-ResultsView {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Panel]$Panel,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results
    )
    $Panel.Children.Clear()
    foreach ($inst in $Results) {
        [void]$Panel.Children.Add((New-InstanceSection -Instance $inst))
    }
}

function Show-MainWindow {
    <#
        .SYNOPSIS
            Builds and shows the main window. -OnScan is a scriptblock returning an
            array of instance result objects; it is invoked when Scan is clicked.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$OnScan,
        [string]$ConfigPath
    )

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Cogito On Call Helper" Height="720" Width="940"
        WindowStartupLocation="CenterScreen" Background="#F5F5F5">
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#263238" Padding="12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="ScanButton" Grid.Column="0" Content="Scan" Width="110" Height="36"
                FontSize="14" FontWeight="Bold" Background="#00897B" Foreground="White" BorderThickness="0"/>
        <TextBlock x:Name="StatusText" Grid.Column="1" Foreground="#ECEFF1" FontSize="13"
                   VerticalAlignment="Center" Margin="16,0,0,0" Text="Click Scan to check SQL Agent jobs."/>
      </Grid>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="InstancesPanel" Margin="14"/>
    </ScrollViewer>
  </DockPanel>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $scanButton = $window.FindName('ScanButton')
    $statusText = $window.FindName('StatusText')
    $panel = $window.FindName('InstancesPanel')

    $scanButton.Add_Click({
        $scanButton.IsEnabled = $false
        $statusText.Text = 'Scanning...'
        # Flush the render queue so the "Scanning..." state is visible during the synchronous scan.
        $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
        try {
            $results = & $OnScan
            Update-ResultsView -Panel $panel -Results @($results)
            $problemCount = 0
            foreach ($r in $results) {
                if (-not $r.Reachable) { $problemCount++ }
                else { $problemCount += @($r.Jobs | Where-Object { $_.IsProblem }).Count }
            }
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $statusText.Text = if ($problemCount -gt 0) {
                "Last scan $stamp - $problemCount item(s) need attention."
            } else {
                "Last scan $stamp - all jobs healthy."
            }
        }
        catch {
            $statusText.Text = "Scan failed: $($_.Exception.Message)"
        }
        finally {
            $scanButton.IsEnabled = $true
        }
    }.GetNewClosure())

    [void]$window.ShowDialog()
}
