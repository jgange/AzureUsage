# get subs
# get resources in sub
# get usage data for resource
# if no data returned, put them on the exception list


$azureSubscriptions  = @()                                                                                        # Get all accessible subscriptions
$azureResources      = [System.Collections.ArrayList]@()                                                          # List of all accessible Azure resources across all subscriptions
$resourceUsageReport = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))    # Thread safe array to hold finally aggregated report data
$snum = 0

# Retrieves resources from all accessible subscriptions
Function getAzureResources()
{
    $global:azureSubscriptions = Get-AzSubscription

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

# Main Program

getAzureResources