param (
    [ValidateScript(
    {
      if ( [datetime]$_ -gt (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-90) -and [datetime]$_ -le (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-1) ) { $true }
      else { throw "Please enter a date between yesterday and 90 days ago."}
    })]
    [string]
    $startDate = (Get-Date).AddDays(-31).tostring(“MM-dd-yyyy”),

    [ValidateScript(
    {
      if ([datetime]$_ -gt (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-89) -and ([datetime]$_ -le (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-1)) -and ([datetime]$_ -gt $startDate)) { $true }
      else { throw "Please enter a date between yesterday and 90 days ago which is at least one day after the start date."}
    })]
    [string]
    $endDate = (Get-Date).AddDays(-1).tostring(“MM-dd-yyyy”),

    [ValidateSet("True", "False")]
    [string]
    $includeDetail = "True",                                              # only shows subscription totals if false - add _Summary if false, or _Detail if true

    [ValidateSet("True", "False")]
    [string]
    $showIdleAssets = "True",                                             # only shows subscription totals if false - add _Summary if false, or _Detail if true

    [ValidateScript({
       if( -Not ($_ | Test-Path) ){
          throw "Directory does not exist. Please create the directory to store the reports before running this script."
            }
       return $true
        })]
    [string] $reportFilePath = $env:USERPROFILE                           # Accept either a user given path, or default to the user profile folder
)

# Program documentation


# Variable definitions

$reportType = "_Summary.txt"

if ($includeDetail -eq "$True")
{
    $reportType = "_Detail.txt"
}

$outputFile = (($reportFilePath + "\AzureCostReport_" + $startDate + "_" + $endDate + $reportType).Replace("/","-") -Replace"\s\d{2}:\d{2}:\d{2}")

#Write-Host "Running with the following settings- Start date: $startDate    End date: $endDate    Detail level: $includeDetail    Report file path: $reportFilePath"
$outputFile

exit 0

# Storage for Azure resources and subscriptions
$azureSubscriptions  = @()                                                                                        # Stores available subscriptions
$azureResources      = [System.Collections.ArrayList]@()                                                          # List of all accessible Azure resources across all subscriptions
$resourceUsageReport = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))    # Thread safe array to hold finally aggregated report data
$resourceQ           = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())                # queue to hold collection of resources per subscriptions
$azureUsageData      = [System.Collections.ArrayList]@()                                                          # Holds set of report data
$idleResources       = [System.Collections.ArrayList]@()                                                          # Holds set of Azure resources with no usage data for the time frame specified
     

# Set max # of concurrent threads
$offset = 3
[int]$maxpoolsize = ([int]$env:NUMBER_OF_PROCESSORS + $offset)


# Storage for threaded usage data
$dateQ              = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$azureUsageRecords  = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# define information for usage data based on date range - need to convert the string value to an actual datetime to use the date arithmetic functions
$sd = [datetime]::ParseExact($startDate,'MM-dd-yyyy',$null)
$ed = [datetime]::ParseExact($endDate,'MM-dd-yyyy',$null)
[int]$offset = 0
[int]$numDays = ($ed - $sd).Days

# Add the days to look up usage data
0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($sd.AddDays($_))
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
            #AggregationGranularity = "Hourly"
            AggregationGranularity = "Daily"
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

Function getIdleResources()
{
    $azu          = ($azureUsageRecords."Resource Id" | Sort-Object | Get-Unique)              # Get list of resource Ids from usage data; list is sorted to properly remove duplicates.
    $idleList     = $azureResources.ResourceId | Where-Object { $_ -notin $azu }               # Generate list of resource Ids which are not in the usage list.
    $outputFile = ($reportFilePath + "\AzureIdleResourcesReport_" + $startDate + "_" + $endDate + ".txt").Replace("/","-")
             
    Start-Transcript -Path $outputFile

    Write-Host "Resources in Azure with no usage data during the selected period`n"
    Write-Host "Date range selected: $startDate to $endDate`n"
    
    $azureSubscriptions | ForEach-Object {

        $subId = $_.Id
        $subName = $_.Name

        Write-Host "`n`nSubscription name: $subName`n"
        '{0,-78} {0,-93} {2,-54} {3,-12}' -f "Resource Name", "Resource Group", "Type", "Location"
        '{0,-78} {0,-93} {2,-54} {3,-12}' -f "-------------", "--------------", "----", "--------"

        $idleList | ForEach-Object {
           $item = $_
               if( $resource = ($azureResources | Where-Object { 
                    ( ($_.ResourceId -eq $item) -and ($_.SubscriptionId -eq $subId) )
                    }))
               {
                    '{0,-78} {0,-93} {2,-54} {3,-12}' -f $resource.ResourceName, $resource.ResourceGroupName, $resource.ResourceType, $resource.Location
                }
            }

        } # End Subscription loop
    Stop-Transcript
    # strip the transcript info out of the file
    (Get-Content $outputFile | Select-Object -Skip 19) | Select-Object -SkipLast 4 |Set-Content $outputFile
}

### Main Program ###

# Check if a connection to Azure exists
if (!($azc.Context.Tenant))
{
    $azc = Connect-AzAccount
    sleep -Seconds 15
}

# Retrieve all the Azure resources
getAzureResources

# Loop through subscriptions to get all the data

$snum = 0

$azureSubscriptions | ForEach-Object {

# Add the days to look up usage data
0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($sd.AddDays($_))
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

Start-Transcript -Path $outputFile

Write-Host "`nDate Range: $startDate to $endDate`n"

$azureSubscriptions | ForEach-Object {

    $subId = $_.Id
    $subName = $_.Name

    Write-Host "`n`nSubscription name: $subName`n"

    '{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f "Resource Name","Total Usage","Unit","Location","Resource Type","Meter Category"
    '{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f "-------------","-----------","----","--------","-------------","--------------"

    $usageBySubscription = $azureUsageRecords.Where({$_.SubscriptionId -eq $subId})

    $resourceGrouping = $usageBySubscription | Group-Object -Property "Resource Id"
     
    $resourceGrouping | ForEach-Object {

        $totalUsage = ($_.Group | Measure-Object -Property Quantity -Sum).Sum                  # Total usage value for the subscription
        
        $mc = $_.Group."Meter Category" | Get-Unique                                           # get meter category and handle null values and multiple values
        if( ($mc.GetType()).Name -ne 'String') 
        { 
            $meterCategory = [String]::Join(" ",($mc | Sort-Object | Get-Unique))
        }
        else
        {
            $meterCategory = $mc
        }
        
        $un = $_.Group.Unit | Get-Unique                                                       # get the usage unit information and handle null value and multiple values
        if ($un.GetType().Name -ne 'String') {
            $unit =  ([String]::Join("-",($un | Sort-Object | Get-Unique))).Split("-")[0]
        }
        else { $unit =  $un }

        $ridm = $_.Group."Resource Id" | Get-Unique                                            # Get list of resource Ids after grouping by resource Id

        $resource = $azureResources -match $ridm                                               # match up the resource Id from the usage data to an actual Azure resource to get the rest of the information
        
        if (!($resource))                                                                      # handle the case where the resource no longer exists in azure
        {
            $resourceName =      "Not Found"
            $resourceType =      "N/A"
            if ($_.Group."Instance Location") 
            {
                $resourceLocation =  ($_.Group."Instance Location")[0]
            }
            else
            {
                $resourceLocation = "N/A"
            } 
        }
        else
        {
            if ($resource.ResourceName.GetType().Name -ne 'String')
            {
                $resourceName = ($resource.ResourceName)[0]
            }
            else
            {
                $resourceName     = $resource.ResourceName
                $resourceLocation = $resource.Location
                $resourceType     = $resource.ResourceType
            }
        }

        # construct an object to hold the data record so we can sort it by the object properties

         $item = New-Object PSObject -Property ([ordered]@{
              "Resource Name"     = $resourceName
              "Total Usage"       = $totalUsage
              "Unit"              = $unit
              "Location"          = $resourceLocation
              "Resource Type"     = $resourceType
              "Meter Category"    = $meterCategory
           })
          [void]$azureUsageData.Add($item)

    } # End ForEach loop to calculate report values

    $subUsage = $azureUsageData | Sort-Object -Property "Total Usage" -Descending
    $subUsage | ForEach-Object {
        '{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f $_."Resource Name", $_."Total Usage", $_.Unit, $_.Location, $_."Resource Type", $_."Meter Category"
    }
    #'{0,-75} {1,-12:n2} {2,-15} {3,-15} {4,-50} {5,-25}' -f $resourceName, $totalUsage, $unit, $resourceLocation, $resourceType, $meterCategory
    $azureUsageData.Clear()

}

Stop-Transcript

# strip the transcript info out of the file
(Get-Content $outputFile | Select-Object -Skip 19) | Select-Object -SkipLast 4 |Set-Content $outputFile

if  ($showIdleAssets = 'True') { getIdleResources }