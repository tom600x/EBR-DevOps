# ===== Parameters =====
param(
    [Parameter(Mandatory=$true)]
    [string]$CollectionUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$ProjectName,
    
    [Parameter(Mandatory=$true)]
    [string]$PAT,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceFieldId,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetFieldId
)

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
        Write-Warning "Failed to get work item types for ${ProjectName}: $($_.Exception.Message)"
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
        Write-Warning "Failed to get fields for $WitName in ${ProjectName}: $($_.Exception.Message)"
        return @()
    }
}

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
                    # Skip folders we can't access
                }
            }
            elseif ($rootItem.isFolder -eq $false -and $rootItem.wiql) {
                [void]$allQueries.Add($rootItem)
            }
        }
        
        return $allQueries.ToArray()
    }
    catch {
        Write-Warning "Failed to get queries for ${ProjectName}: $($_.Exception.Message)"
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
        return $false # No changes needed
    }
    
    # Update the query
    $queryUrl = "$OrgUrl/$ProjectName/_apis/wit/queries/$QueryId`?api-version=$ApiVersion"
    $body = @{
        wiql = $updatedWiql
    } | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $queryUrl -Headers $Headers -Method Patch -Body $body -ContentType "application/json" | Out-Null
        return $true
    }
    catch {
        Write-Warning "Failed to update query $QueryId : $($_.Exception.Message)"
        return $false
    }
}

# ===== Main Script =====
Write-Host "========================================"  -ForegroundColor Cyan
Write-Host "Custom Field Migration Script" -ForegroundColor Cyan
Write-Host "========================================"  -ForegroundColor Cyan
Write-Host "Collection: $CollectionUrl" -ForegroundColor White
Write-Host "Project: $ProjectName" -ForegroundColor White
Write-Host "Source Field: $SourceFieldId" -ForegroundColor White
Write-Host "Target Field: $TargetFieldId" -ForegroundColor White
Write-Host ""

# Get work item types
Write-Host "Fetching work item types..." -ForegroundColor Yellow
$workItemTypes = Get-WorkItemTypes -OrgUrl $CollectionUrl -ProjectName $ProjectName -Headers $auth -ApiVersion $ApiVer

if (-not $workItemTypes -or $workItemTypes.Count -eq 0) {
    Write-Host "No work item types found." -ForegroundColor Red
    exit
}

Write-Host "Found $($workItemTypes.Count) work item type(s)." -ForegroundColor Green
Write-Host ""
$foundInTypes = @()
$missingTargetFieldTypes = @()

# Loop through each work item type
foreach ($wit in $workItemTypes) {
    $witName = $wit.name
    
    # Get fields
    $fields = Get-WorkItemTypeFields -OrgUrl $CollectionUrl -ProjectName $ProjectName -WitName $witName -Headers $auth -ApiVersion $ApiVer
    
    if (-not $fields) {
        continue
    }
    
    # Check if source field exists - only process if it exists
    $sourceField = $fields | Where-Object { $_.referenceName -eq $SourceFieldId }
    
    if ($sourceField) {
        Write-Host "Scanning: $witName" -ForegroundColor White
        $foundInTypes += $witName
        
        # Check if target field already exists
        $targetFieldExists = $fields | Where-Object { $_.referenceName -eq $TargetFieldId }
        
        if ($targetFieldExists) {
            Write-Host "  [FOUND] Source Field: $SourceFieldId (Name: $($sourceField.name))" -ForegroundColor Green
            Write-Host "  [OK] Target Field: $TargetFieldId exists (Name: $($targetFieldExists.name))" -ForegroundColor Green
            
            # Ask if user wants to copy data
            Write-Host ""
            Write-Host "  Do you want to copy data from '$SourceFieldId' to '$TargetFieldId'?" -ForegroundColor Cyan
            $response = Read-Host "  Type 'yes' to proceed, or press Enter to skip"
                
                if ($response -eq 'yes') {
                    Write-Host "    Copying data..." -ForegroundColor Yellow
                    
                    # Query work items with data in old field (filtered by current project)
                    $wiql = @{
                        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$ProjectName' AND [$SourceFieldId] <> ''"
                    } | ConvertTo-Json -Depth 3
                    
                    $wiqlUrl = "$CollectionUrl/$ProjectName/_apis/wit/wiql?api-version=$ApiVer"
                    try {
                        $wiqlRes = Invoke-RestMethod -Uri $wiqlUrl -Headers $auth -Method Post -Body $wiql -ContentType "application/json"
                        $ids = $wiqlRes.workItems.id
                        
                        if ($ids -and $ids.Count -gt 0) {
                            Write-Host "    Found $($ids.Count) work items with data" -ForegroundColor White
                            Write-Host ""
                            Write-Host "    [$($ids.Count) work items will be updated]" -ForegroundColor Yellow
                            Write-Host "    Press any key to continue copying data or Ctrl+C to cancel..." -ForegroundColor Yellow
                            $null = Read-Host
                            
                            $copiedCount = 0
                            
                            # Process in batches of 200
                            $batchSize = 200
                            for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {
                            $endIndex = [Math]::Min($i + $batchSize - 1, $ids.Count - 1)
                            $chunk = $ids[$i..$endIndex]
                            $idsParam = [String]::Join(",", $chunk)
                                
                            $getUrl = "$CollectionUrl/_apis/wit/workitems?ids=$idsParam&`$expand=Fields&api-version=$ApiVer"
                            $wis = Invoke-RestMethod -Uri $getUrl -Headers $auth -Method Get
                                
                            foreach ($wi in $wis.value) {
                                $val = $wi.fields."$SourceFieldId"
                                Write-Host "      WI $($wi.id): Old field value = '$val'" -ForegroundColor Gray
                                
                                if ($null -ne $val -and $val -ne '' -and $val -ne ' ') {
                                    $patchOps = @(
                                        @{
                                            op = "add"
                                            path = "/fields/$TargetFieldId"
                                            value = $val
                                        }
                                    )
                                    $patch = ConvertTo-Json @($patchOps) -Depth 10 -Compress
                                    
                                    $updateUrl = "$CollectionUrl/_apis/wit/workitems/$($wi.id)?api-version=$ApiVer"
                                    try {
                                        Invoke-RestMethod -Uri $updateUrl -Headers $headersPatch -Method Patch -Body $patch | Out-Null
                                        $copiedCount++
                                        Write-Host "      Copied WI $($wi.id)" -ForegroundColor Green
                                    }
                                    catch {
                                        Write-Host "      ERROR updating WI $($wi.id): $($_.Exception.Message)" -ForegroundColor Red
                                        if ($_.ErrorDetails.Message) {
                                            Write-Host "        Details: $($_.ErrorDetails.Message)" -ForegroundColor Red
                                        }
                                    }
                                }
                            }
                            }
                            
                            Write-Host "    [SUCCESS] Copied data for $copiedCount work item(s)" -ForegroundColor Green
                            
                            # Step 3: Scan and update work item queries
                            Write-Host ""
                            Write-Host "    Scanning work item queries for field references..." -ForegroundColor Yellow
                            $queries = Get-WorkItemQueries -OrgUrl $CollectionUrl -ProjectName $ProjectName -Headers $auth -ApiVersion $ApiVer
                            
                            if ($queries -and $queries.Count -gt 0) {
                            Write-Host "    Found $($queries.Count) queries to scan" -ForegroundColor White
                            $updatedQueries = @()
                            $queriesToUpdate = @()
                                
                            foreach ($query in $queries) {
                                if ($query.wiql -and $query.wiql -match "\[$SourceFieldId\]") {
                                    Write-Host "      Found field reference in: $($query.name)" -ForegroundColor Cyan
                                    $queriesToUpdate += $query
                                }
                            }
                                
                            # Pause before updating queries
                            if ($queriesToUpdate.Count -gt 0) {
                                Write-Host ""
                                Write-Host "    [$($queriesToUpdate.Count) queries will be updated]" -ForegroundColor Yellow
                                Write-Host "    Press any key to continue updating queries or Ctrl+C to cancel..." -ForegroundColor Yellow
                                $null = Read-Host
                                
                                foreach ($query in $queriesToUpdate) {
                                    Write-Host "      Updating: $($query.name)" -ForegroundColor Cyan
                                    
                                    $updated = Update-QueryWithNewField -OrgUrl $CollectionUrl -ProjectName $ProjectName `
                                        -QueryId $query.id -QueryWiql $query.wiql `
                                        -OldFieldId $SourceFieldId -TargetFieldId $TargetFieldId `
                                        -Headers $auth -ApiVersion $ApiVer
                                    
                                    if ($updated) {
                                        Write-Host "        [UPDATED] Query successfully updated" -ForegroundColor Green
                                        $updatedQueries += $query.name
                                    }
                                    else {
                                        Write-Host "        [FAILED] Could not update query" -ForegroundColor Red
                                    }
                                }
                                
                                if ($updatedQueries.Count -gt 0) {
                                    Write-Host ""
                                    Write-Host "    [SUCCESS] Updated $($updatedQueries.Count) queries:" -ForegroundColor Green
                                    foreach ($qName in $updatedQueries) {
                                        Write-Host "      - $qName" -ForegroundColor White
                                    }
                                }
                            }
                            else {
                                Write-Host "    No queries found using field '$SourceFieldId'" -ForegroundColor Gray
                            }
                            }
                            else {
                            Write-Host "    No queries found in project" -ForegroundColor Gray
                            }
                            
                            # Ask about hiding original field
                            Write-Host ""
                            Write-Host "    [MANUAL STEP] Hide the original field in the layout:" -ForegroundColor Yellow
                            Write-Host "      1. Go to Project Settings - Project configuration - Process" -ForegroundColor Gray
                            Write-Host "      2. Navigate to work item type: $witName" -ForegroundColor Gray
                            Write-Host "      3. Edit the form layout" -ForegroundColor Gray
                            Write-Host "      4. Hide or remove field: $SourceFieldId" -ForegroundColor Gray
                        }
                        else {
                            Write-Host "    No work items found with data in '$SourceFieldId'" -ForegroundColor Gray
                        }
                    }
                    catch {
                        Write-Warning "    Failed to query/copy data: $($_.Exception.Message)"
                    }
                }
            }
        }
        else {
            # Target field does not exist - provide user guidance
            Write-Host "  [FOUND] Source Field: $SourceFieldId (Name: $($sourceField.name))" -ForegroundColor Green
            Write-Host "  [ERROR] Target Field: $TargetFieldId NOT FOUND!" -ForegroundColor Red
            Write-Host ""
            Write-Host "  REQUIRED ACTION:" -ForegroundColor Yellow
            Write-Host "  The target field '$TargetFieldId' does not exist in work item type '$witName'." -ForegroundColor White
            Write-Host ""
            Write-Host "  Please choose one of the following options:" -ForegroundColor Cyan
            Write-Host "  1. CREATE the target field manually:" -ForegroundColor White
            Write-Host "     - Go to Project Settings > Process" -ForegroundColor Gray
            Write-Host "     - Select your process template" -ForegroundColor Gray
            Write-Host "     - Choose work item type: $witName" -ForegroundColor Gray
            Write-Host "     - Add new field with reference name: $TargetFieldId" -ForegroundColor Gray
            Write-Host "     - Then re-run this script" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  2. VERIFY the target field name:" -ForegroundColor White
            Write-Host "     - Check if the field reference name is correct" -ForegroundColor Gray
            Write-Host "     - Field names are case-sensitive" -ForegroundColor Gray
            Write-Host "     - Use the exact reference name (e.g., 'Custom.FieldName')" -ForegroundColor Gray
            Write-Host "     - Re-run script with correct field name if needed" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  Available fields in '$witName':" -ForegroundColor White
            $customFields = $fields | Where-Object { $_.referenceName -like "Custom.*" } | Sort-Object referenceName
            if ($customFields) {
                foreach ($field in $customFields) {
                    Write-Host "     - $($field.referenceName) (Name: $($field.name))" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "     - No custom fields found in this work item type" -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  Migration SKIPPED for work item type: $witName" -ForegroundColor Yellow
            Write-Host "  =====================================================" -ForegroundColor Yellow
            $missingTargetFieldTypes += $witName
        }
}

# Summary
Write-Host ""
Write-Host "========================================"  -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================"  -ForegroundColor Cyan
if ($foundInTypes.Count -gt 0) {
    Write-Host "Source field '$SourceFieldId' found in: $($foundInTypes -join ', ')" -ForegroundColor Green
}
else {
    Write-Host "Source field '$SourceFieldId' NOT found in any work item type" -ForegroundColor Yellow
}

if ($missingTargetFieldTypes.Count -gt 0) {
    Write-Host ""
    Write-Host "⚠️  WARNING: Target field '$TargetFieldId' NOT FOUND in:" -ForegroundColor Red
    foreach ($witType in $missingTargetFieldTypes) {
        Write-Host "   - $witType" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "ACTION REQUIRED:" -ForegroundColor Yellow
    Write-Host "1. Create the target field '$TargetFieldId' in the missing work item types" -ForegroundColor White
    Write-Host "2. Or verify the field reference name is correct (case-sensitive)" -ForegroundColor White
    Write-Host "3. Re-run the script after creating/correcting the target field" -ForegroundColor White
}

Write-Host "========================================"  -ForegroundColor Cyan


