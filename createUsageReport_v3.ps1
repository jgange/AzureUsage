# Program documentation




# Variable definitions

# Storage for Azure resources and subscriptions
$azureSubscriptions  = @()
$azureResources      = [System.Collections.ArrayList]@()
$resourceUsageReport = [System.Collections.ArrayList]@()

# Set max # of concurrent threads
[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + 1)


# Storage for threaded usage data
$dateQ              = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureUsageRecords  = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# define information for usage data based on date range
$startDate = [datetime]"09-01-2021"
$endDate = [datetime]"10-01-2021"
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days

# Add the days to look up usage data
0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

# define script block to get Azure usage information
$scriptblock = {
 param(
        $dateQ,
        $azureUsageRecords
    )

    [datetime]$sd = $dateQ.Dequeue()
    $ed = $sd.AddDays(1)
    # Write-Output "Fetching usage records for $sd to $ed"

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

        ((Get-UsageAggregates @params).UsageAggregations | Select-Object -ExpandProperty Properties) | ForEach-Object {
        
            $ur = New-Object PSObject -Property ([ordered]@{
                "Resource Id"          = ((($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)).ToLower()
                "Meter Category"       = $_.MeterCategory
                "Meter Name"           = $_.MeterName
                "Meter SubCategory"    = $_.MeterSubCategory
                "Quantity"             = $_.Quantity
                "Unit"                 = $_.Unit
                "Usage Start Time"     = $_.UsageStartTime
                "Usage End Time"       = $_.UsageEndTime
                "Duration"             = ($_.UsageEndTime - $_.UsageStartTime).hours
                "SubscriptionId"       = ((($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri).split("/")[2]).ToLower()
            })

            [System.Threading.Monitor]::Enter($azureUsageRecords.syncroot)
            [void]$azureUsageRecords.Add($ur)
            [System.Threading.Monitor]::Exit($azureUsageRecords.syncroot)
        }

    } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)

}


# Retrieves resources from all accessible subscriptions
Function getAzureResources()
{
    $global:azureSubscriptions = Get-AzSubscription

    $snum = 0

    $global:azureSubscriptions | ForEach-Object {

        $pc = [math]::Round(($snum/$azureSubscriptions.Count)*100)

        Write-Progress -Activity "Getting Azure resources for all subscriptions" -Status "Working on subscription: $($_.Name) - Percent complete $pc%" -PercentComplete $pc

        $azs = $_.SubscriptionId
        # Write-Output "Setting subscription context to subscription $($_.Name) and retrieving all Azure resources"
        Set-AzContext -Subscription $_.SubscriptionId | Out-Null
        Get-AzResource | ForEach-Object {
            $resourceRecord = New-Object PSObject -Property ([ordered]@{
                "SubscriptionId"        = $azs.ToLower()
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
        $snum++
    }
}

Function getResourceUsage([string]$subscriptionId, [string]$resourceId)
{
    # filter the usage records by subscription to reduce the # of comparisons necessary

    $rname = ($azureResources -match $resourceId).ResourceName 

    $usageBySubscription = $azureUsageRecords.Where({ $_.SubscriptionId -eq $subscriptionId})

    if ($recordList = ($usageBySubscription -match $resourceId))
    {
        $usage = (($recordList | Measure-Object -Property Quantity -Sum).Sum)
        Write-Host "Resource = $rname  ---  Usage = $usage $($recordList[-1].Unit) for meter category $($recordList[-1]."Meter Category")"
        
        <#
        $recordList | ForEach-Object {
        [void]$resourceUsageReport.Add($_)
        }
        #>
    }

}


Function createUsageReport()
{
    # Stub
}

### Main Program ###

# Check if a connection to Azure exists
if (!($azc.Context.Tenant))
{
    $azc = Connect-AzAccount
}

# Retrieve all the Azure resources
Write-Host "Getting Azure resources by subscription"
getAzureResources

# Loop through subscriptions to get all the data

$snum = 0

$azureSubscriptions | ForEach-Object {

# Add the days to look up usage data
0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

# Create the Runspace pool and an empty array to store the runspaces
$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxpoolsize)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

$null = (Set-AzContext -Subscription $_.Id)

#Write-Host "Setting subscription to $($_.Name)"
$pc = [math]::Round(($snum/$azureSubscriptions.Count)*100)

Write-Progress -Activity "Getting Usage data for all subscriptions" -Status "Working on subscription: $($_.Name) - Percent complete $pc%" -PercentComplete $pc

# Spin up tasks to get the usage data
1..$numDays | ForEach-Object {
   $runspace = [PowerShell]::Create()
   $null = $runspace.AddScript($scriptblock)
   $null = $runspace.AddArgument($dateQ)
   $null = $runspace.AddArgument($azureUsageRecords)
   $runspace.RunspacePool = $pool
   $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
}

# Check tasks status until they are complete, then close them
while ($runspaces.Status -ne $null)
{
   $completed = $runspaces | Where-Object { $_.Status.IsCompleted -eq $true }
   foreach ($runspace in $completed)
   {
       $runspace.Pipe.EndInvoke($runspace.Status)
       $runspace.Status = $null
   }
}

# Clean up runspaces and free the memory for the pool

$runspaces.Clear()
$pool.Close()
$pool.Dispose()

$snum++

} # End subscription loop

Write-Progress -Completed -Activity "Getting Usage data for all subscriptions"

Write-Host "Building final resource usage report."

$azureSubscriptions | ForEach-Object {

    $subId = $_.Id
    $subName = $_.Name

    Write-Host "Looking up subscription usage data for $subName"

    $resourcesBySubscription = $azureResources.Where({$_.SubscriptionId -eq $subId})

    Write-Host "Returned $($resourcesBySubscription.Count) resources in $subName subscription."

    $resourcesBySubscription.ResourceId | ForEach-Object { 
        getResourceUsage $subId $_
    }

}
