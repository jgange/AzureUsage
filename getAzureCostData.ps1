param (
    [ValidateScript(
    {
      if ( [datetime]$_ -gt (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-180) -and [datetime]$_ -le (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-2) ) { $true }
      else { throw "Please enter a date between yesterday and 180 days ago."}
    })]
    [string]
    $startDate = (Get-Date).AddDays(-31).tostring(“MM-dd-yyyy”),

    [ValidateScript(
    {
      if ([datetime]$_ -gt (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-179) -and ([datetime]$_ -le (Get-Date -Hour 0 -Minute 0 -Second 0).AddDays(-1)) -and ([datetime]$_ -gt $startDate)) { $true }
      else { throw "Please enter a date between yesterday and 180 days ago which is at least one day after the start date."}
    })]
    [string]
    $endDate = (Get-Date).AddDays(-1).tostring(“MM-dd-yyyy”),

    [ValidateSet("True", "False")]
    [string]
    $includeDetail = "True", 
                                              # only shows subscription totals if false - add _Summary if false, or _Detail if true
    [ValidateScript({
            if( -Not ($_ | Test-Path) ){
                throw "Directory does not exist. Please create the directory to store the reports before running this script."
            }
            return $true
        })]
    [string] $reportFilePath = $env:USERPROFILE
)

$azureCostData = [System.Collections.ArrayList]@()
$subscriptionTotalCost = @{}
$reportType = "_Summary.txt"

# Support for using a service principal instead an interactive log on

# Required Azure AD information for Service Account

$tenantId = '7797ca53-b03e-4a03-baf0-13628aa79c92'
$applicationId = "0702023c-176d-46e8-81bc-5e79e7de57cd"

# These files must have already been populated with the correct AES key and encrypted password -- ideally these should be in a key vault
$KeyFile = Join-Path $env:USERPROFILE -ChildPath "AES.key"
$PasswordFile = Join-Path -Path $env:USERPROFILE -ChildPath "Password.txt"

[boolean]$useSP = $true

if ($includeDetail -eq "$True")
{
    $reportType = "_Detail.txt"
}

$outputFile = (($reportFilePath + "\AzureCostReport_" + $startDate + "_" + $endDate + $reportType).Replace("/","-") -Replace"\s\d{2}:\d{2}:\d{2}")

### Main Program ###

# Check if a connection to Azure exists
if (!($azc.Context.Tenant))
{
    If ($useSP)
    {
        $Key = Get-Content $KeyFile
        $pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $applicationId, (Get-Content $PasswordFile | ConvertTo-SecureString -Key $key)
        $azc = Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $tenantId
    }
    else
    {
        $azc = Connect-AzAccount
        sleep -Seconds 15
    }
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

        $l = $azgitem.Group.InstanceLocation | Get-Unique
        if( ($l.GetType()).Name -ne 'String') 
        { 
            $location = [String]::Join(" ",($l | Sort-Object | Get-Unique))[0]
        }
        else
        {
            $location = $l
        }

        $t = $azgitem.Group.ConsumedService | Get-Unique
        if( ($t.GetType()).Name -ne 'String') 
        { 
            $type = [String]::Join(" ",($t | Sort-Object | Get-Unique))[0]
        }
        else
        {
            $type = $t
        }

            $costItem = New-Object PSObject -Property ([ordered]@{
              "Total Cost"        = ($_.Group | Measure-Object -Property PretaxCost -Sum).Sum
              "Number of Charges" = $_.Count
              "Resource Name"     = $_.Name
              "Location"          = $location
              "Resource Type"     = $type
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