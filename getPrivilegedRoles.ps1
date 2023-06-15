<#
   Show Resource group ownership for every resource group in every subscription
   Generate a report that shows Subscription for the header
   Add a blank line
   Show Resource group name
   Add a dotted line
   Tabular format with column headings
   Name, Login, Role Name, Object Type, Delegation Enabled
   Add a blank line between next extra

   If the Object Type is a service principal, do a lookup to show what app registration it is tied to
   If the Object Type is a group, list the members

   Also output a list of users, groups and accounts to be checked for ex-employees or obselete applications
#>
$identities = [System.Collections.ArrayList]::new()

function DisplayReport($subscription)
{
   Set-AzContext -Subscription $subscription.Id | Out-Null
   DisplayHeader "Subscription Name: $($subscription.Name)`n"
   $resourceGroups = Get-AzResourceGroup | select-object resourcegroupname
   ForEach ($resourceGroup IN $resourceGroups)
   {
      $resourceGroupName = $resourceGroup.ResourceGroupName
      DisplayHeader "Resource Group: $resourceGroupName`n-------------------------------------`n"
      $roleAssignment = Get-AzRoleAssignment -ResourceGroupName $resourceGroupName | Where-Object {($_.RoleDefinitionName -eq "Owner") -or ($_.RoleDefinitionName -eq "Contributor")} | Select-Object -Property DisplayName,SignInName,RoleDefinitionName,ObjectType,CanDelegate
      DisplayDetail $roleAssignment

      $roleAssignment | ForEach-Object {
         $roleRecord = [PSCustomObject]@{
            DisplayName        = $_.DisplayName
            SignInName         = $_.SignInName
            RoleDefinitionName = $_.RoleDefinitionName
            ObjectType         = $_.ObjectType
            CanDelete          = $_.CanDelegate
        }
        $identities.Add($roleRecord) | Out-Null
      }
   }
   Write-Output "`n"
}

function DisplayHeader($header)
{
   Write-Output $header
}

function DisplayDetail($detailTable)
{
   $detailTable | Format-Table -AutoSize
   Write-Output "`n"
}

function displayUserList($identities)
{
   $identities | Sort-Object -Property DisplayName -unique | Format-Table -AutoSize
}

function checkIdentityType($identity)
{
   switch ($identity.ObjectType)
   {
      "User" { checkUserStatus $identity }
      "ServicePrincipal" { checkServiceAccountStatus $identity }
      "Group" { getGroupMembers $identity }
      default {$identity.ObjectType}
   }
}

function checkUserStatus($user)
{
   Get-AzADUser -ObjectId $user.SignInName | Select-Object -Property DisplayName, AccountEnabled, ApproximateLastSignInDateTime
}

function checkServiceAccountStatus($account)
{
   Get-AzADServicePrincipal -DisplayName $account.DisplayName | Select-Object -Property DisplayName,AccountEnabled,AdditionalProperties
}

function ShowExpiredUsers()
{
      # Get-AzureADUser -ObjectId "testUpn@tenant.com"
}

function ShowActiveUsers()
{

}

function getGroupMembers($identity)
{
   Get-AzADGroup -DisplayName $identity.DisplayName
}

function checkServicePrincipal()
{
   
}

#### Main Program ####
[void](Update-AzConfig -DisplayBreakingChangeWarning $false)

<#
try {
   Get-AzureADTenantDetail
}
catch {
   Connect-AzAccount
}
#>

# Start-Transcript -Path "./AzureRoles.txt"

Get-AzSubscription | Select-Object -First 1 | ForEach-Object { DisplayReport $_ }

Write-Output "List of identities included in the report:`n"

displayUserList $identities

# Stop-Transcript

$identities | ForEach-Object { checkIdentityType $_ }