$usageData    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
# $resourceList = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

Function Get-AzureUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [datetime]$FromTime,
 
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [datetime]$ToTime,
 
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Hourly', 'Daily')]
        [string]$Interval = 'Daily'
    )
    
    Write-Verbose -Message "Querying usage data [$($FromTime) - $($ToTime)]..."
    $usageData = $null
    do {    
        $params = @{
            ReportedStartTime      = $FromTime
            ReportedEndTime        = $ToTime
            AggregationGranularity = $Interval
            ShowDetails            = $true
        }
        if ((Get-Variable -Name usageData -ErrorAction Ignore) -and $usageData) {
            Write-Verbose -Message "Querying usage data with continuation token $($usageData.ContinuationToken)..."
            $params.ContinuationToken = $usageData.ContinuationToken
        }
        $usageData = Get-UsageAggregates @params
        $usageData.UsageAggregations | Select-Object -ExpandProperty Properties
    } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)
}

$startDate = [datetime]"10-04-2021"
$endDate   = [datetime]"10-05-2021"
$interval = 'Hourly'
$Switch = ''



$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, 5)
$RunspacePool.Open()

$ScriptBlock = {
    param ($[
    $usage = Get-AzureUsage -FromTime $startDate -ToTime $endDate -Interval $interval
}

$Runspaces = @()
(1..10) | ForEach-Object {
    $Runspace = [powershell]::Create().AddScript($ScriptBlock)
    $Runspace.RunspacePool = $RunspacePool
    $Runspaces += New-Object PSObject -Property @{
        Runspace = $Runspace
        State = $Runspace.BeginInvoke()
    }
}

while ( $Runspaces.State.IsCompleted -contains $False) { Start-Sleep -Milliseconds 10 }

$Results = @()

$Runspaces | ForEach-Object {
    $Results += $_.Runspace.EndInvoke($_.State)
}
