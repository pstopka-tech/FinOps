﻿#title: FinOps_Inventory
#author: Patrycja Stopka patrycja.stopka@gmail.com
#date: 01.09.2026
#version: 1.0


param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$StorageSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$StorageResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$StorageContainer = "finops-inventory"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
}

# ------------------------------------------------------------
# Connect to Azure
# ------------------------------------------------------------


Disable-AzContextAutosave -Scope Process | Out-Null

Write-Log "Connecting to Azure using Managed Identity..."

try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
}
catch {
    throw "Failed to authenticate using Managed Identity. Error: $($_.Exception.Message)"
}

Write-Log "Successfully connected to Azure."

# ------------------------------------------------------------
# Storage: context, account, container
# ------------------------------------------------------------

Write-Log "Setting context to Storage Account subscription..."

Set-AzContext -SubscriptionId $StorageSubscriptionId -ErrorAction Stop | Out-Null

Write-Log "Getting Storage Account: $StorageAccountName"

$storageAccount = Get-AzStorageAccount `
    -ResourceGroupName $StorageResourceGroup `
    -Name $StorageAccountName `
    -ErrorAction Stop

$storageContext = New-AzStorageContext `
    -StorageAccountName $storageAccount.StorageAccountName `
    -UseConnectedAccount `
    -ErrorAction Stop

Write-Log "Checking Storage Container: $StorageContainer"

$container = Get-AzStorageContainer `
    -Name $StorageContainer `
    -Context $storageContext `
    -ErrorAction SilentlyContinue

if (-not $container) {
    Write-Log "Container does not exist. Creating container..."
    New-AzStorageContainer -Name $StorageContainer -Context $storageContext -Permission Off | Out-Null
    Write-Log "Container created."
}
else {
    Write-Log "Container already exists."
}

# ------------------------------------------------------------
# Get enabled subscriptions
# ------------------------------------------------------------

Write-Log "Getting enabled Azure subscriptions..."

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

Write-Log "Found $($subscriptions.Count) enabled subscriptions."

# ------------------------------------------------------------
# Cache SKU (vCPU / memory)
# ------------------------------------------------------------

$skuCache = @{}

function Get-VmSkuInfo {
    param(
        [string]$Location,
        [string]$VmSize
    )

    $locKey = $Location.ToLowerInvariant()

    if (-not $skuCache.ContainsKey($locKey)) {
        Write-Log "Caching VM SKUs for location: $Location"
        $locSkus = @{}
        try {
            Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                Where-Object { $_.ResourceType -eq "virtualMachines" } |
                ForEach-Object {
                    $cpu = ($_.Capabilities | Where-Object { $_.Name -eq "vCPUs" }).Value
                    $mem = ($_.Capabilities | Where-Object { $_.Name -eq "MemoryGB" }).Value
                    $locSkus[$_.Name] = [PSCustomObject]@{ CPU = $cpu; MemoryGB = $mem }
                }
        }
        catch {
            Write-Warning "Unable to retrieve SKUs for location '$Location'."
        }
        $skuCache[$locKey] = $locSkus
    }

    return $skuCache[$locKey][$VmSize]
}

# ------------------------------------------------------------
# Inventory collection
# ------------------------------------------------------------

$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($subscription in $subscriptions) {

    Write-Log "--------------------------------------------------"
    Write-Log "Processing subscription: $($subscription.Name)"

    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
        $resources = Get-AzResource
        Write-Log "Found $($resources.Count) resources."
    }
    catch {
        Write-Warning "Unable to process subscription '$($subscription.Name)'. Error: $($_.Exception.Message)"
        continue
    }

    # --------------------------------------------------------


    $vmMap   = @{}
    $diskMap = @{}
    $pipMap  = @{}

    try {
        Get-AzVM -Status -ErrorAction SilentlyContinue |
            ForEach-Object { $vmMap[$_.Id.ToLowerInvariant()] = $_ }
    }
    catch { Write-Warning "Unable to list VMs in '$($subscription.Name)'." }

    try {
        Get-AzDisk -ErrorAction SilentlyContinue |
            ForEach-Object { $diskMap[$_.Id.ToLowerInvariant()] = $_ }
    }
    catch { Write-Warning "Unable to list disks in '$($subscription.Name)'." }

    try {
        Get-AzPublicIpAddress -ErrorAction SilentlyContinue |
            ForEach-Object { $pipMap[$_.Id.ToLowerInvariant()] = $_ }
    }
    catch { Write-Warning "Unable to list Public IPs in '$($subscription.Name)'." }

    foreach ($resource in $resources) {

        $tags = ""
        if ($resource.Tags) {
            $tags = (
                $resource.Tags.GetEnumerator() |
                Sort-Object Key |
                ForEach-Object { "$($_.Key)=$($_.Value)" }
            ) -join ";"
        }

        $item = [PSCustomObject]@{
            CollectionDate    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            SubscriptionName  = $subscription.Name
            SubscriptionId    = $subscription.Id
            ResourceGroup     = $resource.ResourceGroupName
            ResourceName      = $resource.Name
            ResourceType      = $resource.ResourceType
            Location          = $resource.Location
            ResourceId        = $resource.ResourceId
            Tags              = $tags
            ManagedBy         = $resource.ManagedBy
            ProvisioningState = $null
            SKU               = $null
            VMSize            = $null
            VMCPU             = $null
            VMMemoryGB        = $null
            VMOS              = $null
            DiskSizeGB        = $null
            DiskSKU           = $null
            PublicIPStatus    = $null
            IsAttached        = $null
        }

        $resourceKey = $resource.ResourceId.ToLowerInvariant()

        switch ($resource.ResourceType) {

            "Microsoft.Compute/virtualMachines" {
                $vm = $vmMap[$resourceKey]
                if ($vm) {
                    $item.VMSize            = $vm.HardwareProfile.VmSize
                    $item.VMOS              = $vm.StorageProfile.OsDisk.OsType
                    $item.ProvisioningState = $vm.PowerState

                    $skuInfo = Get-VmSkuInfo -Location $resource.Location -VmSize $vm.HardwareProfile.VmSize
                    if ($skuInfo) {
                        $item.VMCPU      = $skuInfo.CPU
                        $item.VMMemoryGB = $skuInfo.MemoryGB
                    }
                }
            }

            "Microsoft.Compute/disks" {
                $disk = $diskMap[$resourceKey]
                if ($disk) {
                    $item.DiskSizeGB = $disk.DiskSizeGB
                    $item.DiskSKU    = $disk.Sku.Name

                    if ($disk.ManagedBy) {
                        $item.IsAttached = "Attached"
                        $item.ManagedBy  = $disk.ManagedBy
                    }
                    else {
                        $item.IsAttached = "Unattached"
                    }
                }
            }

            "Microsoft.Network/publicIPAddresses" {
                $pip = $pipMap[$resourceKey]
                if ($pip) {
                    $item.PublicIPStatus = if ($pip.IpConfiguration) { "Attached" } else { "Unattached" }
                }
            }
        }

        $inventory.Add($item)
    }
}

# ------------------------------------------------------------
# Validate, CSV, upload, cleanup
# ------------------------------------------------------------

Write-Log "Inventory collection completed."
Write-Log "Total resources collected: $($inventory.Count)"

if ($inventory.Count -eq 0) {
    throw "Inventory is empty. No CSV will be uploaded."
}

Write-Log "Generating CSV..."

$csv = $inventory | ConvertTo-Csv -NoTypeInformation | Out-String

$tempFile = Join-Path -Path $env:TEMP -ChildPath "Azure-FinOps-Inventory-$([guid]::NewGuid()).csv"

[System.IO.File]::WriteAllText($tempFile, $csv, [System.Text.UTF8Encoding]::new($false))

$fileName = "Azure-FinOps-Inventory-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').csv"

Write-Log "Uploading inventory to Storage Account..."
Write-Log "Blob: $StorageContainer/$fileName"


Set-AzStorageBlobContent `
    -File $tempFile `
    -Container $StorageContainer `
    -Blob $fileName `
    -Context $storageContext `
    -Force `
    -ErrorAction Stop | Out-Null

Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

Write-Log "=================================================="
Write-Log "FinOps inventory completed successfully."
Write-Log "Resources collected: $($inventory.Count)"
Write-Log "Storage Account: $StorageAccountName"
Write-Log "Container: $StorageContainer"
Write-Log "Blob: $fileName"
Write-Log "=================================================="