
#title: FinOps_Snapshots_Inventory
#author: Patrycja Stopka patrycja.stopka@gmail.com
#date: 01.10.2026
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
# Snapshots collection
# ------------------------------------------------------------

$snapshots = [System.Collections.Generic.List[object]]::new()

foreach ($subscription in $subscriptions) {

    Write-Log "--------------------------------------------------"
    Write-Log "Processing subscription: $($subscription.Name)"

    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Unable to set context for subscription '$($subscription.Name)'. Error: $($_.Exception.Message)"
        continue
    }

    $subSnapshots = @()
    try {
        $subSnapshots = Get-AzSnapshot -ErrorAction Stop
        Write-Log "Found $($subSnapshots.Count) snapshots in subscription."
    }
    catch {
        Write-Warning "Unable to list snapshots in '$($subscription.Name)'. Error: $($_.Exception.Message)"
        continue
    }

    foreach ($snapshot in $subSnapshots) {

        $tags = ""
        if ($snapshot.Tags) {
            $tags = (
                $snapshot.Tags.GetEnumerator() |
                Sort-Object Key |
                ForEach-Object { "$($_.Key)=$($_.Value)" }
            ) -join ";"
        }

        $item = [PSCustomObject]@{
            CollectionDate       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            SubscriptionName     = $subscription.Name
            SubscriptionId       = $subscription.Id
            ResourceGroup        = $snapshot.ResourceGroupName
            SnapshotName         = $snapshot.Name
            Location             = $snapshot.Location
            ResourceId           = $snapshot.Id
            Tags                 = $tags
            DiskSizeGB           = $snapshot.DiskSizeGB
            SKU                  = $snapshot.Sku.Name
            SourceResourceId     = $snapshot.CreationData.SourceResourceId
            CreateOption         = $snapshot.CreationData.CreateOption
            OsType               = $snapshot.OsType
            Incremental          = $snapshot.Incremental
            TimeCreated          = $snapshot.TimeCreated
            ProvisioningState    = $snapshot.ProvisioningState
        }

        $snapshots.Add($item)
    }
}

# ------------------------------------------------------------
# Validate, CSV, upload, cleanup
# ------------------------------------------------------------

Write-Log "Snapshots collection completed."
Write-Log "Total snapshots collected: $($snapshots.Count)"

if ($snapshots.Count -eq 0) {
    Write-Log "No snapshots found. CSV will still be uploaded with headers only."
}

Write-Log "Generating CSV..."

$csv = $snapshots | ConvertTo-Csv -NoTypeInformation | Out-String

$tempFile = Join-Path -Path $env:TEMP -ChildPath "Azure-FinOps-Snapshots-$([guid]::NewGuid()).csv"

[System.IO.File]::WriteAllText($tempFile, $csv, [System.Text.UTF8Encoding]::new($false))

$fileName = "Azure-FinOps-Snapshots-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').csv"

Write-Log "Uploading snapshots inventory to Storage Account..."
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
Write-Log "Snapshots inventory completed successfully."
Write-Log "Snapshots collected: $($snapshots.Count)"
Write-Log "Storage Account: $StorageAccountName"
Write-Log "Container: $StorageContainer"
Write-Log "Blob: $fileName"
Write-Log "=================================================="
