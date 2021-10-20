$usageData    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

$startDate = [datetime]"09-01-2021"
$endDate = [datetime]"10-01-2021"
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days

Write-Output "Starting values:"
Write-Output "Offset = $($offSet) Start date= $($startDate.AddDays($offSet)) End date  = $($endDate)"

$ScriptBlock = {
    param(
        [ref]$offset
    )
    $offset.Value = $offset.Value + 1
    Write-Verbose "Offset = $($offset) Start date= $($startDate.AddDays($offset)) End date  = $($endDate)" -Verbose
    Start-Sleep -Seconds 2
}

### Runspace code

$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, 5)
$RunspacePool.Open()

$Runspaces = @()
(1..$numDays) | ForEach-Object {
    $Runspace = [powershell]::Create().AddScript($ScriptBlock)
    $Runspace.AddArgument([ref]$offset)
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