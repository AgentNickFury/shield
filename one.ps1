# Define variables
$vmName = "YourVMName"
$resourceGroupName = "YourResourceGroupName"
$scriptToRun = "C:\Path\To\YourScript.ps1"

try {
    # Authenticate to Azure
    Connect-AzAccount -ErrorAction Stop
} catch {
    Write-Error "Failed to authenticate to Azure. $_"
    exit
}

# Import the Excel module
Import-Module ImportExcel -ErrorAction Stop

# Initialize an array to store VM details
$vmDetails = @()

# Fetch all subscriptions in the tenant
try {
    $subscriptions = Get-AzSubscription -ErrorAction Stop
} catch {
    Write-Error "Failed to fetch subscriptions. $_"
    exit
}

foreach ($subscription in $subscriptions) {
    $subscriptionId = $subscription.Id

    try {
        # Set the subscription context
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    } catch {
        Write-Error "Failed to set the subscription context for SubscriptionId $subscriptionId. $_"
        continue
    }

    try {
        # Fetch all VMs in the current subscription
        $vms = Get-AzVM -ErrorAction Stop
    } catch {
        Write-Error "Failed to fetch VMs for SubscriptionId $subscriptionId. $_"
        continue
    }

    foreach ($vm in $vms) {
        $vmName = $vm.Name
        $resourceGroupName = $vm.ResourceGroupName
        $status = "Not Attempted"

        try {
            # Ensure the VM is running
            if ($vm.ProvisioningState -ne "Succeeded" -or $vm.PowerState -ne "VM running") {
                Write-Host "Starting the VM $vmName in SubscriptionId $subscriptionId..."
                Start-AzVM -Name $vmName -ResourceGroupName $resourceGroupName -ErrorAction Stop
            }
        } catch {
            Write-Error "Failed to start the VM $vmName in SubscriptionId $subscriptionId. $_"
            $status = "Failed to Start VM"
            $vmDetails += [PSCustomObject]@{
                VMName       = $vmName
                Subscription = $subscriptionId
                Status       = $status
            }
            continue
        }

        try {
            # Run the script on the VM
            Invoke-AzVMRunCommand -ResourceGroupName $resourceGroupName -VMName $vmName -CommandId "RunPowerShellScript" -ScriptPath $scriptToRun -ErrorAction Stop
            Write-Host "Script executed successfully on the VM $vmName in SubscriptionId $subscriptionId."
            $status = "Script Executed Successfully"
        } catch {
            Write-Error "Failed to execute the script on the VM $vmName in SubscriptionId $subscriptionId. $_"
            $status = "Failed to Execute Script"
        }

        # Add VM details to the array
        $vmDetails += [PSCustomObject]@{
            VMName       = $vmName
            Subscription = $subscriptionId
            Status       = $status
        }
    }
}

# Export the VM details to an Excel file
$excelFilePath = "C:\Path\To\VM_Status_Report.xlsx"
try {
    $vmDetails | Export-Excel -Path $excelFilePath -AutoSize -ErrorAction Stop
    Write-Host "VM status report exported successfully to $excelFilePath."
} catch {
    Write-Error "Failed to export the VM status report to Excel. $_"
}