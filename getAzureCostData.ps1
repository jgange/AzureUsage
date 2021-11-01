param (
    [string]$startDate = (Get-Date).AddDays(-31).tostring(“MM-dd-yyyy”),  # defaults to 30 days prior to last collection date
    [string]$endDate   = (Get-Date).AddDays(-1).tostring(“MM-dd-yyyy”),   # last current collection date
    [ValidateSet("True", "False")]
    [string]
    $includeDetail = "True"                                           # only shows subscription totals if false - add _Summary if false, or _Detail if true
)

$azureCostData = [System.Collections.ArrayList]@()
$subscriptionTotalCost = @{}
$reportType = "_Summary.txt"

if ($includeDetail -eq "$True")
{
    $reportType = "_Detail.txt"
}

$outputFile = ("C:\Users\jgange\Projects\PowerShell\AzureUsage\Reports\AzureCostReport_" + $startDate + "_" + $endDate + $reportType).Replace("/","-")

Write-Host "Running with the following settings- Start date: $startDate    End date: $endDate    Detail level: $includeDetail"

### Main Program ###

# Check if a connection to Azure exists
if (!($azc.Context.Tenant))
{
    $azc = Connect-AzAccount
}

$azSubscriptions = Get-AzSubscription

$azSubscriptions | ForEach-Object {

    $null = (Set-AzContext -Subscription $_.SubscriptionId)

    try
    {
        $azc = Get-AzConsumptionUsageDetail -StartDate $startDate -EndDate $endDate -ErrorAction SilentlyContinue
        if ($azc){
            $subCost = '{0:C}' -f (($azc | Measure-Object -Property PretaxCost -Sum).Sum)
        }
        else{
            $subCost = '{0:C}' -f 0
        }
        [void]$subscriptionTotalCost.Add($_.Name,$subCost)

        $azg = $azc | Group-Object -Property InstanceName
        $azg | ForEach-Object {

        $azgitem = $_

            $costItem = New-Object PSObject -Property ([ordered]@{
              "Total Cost"        = ($_.Group | Measure-Object -Property PretaxCost -Sum).Sum
              "Number of Charges" = $_.Count
              "Resource Name"     = $_.Name
              "Location"          = $azgitem.Group.InstanceLocation | Get-Unique
              "Resource Type"     = $azgitem.Group.ConsumedService | Get-Unique
              "Product"           = $azgitem.Group.Product | Get-Unique
              "Subscription"      = $azgitem.Group.SubscriptionName | Get-Unique
           })
          [void]$azureCostData.Add($costItem)
        }
        $azc.Clear()
        $azg.Clear()
    }

    catch{}

}

### Main Reporting Loop ###

Start-Transcript -Path $outputFile

Write-host "Azure Subscription Cost Report"
Write-Host "Date Range: $startDate - $endDate"

$azSubscriptions | ForEach-Object{

    $subName = $_.Name
    Write-Host "`n`nSubscription: $subName"
    Write-Host "Total cost during period: $($subscriptionTotalCost[$subName])"
    Write-Host
    if ($includeDetail)
    {
        "{0,-100} {1,-20} {2,-30} {3,-30}" -f "Resource Name","Location","Resource Type","Total Cost"
        "{0,-100} {1,-20} {2,-30} {3,-30}" -f "-------------","--------","-------------","----------"
        $subData = ($azureCostData | Where-Object { $_.Subscription -eq $subName} | Select-Object -Property "Resource Name","Location","Resource Type","Total Cost")
        $subData = ($subData | Sort-Object -Property "Total Cost" -Descending)
        $subData | ForEach-Object {'{0,-100} {1,-20} {2,-30} {3,-30:C}' -f $_."Resource Name", $_.Location, $_."Resource Type", $_."Total Cost"}
    }
}

Stop-Transcript

# strip the transcript info out of the file
(Get-Content $outputFile | Select-Object -Skip 19) | Select-Object -SkipLast 4 |Set-Content $outputFile