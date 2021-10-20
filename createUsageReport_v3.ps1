# Program documentation




# Variable definitions

# Storage for Azure resources and subscriptions
$azureSubscriptions  = @()
$azureResources      = [System.Collections.ArrayList]@()
$resourceUsageReport = [System.Collections.ArrayList]@()


# Storage for threaded usage data
$dateQ              = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureUsageRecords  = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# define information for usage data based on date range
$startDate = [datetime]"09-01-2021"
$endDate = [datetime]"10-01-2021"
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days

# set maX # of threads = processor cores and create the Runspace pool
[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + 1)
$pool = [RunspaceFactory]::CreateRunspacePool(1, $maxpoolsize)
$pool.ApartmentState = "MTA"
$pool.Open()
$runspaces = @()

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

        ((Get-UsageAggregates @params).UsageAggregations | Select-Object -ExpandProperty Properties) | ForEach-Object {
        
            $ur = New-Object PSObject -Property ([ordered]@{
                "Resource Id"          = (($_.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)
                "Meter Category"       = $_.MeterCategory
                "Meter Name"           = $_.MeterName
                "Meter SubCategory"    = $_.MeterSubCategory
                "Quantity"             = $_.Quantity
                "Unit"                 = $_.Unit
                "Usage Start Time"     = $_.UsageStartTime
                "Usage End Time"       = $_.UsageEndTime
                "Duration"             = ($_.UsageEndTime - $_.UsageStartTime).hours
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
}

Function getResourceUsage($resourceId)
{
    if ($recordList = $azureUsageRecords -match $resourceId)
    {
        $recordList
    }
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

Set-AzContext -Subscription "International Dev/Test"

Write-Host "Getting usage data"
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

$azureResources.ResourceId | ForEach-Object { getResourceUsage $_ }