Param(
    [Parameter(Mandatory=$true, Position=1, HelpMessage = "Comma separated list of resource groups", ValueFromPipeline = $false)]
    [string]$ResourceGroups,
    [Parameter(Mandatory=$false, Position=2, HelpMessage = "CSV export folder", ValueFromPipeline = $false)]
    [string]$CSVFolder="C:\Users\jgange\Projects\PowerShell\"
)
 
$AzureContext = Get-AzContext
if(!$AzureContext){
    Write-Host "Please login to your Azure Account"
    Login-AzureRmAccount
}
 
# Select Azure subscription
Write-Host "Please select Azure subscription and click OK"
$AzureSubscription = (Get-AzSubscription | Out-GridView -Title "Choose Azure subscription and click OK" -PassThru)
Write-Output "Switching to Azure subscription: $($AzureSubscription.Name)"
Select-AzSubscription -SubscriptionId $AzureSubscription.Id
 
$OutputArray = @()
$ResourceGroups = $ResourceGroups.Replace(' ','')
$resourceGroupsArray = $ResourceGroups.Split(',')
 
foreach($rg in $resourceGroupsArray){
   $resourceGroupExist = Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue
   if($resourceGroupExist){
     
    $rgArray = Get-AzResource -ResourceGroupName $rg | select Name, ResourceType, ResourceGroupName, ResourceId, Location
    foreach($resource in $rgArray){
        $Object = New-Object PSObject -Property ([ordered]@{ 
                "Resource Group"   = $rg
                "Resource Name"    = $resource.Name
                "Resource Type"    = $resource.ResourceType
                "Resource Id"      = $resource.ResourceId
                "Location"         = $resource.Location
            })
             
        $OutputArray += $Object
    }
   }
   else{
       Write-Host "Provided resource group name $rg does not exist in current subscription $($AzureSubscription.Id)" -ForegroundColor Red
   }
       
}

$OutputArray


<#
Write-Host "Exporting results to CSV file..."
$Date = Get-Date -Format yyyyMMddmmHHss
$CSVName = "ResourceList_"+$Date+".csv"

if($CSVFolder){
    $checkCSVFolder = Test-Path $CSVFolder
    if($checkCSVFolder){
        $Path = (Get-Item $CSVFolder).Target
    }
    else{
        $Path = (Get-Location).Path
    }
}
     
$ExportPath = "$Path\$CSVName"
Try{
    $OutputArray | export-csv $ExportPath -NoTypeInformation
}
Catch{
    Write-Host "Error during CSV export. Error: $($_.Exception.Message)" -ForegroundColor Red
    break
}
 
 
Write-Host "CSV file has been exported to $ExportPath" -ForegroundColor Green
#>