$startDate = [datetime]"09-01-2021"
$endDate = [datetime]"10-01-2021"
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days

$dateQ        = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$usageRecords = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, [int]$env:NUMBER_OF_PROCESSORS + 1)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

$scriptblock = {
 param(
        $dateQ,
        $usageRecords
    )
    [datetime]$sd = $dateQ.Dequeue()
    $ed = $sd.AddDays(1)
    Write-Output "Fetching usage records for $sd to $ed"
    $r = (Get-UsageAggregates -ReportedStartTime $sd -ReportedEndTime $ed -ShowDetails $true -AggregationGranularity Hourly).UsageAggregations | Select-Object -ExpandProperty Properties
    [System.Threading.Monitor]::Enter($usageRecords.syncroot)
    [void]$usageRecords.Add($r)
    Write-Output "Returned $($r.count) usage records"
    [System.Threading.Monitor]::Exit($usageRecords.syncroot)
}

1..$numDays | ForEach-Object {
    $runspace = [PowerShell]::Create()
    $null = $runspace.AddScript($scriptblock)
    $null = $runspace.AddArgument($dateQ)
    $null = $runspace.AddArgument($usageRecords)
    $runspace.RunspacePool = $pool
    $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
}

while ($runspaces.Status -ne $null)
{
    $completed = $runspaces | Where-Object { $_.Status.IsCompleted -eq $true }
    foreach ($runspace in $completed)
    {
        $runspace.Pipe.EndInvoke($runspace.Status)
        $runspace.Status = $null
    }
}

$pool.Close()
$pool.Dispose()

$usageRecords

$resourceList = (($usageRecords.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri) | Sort-Object | Get-Unique

$resourceList.Count