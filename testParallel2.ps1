# Create an empty synchronized queue
$ServerQueue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())

# Add some fake servers to the queue
1..25 | ForEach-Object {
    $ServerQueue.Enqueue("Server$($_)")
}

$QueueCount = $ServerQueue.Count

# Create some fake work
$ScriptBlock = {
    param (
        $ServerQueue
    )

    while( $ServerQueue.Count -gt 0 ) {
        $Server = $ServerQueue.Dequeue()
        Write-Output "Starting work on $($Server)"
        Start-Sleep -Seconds $(Get-Random -Minimum 1 -Maximum 4)
        Write-Output "Work Complete"
    }
}

$Inputs = New-Object 'System.Management.Automation.PSDataCollection[PSObject]'
$Results = New-Object 'System.Management.Automation.PSDataCollection[PSObject]'

#Spin up 4 runspaces to process the work
$Instances = @()
(1..4) | ForEach-Object {
    $Instance = [powershell]::Create().AddScript($ScriptBlock).AddParameter('ServerQueue', $ServerQueue)
    $Instances += New-Object PSObject -Property @{
        Instance = $Instance
        State = $Instance.BeginInvoke($Inputs,$Results)
    }
}

# Lets loop and wait for work to complete
while ( $Instances.State.IsCompleted -contains $False) {
    # Report the servers left in the queue
    Write-Host "Server(s) Remaining: $($ServerQueue.Count)/$($QueueCount)"
    Start-Sleep -Milliseconds 1000
}