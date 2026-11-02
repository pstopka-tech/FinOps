#title: Top_10_Expensive_Resources
#author: Patrycja Stopka patrycja.stopka@gmail.com
#date: 30.10.2026
#version: 4.3

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

function Invoke-CostQueryWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Payload,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 5
    )

    $attempt = 0
    $response = $null

    while ($true) {
        $attempt++

        try {
            $response = Invoke-AzRestMethod `
                -Method POST `
                -Uri $Uri `
                -Payload $Payload `
                -ErrorAction Stop

            if (
                $response.StatusCode -eq 429 -or
                $response.StatusCode -eq 503
            ) {
                throw "Temporary Cost Management throttling: HTTP $($response.StatusCode)"
            }

            if (
                $response.StatusCode -lt 200 -or
                $response.StatusCode -ge 300
            ) {
                throw "Cost Management query failed with HTTP status $($response.StatusCode): $($response.Content)"
            }

            return $response
        }
        catch {
            $isRetryable = $false
            $retryAfterSeconds = 30

            if (
                $_.Exception.Message -match "HTTP 429" -or
                $_.Exception.Message -match "HTTP 503"
            ) {
                $isRetryable = $true
            }

            if (
                $response -and
                $response.Headers -and
                $response.Headers["Retry-After"]
            ) {
                try {
                    $retryAfterSeconds = [int]$response.Headers["Retry-After"]
                }
                catch {
                    $retryAfterSeconds = 30
                }
            }

            if (
                -not $isRetryable -or
                $attempt -ge $MaxAttempts
            ) {
                throw
            }

            $waitSeconds = [math]::Min(
                $retryAfterSeconds * $attempt,
                300
            )

            Write-Log "Cost Management request throttled. Waiting $waitSeconds second(s) before retry $attempt of $($MaxAttempts - 1)..."

            Start-Sleep -Seconds $waitSeconds
        }
    }
}

try {
    # ------------------------------------------------------------
    # 1. Connect using Managed Identity
    # ------------------------------------------------------------

    Disable-AzContextAutosave -Scope Process | Out-Null

    Write-Log "Connecting to Azure using Managed Identity..."

    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

    Write-Log "Connected to Azure."

    # ------------------------------------------------------------
    # 2. Reporting period: previous full calendar month
    # ------------------------------------------------------------

    $today = (Get-Date).Date

    $periodEnd = [datetime]::new(
        $today.Year,
        $today.Month,
        1
    )

    $periodStart = $periodEnd.AddMonths(-1)

    $fromDate = $periodStart.ToString("yyyy-MM-ddT00:00:00Z")
    $toDate = $periodEnd.ToString("yyyy-MM-ddT00:00:00Z")
    $reportMonth = $periodStart.ToString("yyyy-MM")

    Write-Log "Reporting month: $reportMonth"
    Write-Log "Period: $fromDate to $toDate"

    # ------------------------------------------------------------
    # 3. Initialize Storage
    # ------------------------------------------------------------

    Write-Log "Setting Storage subscription context..."

    Set-AzContext `
        -SubscriptionId $StorageSubscriptionId `
        -ErrorAction Stop | Out-Null

    $storageAccount = Get-AzStorageAccount `
        -ResourceGroupName $StorageResourceGroup `
        -Name $StorageAccountName `
        -ErrorAction Stop

    $storageContext = New-AzStorageContext `
        -StorageAccountName $storageAccount.StorageAccountName `
        -UseConnectedAccount `
        -ErrorAction Stop

    Write-Log "Storage context created successfully."

    # ------------------------------------------------------------
    # 4. Get enabled subscriptions
    # ------------------------------------------------------------

    Write-Log "Getting enabled subscriptions..."

    $subscriptions = @(
        Get-AzSubscription |
            Where-Object { $_.State -eq "Enabled" }
    )

    Write-Log "Found $($subscriptions.Count) enabled subscriptions."

    if ($subscriptions.Count -eq 0) {
        throw "No enabled subscriptions found."
    }

    # ------------------------------------------------------------
    # 5. Query Cost Management and aggregate immediately
    # ------------------------------------------------------------

    # Key: ResourceId
    # Value: aggregated cost object
    $resourceAggregates = @{}

    $totalRowsProcessed = 0

    foreach ($sub in $subscriptions) {

        Write-Log "--------------------------------------------------"
        Write-Log "Processing subscription: $($sub.Name)"

        $scope = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2025-03-01"

        $dataset = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{
                    name     = "PreTaxCost"
                    function = "Sum"
                }
            }
            grouping = @(
                @{
                    type = "Dimension"
                    name = "ResourceId"
                }
            )
        }

        $body = @{
            type = "Usage"
            timeframe = "Custom"
            timePeriod = @{
                from = $fromDate
                to = $toDate
            }
            dataset = $dataset
        } | ConvertTo-Json -Depth 10

        try {
            $pageNumber = 1
            $subscriptionRows = 0
            $nextLink = $null

            do {
                Write-Log "Querying page $pageNumber for $($sub.Name)..."

                if ($pageNumber -eq 1) {
                    $requestUri = "https://management.azure.com$scope"
                }
                else {
                    $requestUri = $nextLink
                }

                $response = Invoke-CostQueryWithRetry `
                    -Uri $requestUri `
                    -Payload $body

                $data = $response.Content | ConvertFrom-Json
                $properties = $data.properties

                if (-not $properties) {
                    Write-Log "WARNING: Response has no properties object for $($sub.Name), page $pageNumber."
                    break
                }

                $rows = @($properties.rows)

                if ($rows.Count -eq 0) {
                    break
                }

                # Column indexes can differ between pages.
                $columnIndex = @{}

                for ($i = 0; $i -lt $properties.columns.Count; $i++) {
                    $columnIndex[$properties.columns[$i].name] = $i
                }

                if (
                    -not $columnIndex.ContainsKey("ResourceId") -or
                    -not $columnIndex.ContainsKey("PreTaxCost")
                ) {
                    throw "Cost query did not return ResourceId and PreTaxCost columns for $($sub.Name), page $pageNumber."
                }

                $resourceIdIndex = $columnIndex["ResourceId"]
                $costIndex = $columnIndex["PreTaxCost"]
                $currencyIndex = -1

                if ($columnIndex.ContainsKey("Currency")) {
                    $currencyIndex = $columnIndex["Currency"]
                }

                foreach ($row in $rows) {

                    $resourceId = [string]$row[$resourceIdIndex]

                    if ([string]::IsNullOrWhiteSpace($resourceId)) {
                        continue
                    }

                    $cost = [double]$row[$costIndex]

                    $currency = ""

                    if ($currencyIndex -ge 0) {
                        $currency = [string]$row[$currencyIndex]
                    }

                    if ($resourceAggregates.ContainsKey($resourceId)) {

                        # Aggregate immediately instead of storing every row.
                        $resourceAggregates[$resourceId].Cost += $cost

                        if (
                            -not [string]::IsNullOrWhiteSpace($currency) -and
                            $resourceAggregates[$resourceId].Currency -ne $currency
                        ) {
                            $resourceAggregates[$resourceId].Currency = "MIXED"
                        }
                    }
                    else {
                        $resourceName = ($resourceId.TrimEnd("/") -split "/")[-1]

                        $resourceType = ""

                        if ($resourceId -match "/providers/([^/]+/[^/]+)") {
                            $resourceType = $Matches[1]
                        }

                        $resourceGroup = ""

                        if ($resourceId -match "/resourceGroups/([^/]+)") {
                            $resourceGroup = $Matches[1]
                        }

                        $resourceAggregates[$resourceId] = [PSCustomObject]@{
                            ResourceId       = $resourceId
                            ResourceName     = $resourceName
                            ResourceType     = $resourceType
                            ResourceGroup    = $resourceGroup
                            SubscriptionName = $sub.Name
                            SubscriptionId   = $sub.Id
                            Cost             = $cost
                            Currency         = $currency
                            ReportingMonth   = $reportMonth
                        }
                    }

                    $subscriptionRows++
                }

                $totalRowsProcessed += $rows.Count

                $nextLink = $properties.nextLink
                $pageNumber++

                # Small pause between pages to reduce throttling.
                if (-not [string]::IsNullOrWhiteSpace($nextLink)) {
                    Start-Sleep -Seconds 1
                }

            } while (
                -not [string]::IsNullOrWhiteSpace($nextLink)
            )

            Write-Log "Rows processed for $($sub.Name): $subscriptionRows"
        }
        catch {
            Write-Log "QUERY ERROR for $($sub.Name): $($_.Exception.Message)"
            throw
        }
    }

    Write-Log "Total API rows processed: $totalRowsProcessed"
    Write-Log "Unique resources aggregated: $($resourceAggregates.Count)"

    if ($resourceAggregates.Count -eq 0) {
        throw "No resource-level cost data was returned."
    }

    # ------------------------------------------------------------
    # 6. Select Top 10 most expensive resources
    # ------------------------------------------------------------

    Write-Log "Selecting Top 10 resources..."

    $top10 = @(
        $resourceAggregates.Values |
            Where-Object { $_.Currency -ne "MIXED" } |
            Sort-Object Cost -Descending |
            Select-Object -First 10
    )

    $rank = 0

    $top10 = @(
        $top10 | ForEach-Object {
            $rank++

            # Add properties to the existing object without emitting it twice.
            $_ | Add-Member `
                -NotePropertyName Rank `
                -NotePropertyValue $rank `
                -Force

            $_ | Add-Member `
                -NotePropertyName MonthlyCost `
                -NotePropertyValue ([math]::Round($_.Cost, 2)) `
                -Force

            # Return each resource exactly once.
            $_
        }
    )

    if ($top10.Count -lt 10) {
        Write-Log "WARNING: Only $($top10.Count) eligible resources were found for the Top 10 report."
    }

    Write-Log "Top 10 most expensive resources across all subscriptions:"

    $top10 |
        Select-Object Rank, ResourceName, MonthlyCost, Currency, SubscriptionName |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

    # ------------------------------------------------------------
    # 7. Export CSV
    # ------------------------------------------------------------

    # Add a run timestamp so repeated runs for the same month do not overwrite earlier reports.
    $runTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fileName = "Top10Resources_${reportMonth}_$runTimestamp.csv"
    $filePath = Join-Path $env:TEMP $fileName

    $top10 |
        Select-Object Rank, ResourceName, ResourceType, ResourceGroup,
            SubscriptionName, SubscriptionId, ResourceId, MonthlyCost,
            Currency, ReportingMonth |
        Export-Csv `
            -Path $filePath `
            -NoTypeInformation `
            -Encoding UTF8

    Write-Log "CSV generated successfully: $filePath"

    # ------------------------------------------------------------
    # 8. Upload CSV to Storage
    # ------------------------------------------------------------

    Write-Log "Uploading CSV to Storage..."

    Set-AzStorageBlobContent `
        -File $filePath `
        -Container $StorageContainer `
        -Blob $fileName `
        -Context $storageContext `
        -Force `
        -ErrorAction Stop | Out-Null

    Write-Log "SUCCESS: Uploaded $fileName to container $StorageContainer."
    Write-Log "Reporting month: $reportMonth"
    Write-Log "Total API rows processed: $totalRowsProcessed"
    Write-Log "Unique resources aggregated: $($resourceAggregates.Count)"
    Write-Log "Resources reported: $($top10.Count)"
}
catch {
    Write-Log "RUNBOOK FAILED: $($_.Exception.Message)"
    throw
}