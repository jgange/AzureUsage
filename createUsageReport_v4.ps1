# Program documentation




# Variable definitions

# Storage for Azure resources and subscriptions
$azureSubscriptions  = @()                                                                                        # Stores available subscriptions
$azureResources      = [System.Collections.ArrayList]@()                                                          # List of all accessible Azure resources across all subscriptions
$resourceUsageReport = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))    # Thread safe array to hold finally aggregated report data
$subQ                = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())                # queue to hold collection of subscriptions               

# Set max # of concurrent threads
$offset = 3
[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + $offset)


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

    $resource = $azureResources -match $resourceId

    $usageBySubscription = $azureUsageRecords.Where({ $_.SubscriptionId -eq $subscriptionId})

    if ($recordList = ($usageBySubscription -match $resourceId))
    {
        $usage = (($recordList | Measure-Object -Property Quantity -Sum).Sum)

        $entry = New-Object PSObject -Property ([ordered]@{
                "ResourceName"          = $resource.ResourceName
                "ResourceGroupName"     = $resource.ResourceGroupName
                "ResourceType"          = $resource.ResourceType
                "ResourceId"            = $resource.ResourceId
                "Location"              = $resource.Location
                "SKUName"               = $resource.Sku.Name
                "ParentResource"        = $resource.ParentResource
                "Status"                = $resource.Properties.provisioningstate
                "Usage"                 = $usage
                "Unit"                  = $recordList[-1].Unit
                "Meter Category"        = $recordList[-1]."Meter Category"
                "Meter SubCategory"     = $recordList[-1]."Meter SubCategory"
                "Meter Name"            = $recordList[-1]."Meter Name"
                })
         [void]$resourceUsageReport.Add($entry)
    }
    else
    {
          $entry = New-Object PSObject -Property ([ordered]@{
                "ResourceName"          = $resource.ResourceName
                "ResourceGroupName"     = $resource.ResourceGroupName
                "ResourceType"          = $resource.ResourceType
                "ResourceId"            = $resource.ResourceId
                "Location"              = $resource.Location
                "SKUName"               = $resource.Sku.Name
                "ParentResource"        = $resource.ParentResource
                "Status"                = $resource.Properties.provisioningstate
                "Usage"                 = 0
                "Unit"                  = "n/a"
                "Meter Category"        = "n/a"
                "Meter SubCategory"     = "n/a"
                "Meter Name"            = "n/a"
                })
         [void]$resourceUsageReport.Add($entry)
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


# Script block to associate the resource with the usage records
$scriptblock_report = {

    param(
        $subscriptionId,
        $azureResources,
        $azureUsageRecords,
        $resourceUsageReport,
        $subQ
    )

    While ($subQ.Count() -gt 0) {

        $subItem = $subQ.Dequeue()

        $subscriptionId = $subItem.Id
        $subName = $subItem.Name

        $resourcesBySubscription = $azureResources.Where({$_.SubscriptionId -eq $subscriptionId})
 
        $resourcesBySubscription.ResourceId | ForEach-Object { 
 
            $resource = $azureResources -match $resourceId

            $usageBySubscription = $azureUsageRecords.Where({ $_.SubscriptionId -eq $subscriptionId})

            if ($recordList = ($usageBySubscription -match $resourceId))
            {
                $usage = (($recordList | Measure-Object -Property Quantity -Sum).Sum)

                $entry = New-Object PSObject -Property ([ordered]@{
                    "ResourceName"          = $resource.ResourceName
                    "ResourceGroupName"     = $resource.ResourceGroupName
                    "ResourceType"          = $resource.ResourceType
                    "ResourceId"            = $resource.ResourceId
                    "Location"              = $resource.Location
                    "SKUName"               = $resource.Sku.Name
                    "ParentResource"        = $resource.ParentResource
                    "Status"                = $resource.Properties.provisioningstate
                    "Usage"                 = $usage
                    "Unit"                  = $recordList[-1].Unit
                    "Meter Category"        = $recordList[-1]."Meter Category"
                    "Meter SubCategory"     = $recordList[-1]."Meter SubCategory"
                    "Meter Name"            = $recordList[-1]."Meter Name"
                    })
                [System.Threading.Monitor]::Enter($resourceUsageReport.syncroot)
                [void]$resourceUsageReport.Add($entry)
                [System.Threading.Monitor]::Exit($resourceUsageReport.syncroot)
            }
            else
            {
                $entry = New-Object PSObject -Property ([ordered]@{
                    "ResourceName"          = $resource.ResourceName
                    "ResourceGroupName"     = $resource.ResourceGroupName
                    "ResourceType"          = $resource.ResourceType
                    "ResourceId"            = $resource.ResourceId
                    "Location"              = $resource.Location
                    "SKUName"               = $resource.Sku.Name
                    "ParentResource"        = $resource.ParentResource
                    "Status"                = $resource.Properties.provisioningstate
                    "Usage"                 = 0
                    "Unit"                  = "n/a"
                    "Meter Category"        = "n/a"
                    "Meter SubCategory"     = "n/a"
                    "Meter Name"            = "n/a"
                    })
                [System.Threading.Monitor]::Enter($resourceUsageReport.syncroot)
                [void]$resourceUsageReport.Add($entry)
                [System.Threading.Monitor]::Exit($resourceUsageReport.syncroot)
             }
    
        }

    } # End sub while loop

} # End Script Block

Write-Progress -Completed -Activity "Getting Usage data for all subscriptions"

Write-Host "Building final resource usage report."

$snum = 0

$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxpoolsize)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

# populate subQ with subscription entries
$subQ = $azureSubscriptions

$subQ

# Spin up tasks to get the usage data
    1..$azureSubscriptions.Count | ForEach-Object {
       $runspace = [PowerShell]::Create()
       $null = $runspace.AddScript($scriptblock_report)
       $null = $runspace.AddArgument($subscriptionId)
       $null = $runspace.AddArgument($azureResources)
       $null = $runspace.AddArgument($azureUsageRecords)
       $null = $runspace.AddArgument($resourceUsageReport)
       $null = $runspace.AddArgument($subQ)
       $runspace.RunspacePool = $pool
       $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
    }

# Check tasks status until they are complete, then close them
    while ($runspaces.Status -ne $null)
    {
       Write-Host "Subscriptions remaining: $($subQ.Count)"
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

# Output report
$resourceUsageReport