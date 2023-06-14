#Connect-AzAccount
#Update-AzConfig -DisplayBreakingChangeWarning $false

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
      $ra = Get-AzRoleAssignment -ResourceGroupName $resourceGroupName | Where-Object {($_.RoleDefinitionName -eq "Owner") -or ($_.RoleDefinitionName -eq "Contributor")} | Select-Object -Property DisplayName,SignInName,RoleDefinitionName,ObjectType,CanDelegate
      DisplayDetail $ra
      $ra.DisplayName | ForEach-Object { try { $identities.Add($_.ToString().Trim()) | Out-Null }
         catch {}
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
#### Main Program ####
Start-Transcript -Path "./AzureRoles.txt"

Get-AzSubscription | ForEach-Object { DisplayReport $_ }

Write-Output "List of identities included in the report:`n"
$identities | Sort-Object -Unique

Stop-Transcript