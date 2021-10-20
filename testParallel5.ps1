# Create an array of computers to do work against
$Computers = “computer01”,”computer02”,”computer03”,”computer04”,”computer05”

# Create an empty array that we'll use later
$RunspaceCollection = @()

# This is the array we want to ultimately add our information to
$qwinstaResults = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# Create a Runspace Pool with a minimum and maximum number of run spaces. (http://msdn.microsoft.com/en-us/library/windows/desktop/dd324626(v=vs.85).aspx)
$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1,5)

# Open the RunspacePool so we can use it
$RunspacePool.Open()

# Define a script block to actually do the work
$ScriptBlock = {
	Param($Computer, $qwinstaResults)
	$queryResults = $Computer
    [System.Threading.Monitor]::Enter($qwinstaResults.syncroot)
    [void]$qwinstaResults.Add($queryResults)
    [System.Threading.Monitor]::Exit($qwinstaResults.syncroot)
} #/ScriptBlock

# Create PowerShell objects, then for each one add the unique computer name.
Foreach ($Computer in $Computers) {
	# Create a PowerShell object to run add the script and argument.
	# We first create a Powershell object to use, and simualtaneously add our script block we made earlier, and add our arguement that we created earlier
	$Powershell = [PowerShell]::Create().AddScript($ScriptBlock).AddArgument($Computer).AddArgment($qwinstaResults)

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
			[void]$qwinstaResults.Add($Runspace.PowerShell.EndInvoke($Runspace.Runspace))
			
			# Here's where we cleanup our Runspace
			$Runspace.PowerShell.Dispose()
			$RunspaceCollection.Remove($Runspace)
			
		} #/If
	} #/ForEach
} #/While

Write-Host "`nThe Results of qwinstaResults is ... `n"
$qwinstaResults
Write-Host ""