## Information to generate credentials
$tenantId         = "7797ca53-b03e-4a03-baf0-13628aa79c92"
$appId            = "0702023c-176d-46e8-81bc-5e79e7de57cd"
#$spPass           = (Get-AutomationVariable -Name "AzureAutomationPSsecret") -replace '"',''
$spPass           = "4Mo7Q~-gR1v_onYIf_FI0h9SSjeO-pe5KEv3W"
$appSecret        = $spPass

<#
# Connect to Azure to query service bus
$ss = $spPass | ConvertTo-SecureString -AsPlainText -Force
[pscredential]$credObject = New-Object System.Management.Automation.PSCredential ($appId, $ss)
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -ServicePrincipal -Credential $credObject -Tenant $tenantId -WarningAction Ignore | Out-Null
Select-AzSubscription -SubscriptionName 'Pod-Dev' | Out-Null
$authToken        = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

$loggingToken    = Get-AzAccessToken -ResourceUrl "https://monitoring.azure.com"
#>

# GET https://management.azure.com/{resourceUri}/providers/Microsoft.Insights/metricDefinitions?api-version=2018-01-01

$resourceUri = "/subscriptions/e48da26e-6a86-4902-b383-0abbf5e50ce3/resourceGroups/d-pod-rg/providers/Microsoft.Cache/Redis/d-pod-rc"

$header = @{
    Authorization = "Bearer " + $authToken.Token
}

## Get a bearer token for the Azure Monitor log ingestion end point
$scope       = [System.Web.HttpUtility]::UrlEncode("https://management.azure.com")   
$body        = "client_id=$appId&scope=$scope&client_secret=$appSecret&grant_type=client_credentials";
$headers     = @{"Content-Type" = "application/x-www-form-urlencoded" };
$uri         = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$response = Invoke-RestMethod -Uri $uri -Method "Post" -Body $body -Headers $headers

while ($true)
{
    $header = @{
        Authorization = "Bearer " + $response.access_token
    }

    $result = Invoke-RestMethod -Uri "https://management.azure.com/$resourceUri/providers/Microsoft.Insights/metricDefinitions?api-version=2018-01-01" -Method Get -Headers $header
    $result
    start-sleep 60
}
