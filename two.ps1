# Get the current directory
$currentDirectory = Get-Location

# List all files in the current directory
$files = Get-ChildItem -Path $currentDirectory -File

# Output the list of files in a table format
$files | Select-Object Name, @{Name="Type";Expression={$_.Extension}}, @{Name="Size (KB)";Expression={[math]::Round($_.Length / 1KB, 2)}} | Format-Table -AutoSize