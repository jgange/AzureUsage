# workQ holds the following information- a subscription id, the number of resource groups in that subscription, and the names of the resource groups
# this facilitates copy the resource data for all the subscriptions into a single array- azureResources

# dateQ holds each date of the specific range (e.g. 09-01-2021, 09-02-2021, etc.). It is used to support making the requests to get usage data
# in parallel. Each thread makes the call against a single day's worth of usage data. This data is stored in usageRecords.

# Call Properties.provisioningState to get the status of an Azure resource. Call -ExpandProperty Properties to get the remaining properties besides the base ones 

$workQ             = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$dateQ             = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureResources    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$usageRecords      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

$bypass            = $false
$dataPath          = "C:\Users\jgange\Projects\PowerShell"
$resourceFile      = $dataPath + "\AzureResources.csv"
$usageFile         = $dataPath + "\AzureUsage.csv"

$startDate = [datetime]"09-01-2021"
$endDate = [datetime]"10-01-2021"
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days
[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + 1)

Function getUsageByResource($resourceId)
{
    <#
    Get the resource
    Look up the subscription Id
    Return the matching usageRecord objects
    Search through those objects for a matching resource ID
    #>
    Write-Output "Inside lookup function."
    $azureResources | Select-Object -First 2
    

}

# Main Program Loop

if (!($bypass))
{

Write-Output "Getting Subscriptions..."

$elapsedTime = (Get-Date).Minute

$azureSubscriptions = Get-AzSubscription

Write-Output "Getting resource groups per subscription..."
$azureSubscriptions | ForEach-Object {
    $workQ.Enqueue($_.Id)
    Write-Output "Setting subscription context to subscription $($_.Name)"
    Set-AzContext -Subscription $_.SubscriptionId | Out-Null
    Write-Output "Getting groups for Subscription $($_.Name)"
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
            if ($azResource) {
            $azResource | ForEach-Object {
                    $resourceRecord = New-Object PSObject -Property ([ordered]@{
                        "ResourceName"          = $_.ResourceName
                        "ResourceGroupName"     = $_.ResourceGroupName
                        "ResourceType"          = $_.ResourceType
                        "ResourceId"            = $_.ResourceId
                        "Location"              = $_.Location
                        "SKUName"               = $_.Sku.Name
                        "ParentResource"        = $_.ParentResource
                        "Status"                = $_.Properties.provisioningstate 

                    })
                    [void]$azureResources.Add($resourceRecord)
                }
            }
        }
    }
}


# Retrieve usage information

0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxpoolsize)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

Write-Output "Getting Subscriptions..."
$azureSubscriptions = Get-AzSubscription

$scriptblock = {
 param(
        $dateQ,
        $usageRecords,
        $subscriptionId
    )
    [datetime]$sd = $dateQ.Dequeue()
    $ed = $sd.AddDays(1)
    Write-Output "Fetching usage records for $sd to $ed"

    do {    
        ## Define all parameters to pass to Get-UsageAggregates
        $params = @{
            ReportedStartTime      = $sd
            ReportedEndTime        = $ed
            AggregationGranularity = "Hourly"
            ShowDetails            = $true
        }
        ## Only use the ContinuationToken parameter if this is not the first run
        if ((Get-Variable -Name usageData -ErrorAction Ignore) -and $usageData) {
            Write-Verbose -Message "Querying usage data with continuation token $($usageData.ContinuationToken)..."
            $params.ContinuationToken = $usageData.ContinuationToken
        }
        $usageData = Get-UsageAggregates @params
        $usageData | Add-Member -NotePropertyName SubscriptionID -NotePropertyValue $subscriptionId
        # $usageData.UsageAggregations | Select-Object -ExpandProperty Properties
        [System.Threading.Monitor]::Enter($usageRecords.syncroot)
        [void]$usageRecords.Add($usageData)
        [System.Threading.Monitor]::Exit($usageRecords.syncroot)
        Write-Output "Returned $($usageData.count) usage records"
    } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)

}

# spin up the threads

$azureSubscriptions | ForEach-Object {
    
    $subscriptionId = $_.SubscriptionId
    Write-Output "Getting usage data for subscription $($_.Name)"
    Set-AzContext -Subscription $subscriptionId | Out-Null

    1..$numDays | ForEach-Object {
        $runspace = [PowerShell]::Create()
        $null = $runspace.AddScript($scriptblock)
        $null = $runspace.AddArgument($dateQ)
        $null = $runspace.AddArgument($usageRecords)
        $null = $runspace.AddArgument($subscriptionId)
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

}  # Subscription Loop

$runspaces.Clear()
$pool.Close()
$pool.Dispose()

}  # Bypass the entire data gathering loop since we're using what's in memory

# getUsageByResource -resourceId "/subscriptions/e91b6d6a-70db-4d28-a270-df1027772394/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_eastus2"

$azureResources | Export-Csv -Path $resourceFile -NoTypeInformation
$usageRecords.UsageAggregations | Select-Object -ExpandProperty Properties | Export-Csv "C:\Users\jgange\Projects\PowerShell\UsageRecords.csv" -NoTypeInformation

