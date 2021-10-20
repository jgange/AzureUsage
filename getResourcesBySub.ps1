$workQ             = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureResources    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

Write-Output "Getting Subscriptions..."

$elapsedTime = (Get-Date).Minute

$azureSubscriptions = Get-AzSubscription

$azureSubscriptions | ForEach-Object {
    $workQ.Enqueue($_.Id)
    Set-AzContext -Subscription $_.SubscriptionId | Out-Null
    $rg = Get-AzResourceGroup
    $workQ.Enqueue($rg.Count)
    $rg | ForEach-Object {
        $workQ.Enqueue($_.ResourceGroupName)
    }
}

# Start the dequeueing loop

while ($workQ.Count -gt 0)
{
    # Get subscription context
    $subId = $workQ.Dequeue()
    # Write-Output "Subscription Id: $subId"
    Set-AzContext -Subscription $subId | Out-Null
    $rgCount = $workQ.Dequeue()
    # Write-Output "# of resource groups $rgCount"
    if ($rgCount -gt 0) {
        1..$rgCount | ForEach-Object {
            $rgName = $workQ.Dequeue()
            # Write-Output "Fetching resources in resource group $rgName"
            $azResource = Get-AzResource -ResourceGroupName $rgName
            # Write-Output "Found $($azResource.Count) resources"
            [void]$azureResources.Add($azResource) 
        }
    }
}

$azureResources