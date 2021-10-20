$startDate = [datetime]"09-01-2021"
$endDate = [datetime]"10-01-2021"
[int]$offset = 0
[int]$numDays = ($endDate - $startDate).Days

$dateQ        = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$usageRecords = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

0..($numDays-1) | ForEach-Object {
    $dateQ.Enqueue($startDate.AddDays($_))
}

$RunspaceCollection = @()

# Create a Runspace Pool with a minimum and maximum number of run spaces. (http://msdn.microsoft.com/en-us/library/windows/desktop/dd324626(v=vs.85).aspx)
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, [int]$env:NUMBER_OF_PROCESSORS + 1)

# Open the RunspacePool so we can use it
$RunspacePool.Open()

# Define a script block to actually do the work
$ScriptBlock = {
	param($dateQ, $usageRecords)
    [datetime]$sd = $dateQ.Dequeue()
    $ed = $sd.AddDays(1)
    Write-Output "Fetching usage records for $sd to $ed"
    $results = (Get-UsageAggregates -ReportedStartTime $sd -ReportedEndTime $ed -ShowDetails $true -AggregationGranularity Hourly).UsageAggregations | Select-Object -ExpandProperty Properties
    [System.Threading.Monitor]::Enter($usageRecords.syncroot)
    [void]$usageRecords.Add($results)
    Write-Output "Returned $($results.count) usage records"
    [System.Threading.Monitor]::Exit($usageRecords.syncroot)
} #/ScriptBlock

# Create PowerShell objects, then for each one add the unique computer name.
1..$numDays | ForEach-Object {
	# Create a PowerShell object to run add the script and argument.
	# We first create a Powershell object to use, and simualtaneously add our script block we made earlier, and add our arguement that we created earlier
	$Powershell = [PowerShell]::Create().AddScript($ScriptBlock).AddArgument($dateQ).AddArgment($usageRecords)

	# Specify runspace to use
	# This is what let's us run concurrent and simualtaneous sessions
	$Powershell.RunspacePool = $RunspacePool

	# Create Runspace collection
	# When we create the collection, we also define that each Runspace should begin running
	[Collections.Arraylist]$RunspaceCollection += New-Object -TypeName PSObject -Property @{
		Runspace = $PowerShell.BeginInvoke()
		PowerShell = $PowerShell  
	} #/New-Object
} #/ForEach

# Now we need to wait for everything to finish running, and when it does go collect our results and cleanup our run spaces
# We just say that so long as we have anything in our RunspacePool to keep doing work. This works since we clean up each runspace as it completes.
While($RunspaceCollection) {
	
	# Just a simple ForEach loop for each Runspace to get resolved
	Foreach ($Runspace in $RunspaceCollection.ToArray()) {
		
		# Here's where we actually check if the Runspace has completed
		If ($Runspace.Runspace.IsCompleted) {
			
			# Since it's completed, we get our results here
			[void]$usageRecords.Add($Runspace.PowerShell.EndInvoke($Runspace.Runspace))
			
			# Here's where we cleanup our Runspace
			$Runspace.PowerShell.Dispose()
			$RunspaceCollection.Remove($Runspace)
			
		} #/If
	} #/ForEach
} #/While

Write-Host "`nTUsage data`n"
$usageRecords
Write-Host ""