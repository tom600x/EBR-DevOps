# ===== Parameters =====
param(
    [Parameter(Mandatory=$true)]
    [string]$CollectionUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
    
    [Parameter(Mandatory=$true)]
    [string]$PAT,
    
    [Parameter(Mandatory=$true)]
    [string]$ConfigFilePath
)

# ===== Initialize Logging =====
$LogFile = "query-update-optimized-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $logMessage
}

# ===== TLS =====
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ===== Auth header =====
$pair = ":$PAT"
$b64  = [System.Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
$auth = @{ Authorization = "Basic $b64" }

# ===== API version =====
$ApiVer = "7.1"

# ===== Functions =====
function Get-QueriesFromFolder {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$FolderId,
        [string]$FolderPath,
        [hashtable]$Headers,
        [string]$ApiVersion,
        [System.Collections.ArrayList]$QueriesList
    )
    
    # Get folder contents with depth to see children
    $folderUrl = "$OrgUrl/$ProjectName/_apis/wit/queries/$FolderId`?`$depth=1&`$expand=all&api-version=$ApiVersion"
    
    try {
        $folder = Invoke-RestMethod -Uri $folderUrl -Headers $Headers -Method Get
        
        if ($folder.children) {
            foreach ($item in $folder.children) {
                $itemPath = if ($FolderPath) { "$FolderPath/$($item.name)" } else { $item.name }
                
                # If it's a query (not a folder), add it
                if ($item.isFolder -ne $true -and $item.wiql) {
                    Write-Log "    Found query: $itemPath" -Color "Gray"
                    [void]$QueriesList.Add($item)
                }
                # If it's a folder, recurse into it
                elseif ($item.isFolder -eq $true) {
                    Write-Log "    Scanning folder: $itemPath" -Color "DarkGray"
                    Get-QueriesFromFolder -OrgUrl $OrgUrl -ProjectName $ProjectName `
                        -FolderId $item.id -FolderPath $itemPath `
                        -Headers $Headers -ApiVersion $ApiVersion -QueriesList $QueriesList
                }
            }
        }
    }
    catch {
        Write-Log "    Cannot access folder: $FolderPath - $($_.Exception.Message)" -Color "Yellow"
    }
}

function Get-WorkItemQueries {
    param([string]$OrgUrl, [string]$ProjectName, [hashtable]$Headers, [string]$ApiVersion)
    
    $allQueries = [System.Collections.ArrayList]::new()
    
    Write-Log "Discovering all queries (including subdirectories)..." -Color "Yellow"
    
    # Get root level items
    $queriesUrl = "$OrgUrl/$ProjectName/_apis/wit/queries?`$depth=1&api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $queriesUrl -Headers $Headers -Method Get
        
        foreach ($rootItem in $response.value) {
            # If it's a root-level query
            if ($rootItem.isFolder -ne $true -and $rootItem.wiql) {
                Write-Log "  Found query: $($rootItem.name)" -Color "Gray"
                [void]$allQueries.Add($rootItem)
            }
            # If it's a folder, recursively get all queries from it
            elseif ($rootItem.isFolder -eq $true) {
                Write-Log "  Scanning folder: $($rootItem.name)" -Color "DarkGray"
                Get-QueriesFromFolder -OrgUrl $OrgUrl -ProjectName $ProjectName `
                    -FolderId $rootItem.id -FolderPath $rootItem.name `
                    -Headers $Headers -ApiVersion $ApiVersion -QueriesList $allQueries
            }
        }
        
        Write-Log "Total queries found: $($allQueries.Count)" -Color "Green"
        Write-Log ""
        return $allQueries.ToArray()
    }
    catch {
        Write-Log "Failed to get queries for ${ProjectName}: $($_.Exception.Message)" -Color "Red"
        return @()
    }
}

function Update-QueryWithAllFieldMappings {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$QueryId,
        [string]$QueryName,
        [string]$QueryWiql,
        [array]$FieldMappings,
        [hashtable]$Headers,
        [string]$ApiVersion
    )
    
    $originalWiql = $QueryWiql
    $updatedWiql = $QueryWiql
    $appliedMappings = @()
    
    # Apply ALL field mappings to this query
    foreach ($mapping in $FieldMappings) {
        $sourceField = $mapping.sourceField
        $targetField = $mapping.targetField
        
        # Check if this query contains the source field
        if ($updatedWiql -match "\[$sourceField\]") {
            # Replace the field reference
            $updatedWiql = $updatedWiql -replace "\[$sourceField\]", "[$targetField]"
            $appliedMappings += "$sourceField → $targetField"
            Write-Log "      Applied mapping: $sourceField → $targetField" -Color "Gray"
        }
    }
    
    # If no changes were made, return early
    if ($updatedWiql -eq $originalWiql) {
        return @{
            Success = $true
            Updated = $false
            AppliedMappings = @()
            Message = "No field mappings found in this query"
        }
    }
    
    # Update the query with all changes at once
    $queryUrl = "$OrgUrl/$ProjectName/_apis/wit/queries/$QueryId`?api-version=$ApiVersion"
    $body = @{
        wiql = $updatedWiql
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $queryUrl -Headers $Headers -Method Patch -Body $body -ContentType "application/json" | Out-Null
        return @{
            Success = $true
            Updated = $true
            AppliedMappings = $appliedMappings
            Message = "Query updated successfully with $($appliedMappings.Count) field mapping(s)"
        }
    }
    catch {
        return @{
            Success = $false
            Updated = $false
            AppliedMappings = $appliedMappings
            Message = "Failed to update query: $($_.Exception.Message)"
        }
    }
}

function Process-AllQueriesOptimized {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [array]$Queries,
        [array]$FieldMappings,
        [hashtable]$Headers,
        [string]$ApiVersion
    )
    
    Write-Log "Processing all queries with optimized field mapping approach..." -Color "Yellow"
    Write-Log "Total queries to process: $($Queries.Count)" -Color "White"
    Write-Log "Total field mappings: $($FieldMappings.Count)" -Color "White"
    Write-Log ""
    
    $results = @{
        TotalQueries = $Queries.Count
        QueriesScanned = 0
        QueriesUpdated = 0
        QueriesFailed = 0
        TotalMappingsApplied = 0
        UpdatedQueries = @()
        FailedQueries = @()
        DetailedResults = @{}
    }
    
    $processedCount = 0
    
    foreach ($query in $Queries) {
        $processedCount++
        Write-Log "[$processedCount/$($Queries.Count)] Processing: $($query.name)" -Color "Cyan"
        
        $result = Update-QueryWithAllFieldMappings -OrgUrl $OrgUrl -ProjectName $ProjectName `
            -QueryId $query.id -QueryName $query.name -QueryWiql $query.wiql `
            -FieldMappings $FieldMappings -Headers $Headers -ApiVersion $ApiVersion
        
        $results.QueriesScanned++
        
        if ($result.Success -and $result.Updated) {
            Write-Log "    [UPDATED] $($result.Message)" -Color "Green"
            foreach ($mapping in $result.AppliedMappings) {
                Write-Log "      └─ $mapping" -Color "White"
            }
            $results.QueriesUpdated++
            $results.TotalMappingsApplied += $result.AppliedMappings.Count
            $results.UpdatedQueries += $query.name
            $results.DetailedResults[$query.name] = $result.AppliedMappings
        }
        elseif ($result.Success -and -not $result.Updated) {
            Write-Log "    [SKIPPED] $($result.Message)" -Color "Gray"
        }
        else {
            Write-Log "    [FAILED] $($result.Message)" -Color "Red"
            $results.QueriesFailed++
            $results.FailedQueries += $query.name
        }
        
        # Progress indicator for large datasets
        if ($processedCount % 10 -eq 0 -or $processedCount -eq $Queries.Count) {
            $percentComplete = [math]::Round(($processedCount / $Queries.Count) * 100, 1)
            Write-Log "    Progress: $percentComplete% ($processedCount/$($Queries.Count))" -Color "Yellow"
        }
    }
    
    return $results
}

# ===== Main Script =====
Write-Log "========================================" -Color "Cyan"
Write-Log "OPTIMIZED Query Update Script" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Collection: $CollectionUrl" -Color "White"
Write-Log "Project: $ProjectName" -Color "White"
Write-Log "Config File: $ConfigFilePath" -Color "White"
Write-Log "Log File: $LogFile" -Color "White"
Write-Log ""
Write-Log "OPTIMIZATION FEATURES:" -Color "Yellow"
Write-Log "- Single-pass query processing (scan each query once)" -Color "Gray"
Write-Log "- Batch field replacements (apply all mappings per query)" -Color "Gray"
Write-Log "- Reduced API calls from (Queries × FieldMappings) to Queries" -Color "Gray"
Write-Log "- Enhanced progress tracking and performance metrics" -Color "Gray"
Write-Log ""

# Load configuration
if (-not (Test-Path $ConfigFilePath)) {
    Write-Log "Configuration file not found: $ConfigFilePath" -Color "Red"
    exit 1
}

try {
    $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
    Write-Log "Loaded $($config.fieldMappings.Count) field mapping(s)" -Color "Green"
    
    # Display all field mappings
    Write-Log "Field Mappings to Apply:" -Color "White"
    foreach ($mapping in $config.fieldMappings) {
        Write-Log "  • $($mapping.sourceField) → $($mapping.targetField)" -Color "Gray"
    }
}
catch {
    Write-Log "Failed to parse configuration file: $($_.Exception.Message)" -Color "Red"
    exit 1
}

Write-Log ""

# Get all queries once
Write-Log "Fetching all work item queries..." -Color "Yellow"
$queries = Get-WorkItemQueries -OrgUrl $CollectionUrl -ProjectName $ProjectName -Headers $auth -ApiVersion $ApiVer

if (-not $queries -or $queries.Count -eq 0) {
    Write-Log "No queries found in project" -Color "Yellow"
    exit 0
}

Write-Log "Found $($queries.Count) queries to process" -Color "Green"
Write-Log ""

# Process all queries with optimized approach
$startTime = Get-Date
Write-Log "========================================" -Color "Cyan"
Write-Log "PROCESSING ALL QUERIES (OPTIMIZED)" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"

$results = Process-AllQueriesOptimized -OrgUrl $CollectionUrl -ProjectName $ProjectName `
    -Queries $queries -FieldMappings $config.fieldMappings `
    -Headers $auth -ApiVersion $ApiVer

$endTime = Get-Date
$duration = $endTime - $startTime

# Final Summary
Write-Log ""
Write-Log "========================================" -Color "Cyan"
Write-Log "OPTIMIZED PROCESSING SUMMARY" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Processing Time: $($duration.TotalSeconds.ToString('F2')) seconds" -Color "White"
Write-Log "Total Queries Scanned: $($results.QueriesScanned)" -Color "White"
Write-Log "Queries Updated: $($results.QueriesUpdated)" -Color "Green"
Write-Log "Queries Failed: $($results.QueriesFailed)" -Color "Red"
Write-Log "Total Field Mappings Applied: $($results.TotalMappingsApplied)" -Color "Green"
Write-Log "Average Mappings per Updated Query: $(if ($results.QueriesUpdated -gt 0) { [math]::Round($results.TotalMappingsApplied / $results.QueriesUpdated, 2) } else { 0 })" -Color "White"
Write-Log ""

if ($results.UpdatedQueries.Count -gt 0) {
    Write-Log "Successfully Updated Queries:" -Color "Green"
    foreach ($queryName in $results.UpdatedQueries) {
        $mappings = $results.DetailedResults[$queryName]
        Write-Log "  • $queryName" -Color "White"
        foreach ($mapping in $mappings) {
            Write-Log "    └─ $mapping" -Color "Gray"
        }
    }
    Write-Log ""
}

if ($results.FailedQueries.Count -gt 0) {
    Write-Log "Failed to Update Queries:" -Color "Red"
    foreach ($queryName in $results.FailedQueries) {
        Write-Log "  • $queryName" -Color "Red"
    }
    Write-Log ""
}

# Performance comparison estimate
$estimatedOriginalTime = $results.QueriesScanned * $config.fieldMappings.Count * 0.1 # Estimated 0.1 seconds per query per mapping
Write-Log "Performance Improvement Estimate:" -Color "Cyan"
Write-Log "  Estimated Original Approach: $($estimatedOriginalTime.ToString('F2')) seconds" -Color "Gray"
Write-Log "  Optimized Approach: $($duration.TotalSeconds.ToString('F2')) seconds" -Color "Green"
Write-Log "  Time Saved: $(($estimatedOriginalTime - $duration.TotalSeconds).ToString('F2')) seconds" -Color "Green"
Write-Log "  Efficiency Gain: $(if ($estimatedOriginalTime -gt 0) { [math]::Round((($estimatedOriginalTime - $duration.TotalSeconds) / $estimatedOriginalTime) * 100, 1) } else { 0 })%" -Color "Green"

Write-Log ""
Write-Log "Log saved to: $LogFile" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"