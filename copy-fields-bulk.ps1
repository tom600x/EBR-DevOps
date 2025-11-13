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
    [int]$BatchSize = 50
)

# ===== Initialize Logging =====
$LogFile = "field-copy-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
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

function Copy-FieldData {
    param(
        [string]$OrgUrl,
        [string]$ProjectName,
        [string]$SourceFieldId,
        [string]$TargetFieldId,
        [hashtable]$Headers,
        [hashtable]$HeadersPatch,
        [string]$ApiVersion,
        [int]$UpdateBatchSize = 50
    )
    
    Write-Log "    Copying data from '$SourceFieldId' to '$TargetFieldId'..." -Color "Yellow"
    
    # Query work items with data in source field (filtered by current project)
    $wiql = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$ProjectName' AND [$SourceFieldId] <> ''"
    } | ConvertTo-Json -Depth 3
    
    $wiqlUrl = "$OrgUrl/$ProjectName/_apis/wit/wiql?api-version=$ApiVersion"
    try {
        $wiqlRes = Invoke-RestMethod -Uri $wiqlUrl -Headers $Headers -Method Post -Body $wiql -ContentType "application/json"
        $ids = $wiqlRes.workItems.id
        
        if ($ids -and $ids.Count -gt 0) {
            Write-Log "    Found $($ids.Count) work items with data in source field" -Color "White"
            
            $copiedCount = 0
            $errorCount = 0
            
            # Process in batches of 200 for retrieval, configurable batch for updates
            $retrievalBatchSize = 200
            $updateBatchSize = $UpdateBatchSize  # Use parameter value
            $totalBatches = [Math]::Ceiling($ids.Count / $retrievalBatchSize)
            
            Write-Log "    Processing $($ids.Count) work items in $totalBatches batches..." -Color "White"
            
            for ($i = 0; $i -lt $ids.Count; $i += $retrievalBatchSize) {
                $batchNum = [Math]::Floor($i / $retrievalBatchSize) + 1
                $endIndex = [Math]::Min($i + $retrievalBatchSize - 1, $ids.Count - 1)
                $chunk = $ids[$i..$endIndex]
                $idsParam = [String]::Join(",", $chunk)
                
                Write-Log "    Processing batch $batchNum of $totalBatches (WIs $($i + 1)-$($endIndex + 1))..." -Color "Gray"
                
                $getUrl = "$OrgUrl/_apis/wit/workitems?ids=$idsParam&`$expand=Fields&api-version=$ApiVersion"
                $wis = Invoke-RestMethod -Uri $getUrl -Headers $Headers -Method Get
                
                # Collect work items that need updates
                $workItemsToUpdate = @()
                foreach ($wi in $wis.value) {
                    $val = $wi.fields."$SourceFieldId"
                    if ($null -ne $val -and $val -ne '' -and $val -ne ' ') {
                        $workItemsToUpdate += @{
                            Id = $wi.id
                            Value = $val
                        }
                    }
                }
                
                # Process updates in smaller sub-batches to avoid API limits
                if ($workItemsToUpdate.Count -gt 0) {
                    for ($j = 0; $j -lt $workItemsToUpdate.Count; $j += $updateBatchSize) {
                        $updateEndIndex = [Math]::Min($j + $updateBatchSize - 1, $workItemsToUpdate.Count - 1)
                        $updateChunk = $workItemsToUpdate[$j..$updateEndIndex]
                        
                        # Process each work item in the update chunk
                        foreach ($wiInfo in $updateChunk) {
                            $patchOps = @(
                                @{
                                    op = "add"
                                    path = "/fields/$TargetFieldId"
                                    value = $wiInfo.Value
                                }
                            )
                            $patch = ConvertTo-Json @($patchOps) -Depth 10 -Compress
                            
                            $updateUrl = "$OrgUrl/_apis/wit/workitems/$($wiInfo.Id)?api-version=$ApiVersion"
                            try {
                                Invoke-RestMethod -Uri $updateUrl -Headers $HeadersPatch -Method Patch -Body $patch | Out-Null
                                $copiedCount++
                                if ($copiedCount % 100 -eq 0) {
                                    Write-Log "      Progress: Copied $copiedCount of $($ids.Count) work items..." -Color "Green"
                                }
                            }
                            catch {
                                $errorCount++
                                Write-Log "      ERROR updating WI $($wiInfo.Id): $($_.Exception.Message)" -Color "Red"
                                if ($_.ErrorDetails.Message) {
                                    Write-Log "        Details: $($_.ErrorDetails.Message)" -Color "Red"
                                }
                            }
                            
                            # Add small delay to avoid rate limiting
                            if (($copiedCount + $errorCount) % 10 -eq 0) {
                                Start-Sleep -Milliseconds 100
                            }
                        }
                    }
                }
            }
            
            Write-Log "    [SUCCESS] Copied data for $copiedCount work item(s), $errorCount errors" -Color "Green"
            return @{
                Success = $true
                CopiedCount = $copiedCount
                ErrorCount = $errorCount
                TotalFound = $ids.Count
            }
        }
        else {
            Write-Log "    No work items found with data in '$SourceFieldId'" -Color "Gray"
            return @{
                Success = $true
                CopiedCount = 0
                ErrorCount = 0
                TotalFound = 0
            }
        }
    }
    catch {
        Write-Log "    Failed to query/copy data: $($_.Exception.Message)" -Color "Red"
        return @{
            Success = $false
            CopiedCount = 0
            ErrorCount = 1
            TotalFound = 0
            Error = $_.Exception.Message
        }
    }
}

# ===== Main Script =====
Write-Log "========================================" -Color "Cyan"
Write-Log "Field Data Copy Script" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Collection: $CollectionUrl" -Color "White"
Write-Log "Project: $ProjectName" -Color "White"
Write-Log "Config File: $ConfigFilePath" -Color "White"
Write-Log "Update Batch Size: $BatchSize" -Color "White"
Write-Log "Log File: $LogFile" -Color "White"
Write-Log ""
Write-Log "PERFORMANCE OPTIMIZATIONS:" -Color "Yellow"
Write-Log "- WIQL query retrieves all work item IDs at once" -Color "Gray"
Write-Log "- Work item data retrieved in batches of 200" -Color "Gray"
Write-Log "- Updates processed in configurable batches (current: $BatchSize)" -Color "Gray"
Write-Log "- Rate limiting: 100ms delay every 10 updates" -Color "Gray"
Write-Log "- Progress reporting every 100 successful copies" -Color "Gray"
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

# Get work item types
Write-Log "Fetching work item types..." -Color "Yellow"
$workItemTypes = Get-WorkItemTypes -OrgUrl $CollectionUrl -ProjectName $ProjectName -Headers $auth -ApiVersion $ApiVer

if (-not $workItemTypes -or $workItemTypes.Count -eq 0) {
    Write-Log "No work item types found." -Color "Red"
    exit 1
}

Write-Log "Found $($workItemTypes.Count) work item type(s)." -Color "Green"
Write-Log ""

# Initialize summary tracking
$summary = @{
    TotalMappings = $config.fieldMappings.Count
    ProcessedMappings = 0
    SuccessfulCopies = 0
    FailedCopies = 0
    WorkItemTypesProcessed = @{}
}

# Process each field mapping
foreach ($mapping in $config.fieldMappings) {
    $sourceField = $mapping.sourceField
    $targetField = $mapping.targetField
    
    Write-Log "========================================" -Color "Cyan"
    Write-Log "Processing Field Mapping: $sourceField -> $targetField" -Color "Cyan"
    Write-Log "========================================" -Color "Cyan"
    
    $mappingProcessed = $false
    
    # Loop through each work item type
    foreach ($wit in $workItemTypes) {
        $witName = $wit.name
        
        # Get fields for this work item type
        $fields = Get-WorkItemTypeFields -OrgUrl $CollectionUrl -ProjectName $ProjectName -WitName $witName -Headers $auth -ApiVersion $ApiVer
        
        if (-not $fields) {
            continue
        }
        
        # Check if source field exists
        $sourceFieldObj = $fields | Where-Object { $_.referenceName -eq $sourceField }
        
        if (-not $sourceFieldObj) {
            # Skip work item types that don't have the source field (this is expected)
            continue
        }
        
        # Process work item type that has the source field
        Write-Log ""
        Write-Log "Processing Work Item Type: $witName" -Color "White"
        Write-Log "  [FOUND] Source Field: $sourceField (Name: $($sourceFieldObj.name))" -Color "Green"
        
        # Check if target field exists
        $targetFieldObj = $fields | Where-Object { $_.referenceName -eq $targetField }
        
        if ($targetFieldObj) {
            Write-Log "  [OK] Target Field: $targetField exists (Name: $($targetFieldObj.name))" -Color "Green"
            
            # Copy data
            $result = Copy-FieldData -OrgUrl $CollectionUrl -ProjectName $ProjectName `
                -SourceFieldId $sourceField -TargetFieldId $targetField `
                -Headers $auth -HeadersPatch $headersPatch -ApiVersion $ApiVer -UpdateBatchSize $BatchSize
            
            if ($result.Success) {
                $summary.SuccessfulCopies++
                $mappingProcessed = $true
                
                # Track work item type processing
                if (-not $summary.WorkItemTypesProcessed.ContainsKey($witName)) {
                    $summary.WorkItemTypesProcessed[$witName] = @()
                }
                $summary.WorkItemTypesProcessed[$witName] += "$sourceField -> $targetField"
            }
            else {
                $summary.FailedCopies++
                Write-Log "  [ERROR] Failed to copy data for this work item type" -Color "Red"
            }
        }
        else {
            # Target field does not exist
            Write-Log "  [ERROR] Target Field: $targetField NOT FOUND!" -Color "Red"
            Write-Log "  [ACTION] Create target field '$targetField' manually in work item type '$witName'" -Color "Yellow"
            $summary.FailedCopies++
        }
    }
    
    if (-not $mappingProcessed) {
        Write-Log "Source field '$sourceField' not found in any work item type" -Color "Yellow"
    }
    
    $summary.ProcessedMappings++
}

# Final Summary
Write-Log ""
Write-Log "========================================" -Color "Cyan"
Write-Log "FINAL SUMMARY" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"
Write-Log "Total Field Mappings: $($summary.TotalMappings)" -Color "White"
Write-Log "Processed Mappings: $($summary.ProcessedMappings)" -Color "White"
Write-Log "Successful Copies: $($summary.SuccessfulCopies)" -Color "Green"
Write-Log "Failed Copies: $($summary.FailedCopies)" -Color "Red"
Write-Log ""
Write-Log "Work Item Types Processed:" -Color "White"
foreach ($witName in $summary.WorkItemTypesProcessed.Keys) {
    Write-Log "  ${witName}:" -Color "White"
    foreach ($mapping in $summary.WorkItemTypesProcessed[$witName]) {
        Write-Log "    - $mapping" -Color "Gray"
    }
}
Write-Log ""
Write-Log "Log saved to: $LogFile" -Color "Cyan"
Write-Log "========================================" -Color "Cyan"