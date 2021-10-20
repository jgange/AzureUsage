[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + 1)
<#
$azureSubscriptions = Get-AzSubscription

$azureSubscriptions | ForEach-Object {
    Set-AzContext -Subscription $_.SubscriptionId
    Get-AzResourceGroup
}
#>

# Create a synchronized collection to be used for parallel operations
$resourceGroupsQ   = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureResources    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

Get-AzResourceGroup | ForEach-Object { 
    $resourceGroupsQ.EnQueue($_.ResourceGroupName)
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxpoolsize)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

$scriptblock = {
    param($resourceGroupsQ, $azureResources)
    While ($resourceGroupsQ.Count -gt 0) {
        $rgName = $resourceGroupsQ.Dequeue()
        $result = Get-AzResource -ResourceGroupName $rgName
        [System.Threading.Monitor]::Enter($azureResources.syncroot)
        [void]$azureResources.Add($result)
        [System.Threading.Monitor]::Exit($azureResources.syncroot)
    }
}

$Inputs = New-Object 'System.Management.Automation.PSDataCollection[PSObject]'
$Results = New-Object 'System.Management.Automation.PSDataCollection[PSObject]'

$Instances = @()
(1..10) | ForEach-Object {
    $Instance = [powershell]::Create().AddScript($scriptblock).AddArgument($resourceGroupsQ).AddArgument($azureResources)
    $Instances += New-Object PSObject -Property @{
        Instance = $Instance
        State = $Instance.BeginInvoke($Inputs,$Results)
    }
}

while ( $Instances.State.IsCompleted -contains $False) {
    # Report the servers left in the queue
    Write-Host "Resource groups to process $($resourceGroupsQ.Count)"
    Start-Sleep -Milliseconds 1000
}

$azureResources.Count

$pool.Close()
$pool.Dispose()

