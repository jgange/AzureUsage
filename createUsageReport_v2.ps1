# workQ holds the following information- a subscription id, the number of resource groups in that subscription, and the names of the resource groups
# this facilitates copy the resource data for all the subscriptions into a single array- azureResources

# dateQ holds each date of the specific range (e.g. 09-01-2021, 09-02-2021, etc.). It is used to support making the requests to get usage data
# in parallel. Each thread makes the call against a single day's worth of usage data. This data is stored in usageRecords.

# Call Properties.provisioningState to get the status of an Azure resource. Call -ExpandProperty Properties to get the remaining properties besides the base ones 

$dateQ             = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureResources    = [System.Collections.ArrayList]@()
$azureUsageRecords = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
#$usageRecords      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$usageRecords      = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())

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
    Write-Output "Inside Look up function. Using $resourceId for lookup."
    $recordList = $azureUsageRecords -match $resourceId
    $recordList
}

# Main Program Loop

Write-Output "Getting Subscriptions..."

$elapsedTime = (Get-Date).Minute

$azureSubscriptions = Get-AzSubscription

$azureSubscriptions | ForEach-Object {
    Write-Output "Setting subscription context to subscription $($_.Name) and retrieving all Azure resources"
    Set-AzContext -Subscription $_.SubscriptionId | Out-Null
    Get-AzResource | ForEach-Object {
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
        [System.Threading.Monitor]::Enter($usageRecords.syncroot)
        #[void]$usageRecords.Add($usageData)
        [void]$usageRecords.Enqueue($usageData)
        [System.Threading.Monitor]::Exit($usageRecords.syncroot)
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

# Necessary to break out the usage data into a single instance per record since it is stored in aggregate now

$usageAggregations = ($usageRecords.UsageAggregations |Select-Object -ExpandProperty Properties)
$usageRecordCount = $usageRecords.Count

$scriptblock = {

Param($usageAggregations, $azureUsageRecords)

 while( $usageRecords.Count -gt 0 ) {
    $resourceRecord = $usageAggregations.Dequeue()
    $resourceId = (($resourceRecord.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)

     $ur = New-Object PSObject -Property ([ordered]@{
        "Resource Id"          = $resourceId
        "Meter Category"       = $resourceRecord.MeterCategory
        "Meter Name"           = $resourceRecord.MeterName
        "Meter SubCategory"    = $resourceRecord.MeterSubCategory
        "Quantity"             = $resourceRecord.Quantity
        "Unit"                 = $resourceRecord.Unit
        "Usage Start Time"     = $resourceRecord.UsageStartTime
        "Usage End Time"       = $resourceRecord.UsageEndTime
        "Duration"             = ($resourceRecord.UsageEndTime - $resourceRecord.UsageStartTime).hours
    })
    
    [System.Threading.Monitor]::Enter($azureUsageRecords.syncroot)
    [void]$azureUsageRecords.Add($ur)
    [System.Threading.Monitor]::Exit($azureUsageRecords.syncroot)

    }
}

1..10 | ForEach-Object {
    $runspace = [PowerShell]::Create()
    $null = $runspace.AddScript($scriptblock)
    $null = $runspace.AddArgument($usageAggregations)
    $null = $runspace.AddArgument($azureUsageRecords)
    #$null = $runspace.AddArgument($uc)
    #$null = $runspace.AddArgument($i)
    #$null = $runspace.AddArgument($startTime)
    $runspace.RunspacePool = $pool
    $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
}

while ($runspaces.Status -ne $null)
{
   Write-Host "$($usageRecords.Count)/$($usageRecordCount)"
   $completed = $runspaces | Where-Object { $_.Status.IsCompleted -eq $true }
   foreach ($runspace in $completed)
      {
         $runspace.Pipe.EndInvoke($runspace.Status)
         $runspace.Status = $null
      }
}

$runspaces.Clear()
$pool.Close()
$pool.Dispose()

$azureResources | Select-Object -First 2 -Property ResourceId | getUsageByResource

#$azureResources | Export-Csv -Path $resourceFile -NoTypeInformation
#$usageRecords.UsageAggregations | Select-Object -ExpandProperty Properties | Export-Csv "C:\Users\jgange\Projects\PowerShell\UsageRecords.csv" -NoTypeInformation

