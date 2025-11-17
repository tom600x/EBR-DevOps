# Generate witadmin exportwitd batch file from fields inventory
# Simplified version - reads fields file, filters by prefix and type, creates bat file
param(
    [Parameter(Mandatory=$true)]  [string]$FieldsFile,
    [Parameter(Mandatory=$true)]  [string]$OutputBatchFile,
    [Parameter(Mandatory=$false)] [string]$FieldPrefix = 'EBR',
    [Parameter(Mandatory=$false)] [string]$CollectionUrl = ''
)

if (-not (Test-Path $FieldsFile)) { 
    Write-Error "Fields file not found: $FieldsFile"
    exit 1
}

# Normalize prefix to ensure it ends with a dot
$PrefixNorm = if ($FieldPrefix.EndsWith('.')) { $FieldPrefix } else { "$FieldPrefix." }

Write-Host "Reading fields from: $FieldsFile"
Write-Host "Filtering by prefix: $PrefixNorm"
Write-Host "Limiting to: String and Integer types only"

# Read file and split into Field blocks
$text = Get-Content $FieldsFile -Raw
$blocks = [regex]::Split($text, "\r?\n\s*Field:\s*") | Where-Object { $_.Trim().Length -gt 0 }

$projectWitPairs = @{}

foreach ($block in $blocks) {
    $lines = $block -split "\r?\n"
    if ($lines.Count -eq 0) { continue }
    
    # First line is the field reference name
    $refname = $lines[0].Trim()
    
    # Check if field starts with the specified prefix
    if (-not $refname.StartsWith($PrefixNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    
    # Extract Type
    $typeMatch = [regex]::Match($block, "\n\s*Type:\s*([^\n]+)")
    if (-not $typeMatch.Success) { continue }
    
    $fieldType = $typeMatch.Groups[1].Value.Trim().ToLowerInvariant()
    
    # Filter: only String or Integer types
    if (@('string', 'integer') -notcontains $fieldType) {
        continue
    }
    
    # Extract Use: section
    $useMatch = [regex]::Match($block, "\n\s*Use:\s*(.+?)(\n\s*Indexed:|$)", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $useMatch.Success) { continue }
    
    $useText = $useMatch.Groups[1].Value
    
    # Extract all "Project (WIT)" patterns
    $patterns = [regex]::Matches($useText, '([A-Za-z0-9_-]+)\s*\(([^)]+)\)')
    
    foreach ($match in $patterns) {
        $project = $match.Groups[1].Value.Trim()
        $wits = $match.Groups[2].Value.Split(',') | ForEach-Object { $_.Trim() }
        
        foreach ($wit in $wits) {
            if ($wit) {
                $key = "$project|||$wit"
                $projectWitPairs[$key] = $true
            }
        }
    }
}

Write-Host "Found $($projectWitPairs.Count) unique Project/WIT combinations"

# Generate batch file
$batContent = @()
$batContent += "@echo off"
$batContent += "REM Auto-generated witadmin exportwitd commands"
$batContent += "REM Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$batContent += "REM Source: $FieldsFile"
$batContent += "REM Field Prefix: $PrefixNorm (String/Integer types only)"
$batContent += ""
$batContent += "REM EDIT THESE VARIABLES:"

if ([string]::IsNullOrWhiteSpace($CollectionUrl)) {
    $batContent += 'set COLLECTION_URL=https://your-server/DefaultCollection'
} else {
    $batContent += "set COLLECTION_URL=$CollectionUrl"
}

$batContent += 'set WITADMIN_PATH="C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\witadmin.exe"'
$batContent += 'set OUTPUT_DIR=.'
$batContent += ""
$batContent += "echo Starting WITD exports..."
$batContent += "echo."
$batContent += ""

$counter = 0
foreach ($key in ($projectWitPairs.Keys | Sort-Object)) {
    $parts = $key -split '\|\|\|'
    $project = $parts[0]
    $wit = $parts[1]
    
    $counter++
    $safeProject = $project -replace '[^a-zA-Z0-9_-]', ''
    $safeWit = $wit -replace '[^a-zA-Z0-9_-]', ''
    
    $batContent += "REM Export #$counter"
    $batContent += "echo Exporting: $project / $wit"
    $batContent += "%WITADMIN_PATH% exportwitd /collection:%COLLECTION_URL% /p:`"$project`" /n:`"$wit`" /f:`"%OUTPUT_DIR%\$safeProject-$safeWit.xml`""
    $batContent += "if errorlevel 1 echo [ERROR] Failed to export $project/$wit"
    $batContent += "echo."
    $batContent += ""
}

$batContent += "echo."
$batContent += "echo Export process completed!"
$batContent += "echo Total: $counter exports"
$batContent += "pause"

# Write batch file
$batContent | Out-File -FilePath $OutputBatchFile -Encoding ascii

Write-Host ""
Write-Host "Batch file created: $OutputBatchFile" -ForegroundColor Green
Write-Host "Total export commands: $counter" -ForegroundColor Green
Write-Host "Fields filtered by prefix: $PrefixNorm (String/Integer only)" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Edit $OutputBatchFile and set COLLECTION_URL, WITADMIN_PATH, and OUTPUT_DIR" -ForegroundColor Yellow
Write-Host "2. Run the batch file to execute exports" -ForegroundColor Yellow
