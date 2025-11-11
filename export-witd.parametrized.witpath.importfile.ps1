# Requires: witadmin.exe (Azure DevOps Server/Services tooling)
# Purpose: Parse a custom fields inventory (e.g., fields_dev.txt), find EBR.* controls of type String/Integer,
#          then export WITDs per Project/WIT. Supports dry-run, custom root output directory,
#          explicit path to witadmin.exe, and generates 0-import.txt with import commands for injected XMLs.
# example .\export-witd.parametrized.witpath.importfile.ps1 -FieldsFile "C:\temp\fields_dev.txt" -RootDir "C:\temp\WITD-Exports" -DryRun $true -WitadminPath "C:\Program Files\Azure DevOps Server 2022\Tools"

param(
    [Parameter(Mandatory=$false)] [string]$CollectionUrl,      # Required when -DryRun:$false
    [Parameter(Mandatory=$true)]  [string]$FieldsFile,         # path to source custom fields inventory file
    [Parameter(Mandatory=$true)]  [string]$RootDir,            # root location to write outputs
    [Parameter(Mandatory=$true)]  [bool]  $DryRun,             # true = print only; false = perform export
    [Parameter(Mandatory=$true)]  [string]$WitadminPath        # full path to witadmin.exe OR folder containing it
)

$ErrorActionPreference = 'Stop'
Write-Host ("DryRun: {0}"       -f ($DryRun.ToString().ToLower()))
Write-Host ("FieldsFile: {0}"   -f $FieldsFile)
Write-Host ("RootDir: {0}"      -f $RootDir)
Write-Host ("WitadminPath: {0}" -f $WitadminPath)
if (-not (Test-Path -LiteralPath $FieldsFile)) { throw "FieldsFile not found: $FieldsFile" }

# Resolve witadmin.exe
$witExe = $null
if (Test-Path -LiteralPath $WitadminPath -PathType Leaf) {
  $witExe = (Resolve-Path -LiteralPath $WitadminPath).Path
} elseif (Test-Path -LiteralPath $WitadminPath -PathType Container) {
  $candidate = Join-Path $WitadminPath 'witadmin.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $witExe = (Resolve-Path -LiteralPath $candidate).Path
  } else { throw "witadmin.exe not found in folder: $WitadminPath" }
} else { throw "WitadminPath does not exist: $WitadminPath" }
if ($DryRun) { Write-Host ("[DRY] Would use witadmin: {0}" -f $witExe) }

# Helper: sanitize filename components (remove spaces and Windows-invalid characters)
function Get-SafeName([string]$name) {
  $n = $name.Replace(' ', '')
  $n = $n -replace "[<>:""/\\|?*]", ''
  return $n
}

# Read the inventory and split into Field blocks
$text   = Get-Content -LiteralPath $FieldsFile -Raw
$blocks = [regex]::Split($text, "\r?\n\s*Field:\s*") | Where-Object { $_.Trim().Length -gt 0 }

ble mapping "Project|||WIT" => array of matched EBR.* refnames (String/Integer only)
$matchedMap = @{}
foreach ($b in $blocks) {
  $lines = $b -split "\r?\n"
  if ($lines.Count -eq 0) { continue }
  $refname = $lines[0].Trim()
  if (-not $refname.StartsWith('EBR.')) { continue }

  $typeMatch = :Match($b, "\n\s*Type:\s*([^\n]+)")
  if (-not $typeMatch.Success) { continue }
  $ftype = $typeMatch.Groups[1].Value.Trim().ToLowerInvariant()
  if (@('string','integer') -notcontains $ftype) { continue }

  # Extract Use: ... up to next Indexed: (if present)
  $useMatch = :Match($b, "\n\s*Use:\s*(.+?)(\n\s*Indexed:|$)", 'Singleline')
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
if (-not $DryRun -and :IsNullOrWhiteSpace($CollectionUrl)) {
  throw "-CollectionUrl is required when -DryRun is false."
}

# Build import commands in memory (so we can write them once at the end)
$importLines   = New-Object System.Collections.Generic.List[string]
$colForImport  = if (:IsNullOrWhiteSpace($CollectionUrl)) { '<COLLECTION_URL>' } else { $CollectionUrl }

# Iterate over pairs in sorted order
$keys = $matchedMap.Keys | Sort-Object
foreach ($key in $keys) {
  $parts   = $key.Split('|||')
  $project = $parts[0]
  $wit     = $parts[1]

  $pSafe = Get-SafeName $project
  $wSafe = Get-SafeName $wit

  $fileName   = "{0}-{1}.xml" -f $pSafe, $wSafe
  $backupPath = Join-Path $backupDir $fileName
  $finalPath  = Join-Path $RootDir  $fileName

  $controls = ($matchedMap[$key] | Sort-Object) -join ', '
  $comment  = "<!-- Matched EBR controls (String/Integer): $controls -->"

  if ($DryRun) {
    Write-Host "[DRY] Would export (no inject) -> $backupPath"
    Write-Host "[DRY] Would copy to -> $finalPath"
    Write-Host "[DRY] Would inject header: $comment"
  } else {
    # Phase A: clean export to backup (no injection)
    & $witExe exportwitd /collection:$CollectionUrl /p:"$project" /n:"$wit" > $backupPath
    Write-Host ("[Backup] Exported {0}/{1} -> {2}" -f $project, $wit, $backupPath)

    # Phase B: copy and inject
    Copy-Item -Path $backupPath -Destination $finalPath -Force
    $xml = Get-Content -Path $finalPath -Raw -ErrorAction Stop
    if ($xml -match "^\uFEFF?<\?xml[\s\S]*?\?>") {
      $xmlDecl = :Match($xml, "^\uFEFF?<\?xml[\s\S]*?\?>").Value
      $rest    = $xml.Substring($xmlDecl.Length)
      $newXml  = $xmlDecl + "`r`n" + $comment + "`r`n" + $rest
    } else {
      $newXml  = $comment + "`r`n" + $xml
    }
    Set-Content -Path $finalPath -Value $newXml -Encoding UTF8
    Write-Host ("[Final]  Injected -> {0}" -f $finalPath)
  }

  # Build the import command targeting the injected file in RootDir
  $cmd = '"{0}" importwitd /collection:{1} /p:"{2}" /f:"{3}"' -f $witExe, $colForImport, $project, $finalPath
  $importLines.Add($cmd) | Out-Null
}

# Emit 0-import.txt (commands to import injected XMLs)
if ($DryRun) {
  Write-Host "[DRY] 0-import.txt would contain the following commands (first 10 shown):"
  $importLines | Select-Object -First 10 | ForEach-Object { Write-Host $_ }
  Write-Host ("[DRY] Total commands: {0}" -f $importLines.Count)
} else {
  Set-Content -LiteralPath $importListPath -Value $importLines -Encoding UTF8
  Write-Host ("[Import List] Wrote {0} commands -> {1}" -f $importLines.Count, $importListPath)
