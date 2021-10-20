<#

  The resource lookup operation is expensive so it should be limited to unique resourceIds
  resourceIds will have to put into a separate array and iterate through to pull the resource information
  for the existing list. The list will need to be deduplicated.

  Process-

    Pull usage date for each subscription
    Get list of unique resource ids
    Use list of resource ids to get information about resource from Azure
    Create composite object which has usage and resource information

    smaller loop b/c it only does look ups on the resources on the usage list and that is a much smaller result set

    go through the list of resource ids to match against what's it azure
    try to get the resource data
    if that fails and the resource doesn't exist, pull the data from the usage field

#>


# $limiter = 100000
$limiter = 5000
$ExportPath = "C:\Users\jgange\Projects\PowerShell\AzureActivityCostReport.csv"

Function Get-AzureUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [datetime]$FromTime,
 
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [datetime]$ToTime,
 
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Hourly', 'Daily')]
        [string]$Interval = 'Daily'
    )
    
    Write-Verbose -Message "Querying usage data [$($FromTime) - $($ToTime)]..."
    $usageData = $null
    do {    
        $params = @{
            ReportedStartTime      = $FromTime
            ReportedEndTime        = $ToTime
            AggregationGranularity = $Interval
            ShowDetails            = $true
        }
        if ((Get-Variable -Name usageData -ErrorAction Ignore) -and $usageData) {
            Write-Verbose -Message "Querying usage data with continuation token $($usageData.ContinuationToken)..."
            $params.ContinuationToken = $usageData.ContinuationToken
        }
        $usageData = Get-UsageAggregates @params
        $usageData.UsageAggregations | Select-Object -ExpandProperty Properties
    } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)
}

$usage            = [System.Collections.ArrayList]::new()
$resourceList     = [System.Collections.ArrayList]::new()
$OutputArray      = [System.Collections.ArrayList]::new()
$azureResources   = [System.Collections.ArrayList]::new()

$startDate = '09-06-2021'
$endDate   = '10-05-2021'
$interval = 'Hourly'
$Switch = '-Verbose'
$Switch = ''
$i = 0
$refreshData = $false
$rc = 0

if (($usage.Count -eq 0) -or ($refreshData))
{
    Write-Output "Getting usage data..."
    $usage = Get-AzureUsage -FromTime $startDate -ToTime $endDate -Interval $interval | Select-Object -First $limiter
}
else 
{
    Write-Output "Using existing data. Set refresh flag to true to get a new data set."
}

# The resource list should be held in a queue. Then each process can read the queue and pull off an entry
# the entry gets processed with a single get-AzResource call for each thread running which should speed up the time to populate
# the azureResources arrary

if (($azureResources.Count -eq 0) -or ($resourceList.Count -eq 0))
{
    $resourceList = (($usage.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri) | Sort-Object | Get-Unique
    $rc = $resourceList.Count
    Write-Output "Looking up resource information"
    $startTime = Get-Date
    $resourceList | ForEach-Object { 
        try {
            $i++
            $pc = [math]::round($i/$rc*100,0)
            $elapsedTime = ((Get-Date).Add(-$startTime).Minute)
            #$averageTime = "$($elapsedTime / $i) minutes"
            Write-Progress -Activity "Looking up resource information" -Status "$pc% complete -- Elasped time: $elapsedTime minutes -- Iteration $i of $rc" -PercentComplete $pc
            $azureResources.Add((Get-AzResource -ResourceId $_ -ErrorAction SilentlyContinue))
            }
        catch {}
   }
}
else 
{
    Write-Output "Using existing Azure resource data."
}

Write-Progress -Activity "Looking up resource information" -Status "Ready" -Completed   # Remove progress bar

$usage | ForEach-Object {

    $usageDetail = $_
    $resourceId = ($usageDetail.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri

    if ($resourceList -contains $resourceId)
    {  
        try
        {
            # $resourceDetail = Get-AzResource -ResourceId $resourceId -ErrorAction SilentlyContinue
            # replace the call to Get-AzResource with a lookup against $azureResources instead
            $resourceDetail = ($azureResources | Where-Object {$_.resourceId -eq $resourceId} )
            $resourceDetail
        }
        catch {
            $resourceDetail = New-Object PSObject -Property ([ordered]@{
               "ResourceName"      = (((($usageDetail.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)-split '/')[-1]).Name
               "ResourceGroupName" = (((($usageDetail.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)-split '/')[4]).Name
               "ResourceType"      = ((((($usageDetail.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)-split '/')[5]).Name + (((($usageDetail.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri)-split '/')[6]).Name)
               "Location"          = ($usageDetail.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.location
               "Status"            = 'Deleted'
            })
        }
    }
    $consolidated = New-Object PSObject -Property ([ordered]@{
        "SubscriptionName"      = (Get-AzSubscription -SubscriptionId ($resourceId -split '/')[2]).Name
        "ResourceName"          = $resourceDetail.ResourceName
        "ResourceGroupName"     = $resourceDetail.ResourceGroupName
        "ResourceType"          = $resourceDetail.ResourceType
        "Location"              = $resourceDetail.Location
        "MeterCategory"         = $usageDetail.MeterCategory
        "MeterName"             = $usageDetail.MeterName
        "MeterSubCategory"      = $usageDetail.MeterSubCategory
        "Quantity"              = $usageDetail.Quantity
        "Unit"                  = $usageDetail.Unit
        "Usage Start Time"      = $usageDetail.UsageStartTime
        "Usage End Time"        = $usageDetail.UsageEndTime
        "Duration"              = ($usageDetail.UsageEndTime - $usageDetail.UsageStartTime).hours
        "Status"                = 'Active'
    })
    $OutputArray.Add($consolidated)
}

#$OutputArray
$OutputArray | export-csv $ExportPath -NoTypeInformation

<#
$usage | Where-Object {$_.MeterCategory -eq 'Virtual Machines'} | `
Format-Table UsageStartTime,UsageEndTime,@{n="VM Name";e={(($_.InstanceData | `
ConvertFrom-Json).'Microsoft.Resources'.resourceURI -split "/")[-1]}},Quantity,Unit
#>