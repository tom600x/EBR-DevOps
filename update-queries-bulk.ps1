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
$LogFile = "query-update-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
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
function Get-WorkItemQueries {
    param([string]$OrgUrl, [string]$ProjectName, [hashtable]$Headers, [string]$ApiVersion)
    
    $allQueries = [System.Collections.ArrayList]::new()
    
    # Get root folders
    $queriesUrl = "$OrgUrl/$ProjectName/_apis/wit/queries?`$depth=1&api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $queriesUrl -Headers $Headers -Method Get
        
        foreach ($rootItem in $response.value) {
            if ($rootItem.isFolder -eq $true) {
                # Get queries from this folder
                $folderUrl = "$OrgUrl/$ProjectName/_apis/wit/queries/$($rootItem.id)`?`$depth=2&`$expand=all&api-version=$ApiVersion"
                try {
                    $folder = Invoke-RestMethod -Uri $folderUrl -Headers $Headers -Method Get
                    
                    if ($folder.children) {
                        foreach ($item in $folder.children) {
                            if ($item.isFolder -ne $true -and $item.wiql) {
                                [void]$allQueries.Add($item)
                            }
                            # Check sub-folders
                            elseif ($item.isFolder -eq $true -and $item.hasChildren -and $item.children) {
                                foreach ($subItem in $item.children) {
                                    if ($subItem.isFolder -ne $true -and $subItem.wiql) {
                                        [void]$allQueries.Add($subItem)
                                    }
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Log "Cannot access folder: $($rootItem.name) - $($_.Exception.Message)" -Color "Yellow"
                }
            }
            elseif ($rootItem.isFolder -eq $false -and $rootItem.wiql) {
                [void]$allQueries.Add($rootItem)
            }
        }
        
        return $allQueries.ToArray()
    }
    catch {
        Write-Log "Failed to get queries for ${ProjectName}: $($_.Exception.Message)" -Color "Red"
        return @()
    }
}

function Update-QueryWithNewField {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$QueryId,
        [string]$QueryWiql,
        [string]$OldFieldId,
        [string]$TargetFieldId,
        [hashtable]$Headers,
        [string]$ApiVersion
    )
    
    # Replace old field with new field in the WIQL
    $updatedWiql = $QueryWiql -replace "\[$OldFieldId\]", "[$TargetFieldId]"
    
    if ($updatedWiql -eq $QueryWiql) {
        return @{
            Success = $true
            Updated = $false
            Message = "No changes needed"
        }
    }
    
    # Update the query
    $queryUrl = "$OrgUrl/$ProjectName/_apis/wit/queries/$QueryId`?api-version=$ApiVersion"
    $body = @{
        wiql = $updatedWiql
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $queryUrl -Headers $Headers -Method Patch -Body $body -ContentType "application/json" | Out-Null
        return @{
            Success = $true
            Updated = $true
            Message = "Query updated successfully"
        }
    }
    catch {
        return @{
            Success = $false
            Updated = $false
            Message = "Failed to update query: $($_.Exception.Message)"
        }
    }
}

function Process-FieldMappingQueries {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$SourceField,
        [string]$TargetField,
        [array]$Queries,
        [hashtable]$Headers,
        [string]$ApiVersion
    )
    
    Write-Log "  Scanning queries for field '$SourceField'..." -Color "Yellow"
    
    $queriesToUpdate = @()
    $updatedQueries = @()
    $failedQueries = @()
    
    # Find queries that reference the source field
    foreach ($query in $Queries) {
        if ($query.wiql -and $query.wiql -match "\[$SourceField\]") {
            Write-Log "    Found field reference in: $($query.name)" -Color "Cyan"
            $queriesToUpdate += $query
        }
    }
    
    if ($queriesToUpdate.Count -eq 0) {
        Write-Log "    No queries found using field '$SourceField'" -Color "Gray"
        return @{
            TotalFound = 0
            Updated = 0
            Failed = 0
            UpdatedQueries = @()
            FailedQueries = @()
        }
    }
    
    Write-Log "    Found $($queriesToUpdate.Count) queries to update" -Color "White"
    
    # Update each query
    foreach ($query in $queriesToUpdate) {
        Write-Log "    Updating: $($query.name)" -Color "Cyan"
        
        $result = Update-QueryWithNewField -OrgUrl $OrgUrl -ProjectName $ProjectName `
            -QueryId $query.id -QueryWiql $query.wiql `
            -OldFieldId $SourceField -TargetFieldId $TargetField `
            -Headers $Headers -ApiVersion $ApiVersion
        
        if ($result.Success -and $result.Updated) {
            Write-Log "      [UPDATED] Query successfully updated" -Color "Green"
            $updatedQueries += $query.name
        }
        elseif ($result.Success -and -not $result.Updated) {
            Write-Log "      [SKIPPED] $($result.Message)" -Color "Gray"
        }
        else {
            Write-Log "      [FAILED] $($result.Message)" -Color "Red"
            $failedQueries += $query.name
        }
    }
    
    return @{
        TotalFound = $queriesToUpdate.Count
        Updated = $updatedQueries.Count
        Failed = $failedQueries.Count
        UpdatedQueries = $updatedQueries
        FailedQueries = $failedQueries
    }
}

# ===== Main Script =====
Write-Log "========================================" -Color "Cyan"
Write-Log "Query Update Script" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Collection: $CollectionUrl" -Color "White"
Write-Log "Project: $ProjectName" -Color "White"
Write-Log "Config File: $ConfigFilePath" -Color "White"
Write-Log "Log File: $LogFile" -Color "White"
Write-Log ""

# Load configuration
if (-not (Test-Path $ConfigFilePath)) {
    Write-Log "Configuration file not found: $ConfigFilePath" -Color "Red"
    exit 1
}

try {
    $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
    Write-Log "Loaded $($config.fieldMappings.Count) field mapping(s)" -Color "Green"
}
catch {
    Write-Log "Failed to parse configuration file: $($_.Exception.Message)" -Color "Red"
    exit 1
}

# Get all queries once
Write-Log "Fetching all work item queries..." -Color "Yellow"
$queries = Get-WorkItemQueries -OrgUrl $CollectionUrl -ProjectName $ProjectName -Headers $auth -ApiVersion $ApiVer

if (-not $queries -or $queries.Count -eq 0) {
    Write-Log "No queries found in project" -Color "Yellow"
    exit 0
}

Write-Log "Found $($queries.Count) queries to scan" -Color "Green"
Write-Log ""

# Initialize summary tracking
$summary = @{
    TotalMappings = $config.fieldMappings.Count
    ProcessedMappings = 0
    TotalQueriesFound = 0
    TotalQueriesUpdated = 0
    TotalQueriesFailed = 0
    MappingResults = @{}
}

# Process each field mapping
foreach ($mapping in $config.fieldMappings) {
    $sourceField = $mapping.sourceField
    $targetField = $mapping.targetField
    
    Write-Log "========================================" -Color "Cyan"
    Write-Log "Processing Field Mapping: $sourceField -> $targetField" -Color "Cyan"
    Write-Log "========================================" -Color "Cyan"
    
    $result = Process-FieldMappingQueries -OrgUrl $CollectionUrl -ProjectName $ProjectName `
        -SourceField $sourceField -TargetField $targetField `
        -Queries $queries -Headers $auth -ApiVersion $ApiVer
    
    # Update summary
    $summary.TotalQueriesFound += $result.TotalFound
    $summary.TotalQueriesUpdated += $result.Updated
    $summary.TotalQueriesFailed += $result.Failed
    $summary.ProcessedMappings++
    
    # Store detailed results for this mapping
    $summary.MappingResults["$sourceField -> $targetField"] = $result
    
    # Log results for this mapping
    if ($result.Updated -gt 0) {
        Write-Log "  [SUCCESS] Updated $($result.Updated) queries:" -Color "Green"
        foreach ($qName in $result.UpdatedQueries) {
            Write-Log "    - $qName" -Color "White"
        }
    }
    
    if ($result.Failed -gt 0) {
        Write-Log "  [FAILED] $($result.Failed) queries failed to update:" -Color "Red"
        foreach ($qName in $result.FailedQueries) {
            Write-Log "    - $qName" -Color "Red"
        }
    }
    
    if ($result.TotalFound -eq 0) {
        Write-Log "  [INFO] No queries found using field '$sourceField'" -Color "Gray"
    }
    
    Write-Log ""
}

# Final Summary
Write-Log "========================================" -Color "Cyan"
Write-Log "FINAL SUMMARY" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Total Field Mappings: $($summary.TotalMappings)" -Color "White"
Write-Log "Processed Mappings: $($summary.ProcessedMappings)" -Color "White"
Write-Log "Total Queries Found: $($summary.TotalQueriesFound)" -Color "White"
Write-Log "Total Queries Updated: $($summary.TotalQueriesUpdated)" -Color "Green"
Write-Log "Total Queries Failed: $($summary.TotalQueriesFailed)" -Color "Red"
Write-Log ""

if ($summary.MappingResults.Count -gt 0) {
    Write-Log "Detailed Results by Field Mapping:" -Color "White"
    foreach ($mapping in $summary.MappingResults.Keys) {
        $result = $summary.MappingResults[$mapping]
        Write-Log "  $mapping" -Color "White"
        Write-Log "    Found: $($result.TotalFound), Updated: $($result.Updated), Failed: $($result.Failed)" -Color "Gray"
    }
}

Write-Log ""
Write-Log "Log saved to: $LogFile" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"