# ===== Parameters =====
param(
    [Parameter(Mandatory=$true)]
    [string]$CollectionUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
    
    [Parameter(Mandatory=$true)]
    [string]$PAT,
    
    [Parameter(Mandatory=$true)]
    [string]$ConfigFilePath,
    
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 50,
    
    [Parameter(Mandatory=$false)]
    [int]$RetrievalBatchSize = 200
)

# ===== Initialize Logging =====
$LogFile = "field-copy-optimized-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
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
$headersPatch = $auth.Clone()
$headersPatch["Content-Type"] = "application/json-patch+json"

# ===== API version =====
$ApiVer = "7.1"

# ===== Functions =====
function Get-WorkItemTypes {
    param([string]$OrgUrl, [string]$ProjectName, [hashtable]$Headers, [string]$ApiVersion)
    $categoriesUrl = "$OrgUrl/$ProjectName/_apis/wit/workitemtypecategories?api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $categoriesUrl -Headers $Headers -Method Get
        $typeNames = @()
        foreach ($category in $response.value) {
            if ($category.defaultWorkItemType) {
                $typeName = $category.defaultWorkItemType.name
                if ($typeNames -notcontains $typeName) {
                    $typeNames += $typeName
                }
            }
            foreach ($wit in $category.workItemTypes) {
                $typeName = $wit.name
                if ($wit.name -and $typeNames -notcontains $typeName) {
                    $typeNames += $typeName
                }
            }
        }
        return $typeNames | ForEach-Object { [PSCustomObject]@{ name = $_ } }
    }
    catch {
        Write-Log "Failed to get work item types for ${ProjectName}: $($_.Exception.Message)" -Color "Red"
        return @()
    }
}

function Get-WorkItemTypeFields {
    param([string]$OrgUrl, [string]$ProjectName, [string]$WitName, [hashtable]$Headers, [string]$ApiVersion)
    $encodedWitName = $WitName.Replace(" ", "%20")
    $fieldsUrl = "$OrgUrl/$ProjectName/_apis/wit/workitemtypes/$encodedWitName/fields?api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $fieldsUrl -Headers $Headers -Method Get
        return $response.value
    }
    catch {
        Write-Log "Failed to get fields for $WitName in ${ProjectName}: $($_.Exception.Message)" -Color "Red"
        return @()
    }
}

function Get-AllWorkItemsWithSourceData {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [array]$SourceFields,
        [hashtable]$Headers,
        [string]$ApiVersion
    )
    
    Write-Log "  Querying work items with data in any source field..." -Color "Yellow"
    
    # Debug: Check incoming SourceFields parameter
    Write-Log "  [DEBUG] SourceFields parameter type: $($SourceFields.GetType().Name)" -Color "Magenta"
    Write-Log "  [DEBUG] SourceFields count: $($SourceFields.Count)" -Color "Magenta"
    if ($SourceFields) {
        Write-Log "  [DEBUG] SourceFields values: $($SourceFields | ConvertTo-Json -Compress)" -Color "Magenta"
    }
    
    # Validate SourceFields parameter
    if (-not $SourceFields -or $SourceFields.Count -eq 0) {
        Write-Log "  No source fields provided" -Color "Red"
        return @()
    }
    
    # Define excluded work item types
    $excludedTypes = @('Shared Steps', 'Shared Parameter', 'Code Review Request', 'Code Review Response', 'Feedback Request', 'Feedback Response')
    Write-Log "  Excluding work item types: $($excludedTypes -join ', ')" -Color "Gray"
    
    # Build WIQL query to find work items with data in any source field
    $fieldConditions = @()
    foreach ($sourceField in $SourceFields) {
        if ($sourceField) {
            $fieldConditions += "[$sourceField] <> ''"
        }
    }
    
    if ($fieldConditions.Count -eq 0) {
        Write-Log "  No valid source fields to query" -Color "Red"
        return @()
    }
    
    $whereClause = [String]::Join(" OR ", $fieldConditions)
    
    $typeExclusions = @()
    foreach ($excludedType in $excludedTypes) {
        $typeExclusions += "[System.WorkItemType] <> '$excludedType'"
    }
    $typeExcludeClause = [String]::Join(" AND ", $typeExclusions)
    
    # Build complete query with proper parentheses
    $completeQuery = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$ProjectName' AND ($whereClause) AND ($typeExcludeClause)"
    
    Write-Log "  [WIQL QUERY] Copy the query below to test in Azure DevOps:" -Color "Cyan"
    Write-Log "  $completeQuery" -Color "White"
    Write-Log "" -Color "White"
    
    $wiql = @{
        query = $completeQuery
    } | ConvertTo-Json -Depth 3
    
    $wiqlUrl = "$OrgUrl/$ProjectName/_apis/wit/wiql?api-version=$ApiVersion"
    try {
        $wiqlRes = Invoke-RestMethod -Uri $wiqlUrl -Headers $Headers -Method Post -Body $wiql -ContentType "application/json"
        $ids = $wiqlRes.workItems.id
        
        if ($ids -and $ids.Count -gt 0) {
            Write-Log "  Found $($ids.Count) work items with data in source fields" -Color "Green"
            return $ids
        }
        else {
            Write-Log "  No work items found with data in source fields" -Color "Gray"
            return @()
        }
    }
    catch {
        Write-Log "  Failed to query work items: $($_.Exception.Message)" -Color "Red"
        throw
    }
}

function Copy-AllFieldDataOptimized {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [array]$FieldMappings,
        [hashtable]$Headers,
        [hashtable]$HeadersPatch,
        [string]$ApiVersion,
        [int]$UpdateBatchSize = 50,
        [int]$RetrievalBatchSize = 200
    )
    
    Write-Log "========================================" -Color "Cyan"
    Write-Log "OPTIMIZED FIELD COPY OPERATION" -Color "Cyan"
    Write-Log "========================================" -Color "Cyan"
    
    # Debug: Check FieldMappings parameter
    Write-Log "[DEBUG] FieldMappings parameter type: $($FieldMappings.GetType().Name)" -Color "Magenta"
    Write-Log "[DEBUG] FieldMappings count: $($FieldMappings.Count)" -Color "Magenta"
    
    if ($FieldMappings -and $FieldMappings.Count -gt 0) {
        for ($i = 0; $i -lt $FieldMappings.Count; $i++) {
            $mapping = $FieldMappings[$i]
            Write-Log "[DEBUG] Mapping[$i]: sourceField='$($mapping.sourceField)', targetField='$($mapping.targetField)'" -Color "Magenta"
        }
    } else {
        Write-Log "[DEBUG] FieldMappings is null or empty!" -Color "Red"
    }
    
    Write-Log "Field Mappings: $($FieldMappings.Count)" -Color "White"
    Write-Log "Update Batch Size: $UpdateBatchSize" -Color "White"
    Write-Log "Retrieval Batch Size: $RetrievalBatchSize" -Color "White"
    Write-Log ""
    
    # Extract all source fields and filter out nulls/empty values
    Write-Log "[DEBUG] Extracting source fields..." -Color "Magenta"
    $sourceFields = @()
    
    if ($FieldMappings) {
        foreach ($mapping in $FieldMappings) {
            if ($mapping -and $mapping.sourceField) {
                $sourceFields += $mapping.sourceField
            }
        }
        $sourceFields = $sourceFields | Sort-Object -Unique
    }
    
    Write-Log "[DEBUG] Extracted source fields count: $($sourceFields.Count)" -Color "Magenta"
    if ($sourceFields.Count -gt 0) {
        Write-Log "[DEBUG] Source fields array: $($sourceFields | ConvertTo-Json -Compress)" -Color "Magenta"
    }
    
    if (-not $sourceFields -or $sourceFields.Count -eq 0) {
        Write-Log "No valid source fields found in field mappings" -Color "Red"
        return @{
            Success = $false
            ProcessedWorkItems = 0
            SuccessfulUpdates = 0
            FailedUpdates = 0
            FieldMappingsApplied = @{}
        }
    }
    
    Write-Log "Source Fields: $($sourceFields -join ', ')" -Color "White"
    Write-Log ""
    
    # Get all work items with data in any source field
    $workItemIds = Get-AllWorkItemsWithSourceData -OrgUrl $OrgUrl -ProjectName $ProjectName -SourceFields $sourceFields -Headers $Headers -ApiVersion $ApiVersion
    
    # Ensure workItemIds is always an array
    if ($workItemIds -is [int] -or $workItemIds -is [string]) {
        $workItemIds = @($workItemIds)
    } elseif ($null -eq $workItemIds) {
        $workItemIds = @()
    } elseif ($workItemIds -isnot [array]) {
        $workItemIds = @($workItemIds)
    }
    
    Write-Log "[DEBUG] WorkItemIds type: $($workItemIds.GetType().Name), Count: $($workItemIds.Count)" -Color "Magenta"
    
    if (-not $workItemIds -or $workItemIds.Count -eq 0) {
        Write-Log "No work items found to process." -Color "Yellow"
        return @{
            Success = $true
            ProcessedWorkItems = 0
            SuccessfulUpdates = 0
            FailedUpdates = 0
            FieldMappingsApplied = @{}
        }
    }
    
    # Initialize counters
    $processedWorkItems = 0
    $successfulUpdates = 0
    $failedUpdates = 0
    $fieldMappingsApplied = @{}
    $FieldMappings | ForEach-Object { $fieldMappingsApplied[$_.sourceField] = 0 }
    
    # Process work items in batches
    $totalBatches = [Math]::Ceiling($workItemIds.Count / $RetrievalBatchSize)
    Write-Log "Processing $($workItemIds.Count) work items in $totalBatches retrieval batches..." -Color "White"
    
    for ($i = 0; $i -lt $workItemIds.Count; $i += $RetrievalBatchSize) {
        $batchNum = [Math]::Floor($i / $RetrievalBatchSize) + 1
        $endIndex = [Math]::Min($i + $RetrievalBatchSize - 1, $workItemIds.Count - 1)
        
        # Extract chunk - handle single item case
        $chunk = @()
        if ($i -eq $endIndex) {
            if ($workItemIds[$i]) {
                $chunk = @($workItemIds[$i])
            }
        } else {
            $chunkTemp = $workItemIds[$i..$endIndex]
            if ($chunkTemp) {
                $chunk = @($chunkTemp)
            }
        }
        
        Write-Log "  [DEBUG] Batch $batchNum - Initial chunk null check: $($null -eq $chunk)" -Color "Magenta"
        
        # Ensure chunk is an array and not null
        if ($null -eq $chunk) {
            Write-Log "  [WARNING] Batch $batchNum - chunk is null, creating empty array" -Color "Yellow"
            $chunk = @()
        } elseif ($chunk -isnot [array]) {
            $chunk = @($chunk)
        }
        
        # Debug: Check chunk
        if ($chunk) {
            Write-Log "  [DEBUG] Batch $batchNum - chunk type: $($chunk.GetType().Name), count: $($chunk.Count)" -Color "Magenta"
            if ($chunk.Count -gt 0) {
                Write-Log "  [DEBUG] Batch $batchNum - first ID: $($chunk[0]), last ID: $($chunk[-1])" -Color "Magenta"
            }
        } else {
            Write-Log "  [DEBUG] Batch $batchNum - chunk is null or empty" -Color "Magenta"
        }
        
        # Filter out any null values and ensure we have a proper array
        $validIds = @()
        foreach ($id in $chunk) {
            if ($id) {
                $validIds += $id
            }
        }
        
        if ($validIds.Count -eq 0) {
            Write-Log "  [WARNING] Batch $batchNum has no valid IDs, skipping..." -Color "Yellow"
            continue
        }
        
        $idsParam = [String]::Join(",", $validIds)
        Write-Log "  [DEBUG] IDs parameter: $idsParam" -Color "Magenta"
        
        Write-Log "  Processing retrieval batch $batchNum of $totalBatches (WIs $($i + 1)-$($endIndex + 1))..." -Color "Cyan"
        
        # Get work item data
        $getUrl = "$OrgUrl/_apis/wit/workitems?ids=$idsParam&`$expand=Fields&api-version=$ApiVersion"
        try {
            $wis = Invoke-RestMethod -Uri $getUrl -Headers $Headers -Method Get
            
            # Collect work items that need updates with all applicable field mappings
            $workItemsToUpdate = @()
            
            foreach ($wi in $wis.value) {
                $applicableMappings = @()
                
                # Check each field mapping for this work item
                foreach ($mapping in $FieldMappings) {
                    $sourceValue = $wi.fields."$($mapping.sourceField)"
                    if ($null -ne $sourceValue -and $sourceValue -ne '' -and $sourceValue -ne ' ') {
                        $applicableMappings += @{
                            SourceField = $mapping.sourceField
                            TargetField = $mapping.targetField
                            Value = $sourceValue
                        }
                    }
                }
                
                # Only add work item if it has applicable mappings
                if ($applicableMappings.Count -gt 0) {
                    $workItemsToUpdate += @{
                        Id = $wi.id
                        Mappings = $applicableMappings
                    }
                }
            }
            
            # Process updates in smaller sub-batches
            if ($workItemsToUpdate.Count -gt 0) {
                Write-Log "    Found $($workItemsToUpdate.Count) work items requiring field updates" -Color "Green"
                
                for ($j = 0; $j -lt $workItemsToUpdate.Count; $j += $UpdateBatchSize) {
                    $updateEndIndex = [Math]::Min($j + $UpdateBatchSize - 1, $workItemsToUpdate.Count - 1)
                    $updateChunk = $workItemsToUpdate[$j..$updateEndIndex]
                    
                    # Process each work item in the update chunk
                    foreach ($wiInfo in $updateChunk) {
                        # Build patch operations for all applicable field mappings
                        $patchOps = @()
                        $appliedMappings = @()
                        
                        foreach ($mapping in $wiInfo.Mappings) {
                            $patchOps += @{
                                op = "add"
                                path = "/fields/$($mapping.TargetField)"
                                value = $mapping.Value
                            }
                            $appliedMappings += "$($mapping.SourceField) -> $($mapping.TargetField)"
                            $fieldMappingsApplied[$mapping.SourceField]++
                        }
                        
                        $patch = ConvertTo-Json @($patchOps) -Depth 10 -Compress
                        
                        $updateUrl = "$OrgUrl/_apis/wit/workitems/$($wiInfo.Id)?api-version=$ApiVersion"
                        try {
                            Invoke-RestMethod -Uri $updateUrl -Headers $HeadersPatch -Method Patch -Body $patch | Out-Null
                            $successfulUpdates++
                            Write-Log "      ✓ Updated WI $($wiInfo.Id): $($appliedMappings -join ', ')" -Color "Green"
                        }
                        catch {
                            $failedUpdates++
                            Write-Log "      ✗ Failed WI $($wiInfo.Id): $($_.Exception.Message)" -Color "Red"
                            if ($_.ErrorDetails.Message) {
                                Write-Log "        Details: $($_.ErrorDetails.Message)" -Color "Red"
                            }
                        }
                        
                        $processedWorkItems++
                        
                        # Progress reporting
                        if ($processedWorkItems % 50 -eq 0) {
                            Write-Log "      Progress: Processed $processedWorkItems of $($workItemIds.Count) work items..." -Color "Yellow"
                        }
                        
                        # Add small delay to avoid rate limiting
                        if ($processedWorkItems % 10 -eq 0) {
                            Start-Sleep -Milliseconds 100
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "  ERROR retrieving work items batch: $($_.Exception.Message)" -Color "Red"
            $failedUpdates += $chunk.Count
            continue
        }
    }
    
    return @{
        Success = $true
        ProcessedWorkItems = $processedWorkItems
        SuccessfulUpdates = $successfulUpdates
        FailedUpdates = $failedUpdates
        FieldMappingsApplied = $fieldMappingsApplied
        TotalWorkItemsFound = $workItemIds.Count
    }
}

function Validate-FieldMappingsForWorkItemType {
    param(
        [array]$FieldMappings,
        [array]$AvailableFields,
        [string]$WorkItemTypeName
    )
    
    $validMappings = @()
    $invalidMappings = @()
    
    foreach ($mapping in $FieldMappings) {
        $sourceExists = $AvailableFields | Where-Object { $_.referenceName -eq $mapping.sourceField }
        $targetExists = $AvailableFields | Where-Object { $_.referenceName -eq $mapping.targetField }
        
        if ($sourceExists -and $targetExists) {
            $validMappings += $mapping
        }
        else {
            $invalidMappings += @{
                Mapping = $mapping
                SourceExists = $null -ne $sourceExists
                TargetExists = $null -ne $targetExists
            }
        }
    }
    
    return @{
        Valid = $validMappings
        Invalid = $invalidMappings
        WorkItemType = $WorkItemTypeName
    }
}

# ===== Main Script =====
Write-Log "========================================" -Color "Cyan"
Write-Log "OPTIMIZED Field Data Copy Script" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Collection: $CollectionUrl" -Color "White"
Write-Log "Project: $ProjectName" -Color "White"
Write-Log "Config File: $ConfigFilePath" -Color "White"
Write-Log "Update Batch Size: $BatchSize" -Color "White"
Write-Log "Retrieval Batch Size: $RetrievalBatchSize" -Color "White"
Write-Log "Log File: $LogFile" -Color "White"
Write-Log ""
Write-Log "OPTIMIZATION FEATURES:" -Color "Yellow"
Write-Log "- Single WIQL query to find all work items with source data" -Color "Gray"
Write-Log "- All field mappings applied to each work item in single API call" -Color "Gray"
Write-Log "- Configurable batch sizes for retrieval and updates" -Color "Gray"
Write-Log "- Progress tracking and performance metrics" -Color "Gray"
Write-Log "- Comprehensive validation and error handling" -Color "Gray"
Write-Log "- Automatic filtering of administrative work item types" -Color "Gray"
Write-Log ""

# Load configuration
if (-not (Test-Path $ConfigFilePath)) {
    Write-Log "Configuration file not found: $ConfigFilePath" -Color "Red"
    exit 1
}

try {
    $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
    Write-Log "Loaded $($config.fieldMappings.Count) field mapping(s)" -Color "Green"
    
    # Display field mappings
    foreach ($mapping in $config.fieldMappings) {
        Write-Log "  $($mapping.sourceField) -> $($mapping.targetField)" -Color "Gray"
    }
    Write-Log ""
}
catch {
    Write-Log "Failed to parse configuration file: $($_.Exception.Message)" -Color "Red"
    exit 1
}

# Get work item types
Write-Log "Fetching work item types..." -Color "Yellow"
$workItemTypes = Get-WorkItemTypes -OrgUrl $CollectionUrl -ProjectName $ProjectName -Headers $auth -ApiVersion $ApiVer

if (-not $workItemTypes -or $workItemTypes.Count -eq 0) {
    Write-Log "No work item types found." -Color "Red"
    exit 1
}

Write-Log "Found $($workItemTypes.Count) work item type(s): $($workItemTypes.name -join ', ')" -Color "Green"
Write-Log ""

# Validate field mappings across all work item types
Write-Log "Validating field mappings..." -Color "Yellow"
$validationResults = @{}
$allValidMappings = @()

foreach ($wit in $workItemTypes) {
    $witName = $wit.name
    $fields = Get-WorkItemTypeFields -OrgUrl $CollectionUrl -ProjectName $ProjectName -WitName $witName -Headers $auth -ApiVersion $ApiVer
    
    if ($fields) {
        $validation = Validate-FieldMappingsForWorkItemType -FieldMappings $config.fieldMappings -AvailableFields $fields -WorkItemTypeName $witName
        $validationResults[$witName] = $validation
        
        if ($validation.Valid.Count -gt 0) {
            Write-Log "  ${witName}: $($validation.Valid.Count) valid mapping(s)" -Color "Green"
            $allValidMappings += $validation.Valid
        }
        
        if ($validation.Invalid.Count -gt 0) {
            Write-Log "  ${witName}: $($validation.Invalid.Count) invalid mapping(s)" -Color "Yellow"
            foreach ($invalid in $validation.Invalid) {
                $missingFields = @()
                if (-not $invalid.SourceExists) { $missingFields += "source" }
                if (-not $invalid.TargetExists) { $missingFields += "target" }
                Write-Log "    ✗ $($invalid.Mapping.sourceField) -> $($invalid.Mapping.targetField) (missing: $($missingFields -join ', '))" -Color "Red"
            }
        }
    }
}

# Get unique valid mappings (avoid duplicates across work item types)
# Use a hashtable to track unique mappings by sourceField
$uniqueMappingsHash = @{}
foreach ($mapping in $allValidMappings) {
    $key = "$($mapping.sourceField)|$($mapping.targetField)"
    if (-not $uniqueMappingsHash.ContainsKey($key)) {
        $uniqueMappingsHash[$key] = $mapping
    }
}
$uniqueValidMappings = $uniqueMappingsHash.Values

Write-Log "[DEBUG] Total valid mappings collected: $($allValidMappings.Count)" -Color "Magenta"
Write-Log "[DEBUG] Unique valid mappings after deduplication: $($uniqueValidMappings.Count)" -Color "Magenta"

if ($uniqueValidMappings.Count -eq 0) {
    Write-Log "No valid field mappings found. Please check field names and ensure target fields exist." -Color "Red"
    exit 1
}

Write-Log ""
Write-Log "Processing $($uniqueValidMappings.Count) unique valid field mapping(s)..." -Color "Green"
Write-Log ""

# Start timer for performance measurement
$startTime = Get-Date

# Execute optimized field copy
try {
    $result = Copy-AllFieldDataOptimized -OrgUrl $CollectionUrl -ProjectName $ProjectName `
        -FieldMappings $uniqueValidMappings -Headers $auth -HeadersPatch $headersPatch `
        -ApiVersion $ApiVer -UpdateBatchSize $BatchSize -RetrievalBatchSize $RetrievalBatchSize
    
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    # Final Summary
    Write-Log ""
    Write-Log "========================================" -Color "Cyan"
    Write-Log "FINAL SUMMARY" -Color "Cyan"
    Write-Log "========================================" -Color "Cyan"
    Write-Log "Execution Time: $($duration.ToString('mm\:ss\.fff'))" -Color "White"
    Write-Log "Work Items Found: $($result.TotalWorkItemsFound)" -Color "White"
    Write-Log "Work Items Processed: $($result.ProcessedWorkItems)" -Color "White"
    Write-Log "Successful Updates: $($result.SuccessfulUpdates)" -Color "Green"
    Write-Log "Failed Updates: $($result.FailedUpdates)" -Color "Red"
    Write-Log ""
    Write-Log "Field Mapping Applications:" -Color "White"
    foreach ($sourceField in $result.FieldMappingsApplied.Keys) {
        $count = $result.FieldMappingsApplied[$sourceField]
        if ($count -gt 0) {
            Write-Log "  ${sourceField}: $count work item(s)" -Color "Green"
        }
    }
    Write-Log ""
    Write-Log "Performance Metrics:" -Color "Yellow"
    if ($result.ProcessedWorkItems -gt 0 -and $duration.TotalSeconds -gt 0) {
        $wiPerSecond = [Math]::Round($result.ProcessedWorkItems / $duration.TotalSeconds, 2)
        Write-Log "  Work Items/Second: $wiPerSecond" -Color "Gray"
    }
    if ($result.SuccessfulUpdates -gt 0 -and $duration.TotalSeconds -gt 0) {
        $updatesPerSecond = [Math]::Round($result.SuccessfulUpdates / $duration.TotalSeconds, 2)
        Write-Log "  Updates/Second: $updatesPerSecond" -Color "Gray"
    }
    Write-Log ""
    Write-Log "Log saved to: $LogFile" -Color "Cyan"
    Write-Log "========================================" -Color "Cyan"
    
    # Exit with appropriate code
    if ($result.FailedUpdates -gt 0) {
        Write-Log "Script completed with some errors." -Color "Yellow"
        exit 1
    }
    else {
        Write-Log "Script completed successfully." -Color "Green"
        exit 0
    }
}
catch {
    Write-Log "CRITICAL ERROR: $($_.Exception.Message)" -Color "Red"
    Write-Log "Log saved to: $LogFile" -Color "Cyan"
    exit
}