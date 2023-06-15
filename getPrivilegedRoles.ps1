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
$servicePrincipals = [System.Collections.ArrayList]::new()
$azureADUsers = [System.Collections.ArrayList]::new()

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
            UserPrincipalName  = $_.SignInName
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
      "User" { createUserList $identity }
      "ServicePrincipal" { createServiceAccountList $identity $servicePrincipals}
      "Group" { getGroupMembers $identity }
      default {
         # Write-Output "Unknown identity object type: $($identity.ObjectType)"
      }
   }
}

function createUserList($user)
{
   $user = Get-AzADUser -ObjectId $user.UserPrincipalName -Select AccountEnabled,LastPasswordChangeDateTime -AppendSelected | Select-Object DisplayName,AccountEnabled,UserPrincipalName,LastPasswordChangeDateTime
   $azureADUsers.Add($user) | Out-Null
}

function createServiceAccountList($account, $servicePrincipals)
{
   $sp = Get-AzADServicePrincipal -DisplayName $account.DisplayName | Select-Object -Property DisplayName,AccountEnabled,AppId,AdditionalProperties
   $serviceAccountRecord = [PSCustomObject]@{
      DisplayName        = $sp[0].DisplayName
      AccountEnabled     = $sp[0].AccountEnabled
      AppId              = $sp[0].AppId
      UserPrincipalName  = $sp[0].AppId
      CreatedDate        = $sp[0].AdditionalProperties.createdDateTime
   }
   $servicePrincipals.Add($serviceAccountRecord) | Out-Null
}

function ShowDisabled($list)
{
   if ($list.Count -gt 0)
   {
      $list | Where-Object { $_.AccountEnabled -ne "True" } | Sort-Object -Property UserPrincipalName -Unique | Format-Table
      Write-Output "`n"
   }
   else {
      Write-Output "No records found."
   }

}

function ShowActive($list)
{
   if ($list.Count -gt 0)
   {
      $list | Where-Object { $_.AccountEnabled -eq "True" } | Sort-Object -Property UserPrincipalName -Unique | Format-Table
      Write-Output "`n"
   }
   else {
      Write-Output "No records found."
   }
}

function getGroupMembers($identity)
{
   # Write-Output "`nGroup Name $($identity.DisplayName)"
   $groupList = get-azadgroupmember -GroupDisplayName $identity.DisplayName -WarningAction SilentlyContinue
   if ($groupList.Count -gt 0)
   {
      $groupList | ForEach-Object {
         createUserList $_
      }
   }
}

#### Main Program ####
[void](Update-AzConfig -DisplayBreakingChangeWarning $false)

try {
   Get-AzureADTenantDetail
}
catch {
   Connect-AzAccount
}

Start-Transcript -Path "./AzureRoles.txt"

Get-AzSubscription | Select-Object -First 50 | ForEach-Object { DisplayReport $_ }

Write-Output "List of identities included in the report:`n"

# Sort identities into types
$identities | ForEach-Object { checkIdentityType $_ }

DisplayHeader "Active Users in Azure Active Directory"
ShowActive $azureADUsers

DisplayHeader "Disabled Users in Azure Active Directory"
ShowDisabled $azureADUsers

DisplayHeader "Active Service Principals in Azure Active Directory"
ShowActive $servicePrincipals

DisplayHeader "Disabled Service Principals in Azure Active Directory"
ShowDisabled $servicePrincipals

Stop-Transcript