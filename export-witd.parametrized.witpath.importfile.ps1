# Requires: witadmin.exe (Azure DevOps Server/Services tooling) OR REST API with PAT
# Purpose: Parse a custom fields inventory (e.g., fields_dev.txt), find <prefix>.* controls of type String/Integer,
#          then export WITDs per Project/WIT. Supports dry-run, custom root output directory,
#          explicit path to witadmin.exe, and generates 0-import.txt with import commands for injected XMLs.
param(
    [Parameter(Mandatory=$false)] [string]$CollectionUrl,      # Required when -DryRun:$false
    [Parameter(Mandatory=$true)]  [string]$FieldsFile,         # path to source custom fields inventory file
    [Parameter(Mandatory=$true)]  [string]$RootDir,            # root location to write outputs
    [Parameter(Mandatory=$true)]  [bool]  $DryRun,             # true = print only; false = perform export
    [Parameter(Mandatory=$false)]  [string]$WitadminPath,       # full path to witadmin.exe OR folder containing it (optional if using PAT)
    [Parameter(Mandatory=$false)] [string]$FieldPrefix = 'Custom', # custom field refname prefix (w/ or w/o trailing dot)
    [Parameter(Mandatory=$false)] [string]$PAT                   # Personal Access Token for REST API authentication (alternative to witadmin)
)

$ErrorActionPreference = 'Stop'

# Normalize prefix to ensure it ends with a dot (e.g., 'EBR.')
if ([string]::IsNullOrWhiteSpace($FieldPrefix)) { throw "-FieldPrefix cannot be empty" }
$PrefixNorm  = if ($FieldPrefix.EndsWith('.')) { $FieldPrefix } else { "$FieldPrefix." }
$PrefixLabel = $PrefixNorm.TrimEnd('.')

Write-Host ("DryRun: {0}"        -f ($DryRun.ToString().ToLower()))
Write-Host ("FieldsFile: {0}"    -f $FieldsFile)
Write-Host ("RootDir: {0}"       -f $RootDir)
Write-Host ("WitadminPath: {0}"  -f $WitadminPath)
Write-Host ("FieldPrefix: {0}"   -f $PrefixNorm)

if (-not (Test-Path -LiteralPath $FieldsFile)) { throw "FieldsFile not found: $FieldsFile" }

# Validate authentication method
if ([string]::IsNullOrWhiteSpace($PAT) -and [string]::IsNullOrWhiteSpace($WitadminPath)) {
  throw "Either -PAT or -WitadminPath must be provided"
}

# Resolve witadmin.exe (if using witadmin method)
$witExe = $null
if (-not [string]::IsNullOrWhiteSpace($WitadminPath)) {
  if (Test-Path -LiteralPath $WitadminPath -PathType Leaf) {
    $witExe = (Resolve-Path -LiteralPath $WitadminPath).Path
  } elseif (Test-Path -LiteralPath $WitadminPath -PathType Container) {
    $candidate = Join-Path $WitadminPath 'witadmin.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $witExe = (Resolve-Path -LiteralPath $candidate).Path
    } else { throw "witadmin.exe not found in folder: $WitadminPath" }
  } else { throw "WitadminPath does not exist: $WitadminPath" }
  if ($DryRun) { Write-Host ("[DRY] Would use witadmin: {0}" -f $witExe) }
}

if (-not [string]::IsNullOrWhiteSpace($PAT)) {
  Write-Host "Using REST API with PAT authentication"
}

# Helper: sanitize filename components (remove spaces and Windows-invalid characters)
function Get-SafeName([string]$name) {
  $n = $name.Replace(' ', '')
  $n = $n -replace "[<>:""/\\|?*]", ''
  return $n
}

# Read the inventory and split into Field blocks
$text   = Get-Content -LiteralPath $FieldsFile -Raw
$blocks = [regex]::Split($text, "\r?\n\s*Field:\s*") | Where-Object { $_.Trim().Length -gt 0 }

# Hashtable mapping "Project|||WIT" => array of matched <prefix>.* refnames (String/Integer only)
$matchedMap = @{}
foreach ($b in $blocks) {
  $lines = $b -split "\r?\n"
  if ($lines.Count -eq 0) { continue }
  $refname = $lines[0].Trim()
  if (-not $refname.StartsWith($PrefixNorm, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

  $typeMatch = [regex]::Match($b, "\n\s*Type:\s*([^\n]+)")
  if (-not $typeMatch.Success) { continue }
  $ftype = $typeMatch.Groups[1].Value.Trim().ToLowerInvariant()
  if (@('string','integer') -notcontains $ftype) { continue }

  # Extract Use: ... up to next Indexed: (if present)
  $useMatch = [regex]::Match($b, "\n\s*Use:\s*(.+?)(\n\s*Indexed:|$)", [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $useMatch.Success) { continue }
  $use = $useMatch.Groups[1].Value

  # Parse occurrences like: Project (Type1, Type2), Project2 (TypeA)
  $pairRegex = New-Object System.Text.RegularExpressions.Regex "([A-Za-z0-9_-]+)\s*\(([^)]*)\)"
  $pairs = $pairRegex.Matches($use)
  foreach ($m in $pairs) {
    $proj = $m.Groups[1].Value.Trim()
    $types = $m.Groups[2].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($wit in $types) {
      if ($wit -match '^(?i)System Artifact$') { continue }
      $key = "$proj|||$wit"
      if (-not $matchedMap.ContainsKey($key)) { $matchedMap[$key] = @() }
      if ($matchedMap[$key] -notcontains $refname) { $matchedMap[$key] += $refname }
    }
  }
}

# Prepare paths
$timestamp      = Get-Date -Format 'yyyyMMdd'
$backupDir      = Join-Path $RootDir ("backup-{0}" -f $timestamp)
$importListPath = Join-Path $RootDir '0-import.txt'

if ($DryRun) {
  Write-Host ("[DRY] Would create: {0} and {1}" -f $RootDir, $backupDir)
  Write-Host ("[DRY] Would generate import list: {0}" -f $importListPath)
} else {
  New-Item -ItemType Directory -Path $RootDir -Force | Out-Null
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

# Ensure CollectionUrl provided when not dry run (needed for actual export)
if (-not $DryRun -and [string]::IsNullOrWhiteSpace($CollectionUrl)) {
  throw "-CollectionUrl is required when -DryRun is false."
}

# Build import commands in memory (so we can write them once at the end)
$importLines  = New-Object System.Collections.Generic.List[string]
$colForImport = if ([string]::IsNullOrWhiteSpace($CollectionUrl)) { '<COLLECTION_URL>' } else { $CollectionUrl }

# Iterate over pairs in sorted order
$keys = $matchedMap.Keys | Sort-Object
foreach ($key in $keys) {
  $parts   = $key -split '\|\|\|'
  $project = $parts[0]
  $wit     = $parts[1]
  
  # Get the list of custom fields for this project/WIT
  $customFields = $matchedMap[$key]

  $pSafe = Get-SafeName $project
  $wSafe = Get-SafeName $wit
  
  # Define export paths
  $exportPath = Join-Path $backupDir ("{0}-{1}.xml" -f $pSafe, $wSafe)
  $rootPath = Join-Path $RootDir ("{0}-{1}.xml" -f $pSafe, $wSafe)
  
  if ($DryRun) {
    Write-Host ("[DRY] Would export: Project='{0}' WIT='{1}' to '{2}'" -f $project, $wit, $exportPath)
  } else {
    Write-Host ("Exporting: Project='{0}' WIT='{1}'" -f $project, $wit)
    
    # Try REST API first if PAT is provided, otherwise use witadmin
    if (-not [string]::IsNullOrWhiteSpace($PAT)) {
      # Use REST API to export WITD
      $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
      $headers = @{ Authorization = "Basic $base64AuthInfo" }
      
      $witEncoded = [uri]::EscapeDataString($wit)
      $apiUrl = "$CollectionUrl/$project/_apis/wit/workitemtypes/$witEncoded" + "?api-version=7.1&`$expand=xmlForm"
      try {
        # Use Invoke-WebRequest to get raw content
        $webResponse = Invoke-WebRequest -Uri $apiUrl -Method Get -Headers $headers -ContentType "application/json"
        $jsonContent = $webResponse.Content
        
        # Extract xmlForm using regex (avoid ConvertFrom-Json issues in PS 5.1)
        if ($jsonContent -match '"xmlForm":"(.*?)"(?:,"|\})') {
          $xmlForm = $matches[1]
          # Unescape JSON string (replace \" with ", \\ with \, etc.)
          $xmlForm = $xmlForm -replace '\\n', "`n"
          $xmlForm = $xmlForm -replace '\\r', "`r"
          $xmlForm = $xmlForm -replace '\\t', "`t"
          $xmlForm = $xmlForm -replace '\\"', '"'
          $xmlForm = $xmlForm -replace '\\\\', '\'
          
          $xmlForm | Out-File -FilePath $exportPath -Encoding utf8
          Write-Host ("  Successfully exported via REST API")
        } else {
          Write-Warning ("No XML form found in response for {0}/{1}" -f $project, $wit)
          continue
        }
      } catch {
        Write-Warning ("REST API failed for {0}/{1}: {2}" -f $project, $wit, $_.Exception.Message)
        continue
      }
    } else {
      # Use witadmin with the exact URL as provided (no modifications)
      $args = @(
        'exportwitd',
        "/collection:$CollectionUrl",
        "/p:$project",
        "/n:$wit",
        "/f:$exportPath"
      )
      
      Write-Host ("  Executing: {0} {1}" -f $witExe, ($args -join ' '))
      try {
        $startTime = Get-Date
        & $witExe $args
        $duration = (Get-Date) - $startTime
        
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  SUCCESS - Export completed in {0:F1} seconds" -f $duration.TotalSeconds) -ForegroundColor Green
        } else {
          Write-Warning ("Failed to export {0}/{1} - Exit Code: {2}, Duration: {3:F1}s" -f $project, $wit, $LASTEXITCODE, $duration.TotalSeconds)
          Write-Host ("  URL used: {0}" -f $CollectionUrl) -ForegroundColor Yellow
          Write-Host ("  Suggestion: Try using -PAT parameter for REST API instead of witadmin") -ForegroundColor Yellow
          continue
        }
      } catch {
        Write-Warning ("Exception running witadmin for {0}/{1}: {2}" -f $project, $wit, $_.Exception.Message)
        continue
      }
    }
    
    # Now copy to root directory with injected XML comments
    if (Test-Path $exportPath) {
      $xmlContent = Get-Content -LiteralPath $exportPath -Raw
      
      # Build comment with list of custom fields
      $fieldList = $customFields -join ', '
      $comment = "<!-- Custom fields to update: $fieldList -->`r`n"
      
      # Inject comment at the beginning
      $modifiedXml = $comment + $xmlContent
      
      # Write to root directory
      $modifiedXml | Out-File -FilePath $rootPath -Encoding utf8
      Write-Host ("  Copied to root with comments: {0}" -f $rootPath)
    }
  }
  
  # Add import command for this WITD (pointing to root file with comments)
  $importCmd = "witadmin importwitd /collection:$colForImport /p:""$project"" /f:""$rootPath"""
  $importLines.Add($importCmd)
}

# Write import list file
if ($DryRun) {
  Write-Host ("[DRY] Would write {0} import commands to: {1}" -f $importLines.Count, $importListPath)
} else {
  $importLines | Out-File -LiteralPath $importListPath -Encoding utf8
  Write-Host ("Import list written to: {0} ({1} commands)" -f $importListPath, $importLines.Count)
}

Write-Host "Done."
