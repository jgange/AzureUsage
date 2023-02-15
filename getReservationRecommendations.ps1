$azContext = Get-AzContext
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
$authHeader = @{
   'Content-Type'='application/json'
   'Authorization'='Bearer ' + $token.AccessToken
}

$requestURLtemplate = "https://management.azure.com/subscriptions/{subscriptionID}/providers/Microsoft.Consumption/reservationRecommendations?api-version=2021-10-01"
$subscriptionList = @("pod-dev","pod-prod")

[int] $i=0

### FUNCTIONS

function returnSubscriptionIdbyName([string] $subscriptionName)
{
   $subList | ForEach-Object {
    if ($_.Name -eq $subscriptionName) { return $_.Id }
    }

}

#### MAIN #####

# Connect-AzAccount | Out-Null

$subList = Get-AzSubscription -TenantId $tenantID

Start-Transcript -Path ".\reservation report.txt" -UseMinimalHeader

$subscriptionList | ForEach-Object {

    $subId = returnSubscriptionIdbyName $_
    $requestURL = $requestURLtemplate -replace "{subscriptionID}",$subId

    $response = (Invoke-RestMethod -Uri $requestURL -Method Get -Headers $authHeader).Value

        Write-Output "Subscription = $_`n`n"

    for($i=0;$i -lt $response.Count; $i++)
    {

        Write-Output "Kind                           : $($response[$i].kind)"
        Write-Output "Id                             : $($response[$i].id)"
        Write-Output "Name                           : $($response[$i].name)"
        Write-Output "Type                           : $($response[$i].type)"
        Write-Output "Location                       : $($response[$i].location)"
        Write-Output "SKU                            : $($response[$i].sku)"

        $details = $response[$i].properties
        $details
    }
}

Stop-Transcript