# Azure DevOps WITD Export/Import Automation Script

## Overview
This PowerShell script automates the process of exporting Work Item Type Definitions (WITDs) from Azure DevOps Server/Services, focusing on work item types that use custom controls with refnames starting with EBR and of type String or Integer. It supports:

- Backup-first export (clean XMLs)
- Injected copy (adds a comment listing matched custom controls)
- Dry-run mode (prints planned actions, no files written)
- Custom output location
- Explicit witadmin.exe path
- Automatic generation of an import command list (0-import.txt)

## What the Script Does

1. **Parses a custom fields inventory file** (e.g., fields_dev.txt) to find all EBR.* fields of type String/Integer.
2. **Builds a matrix** of all Project/Work Item Type pairs that use these controls (from the Use: matrix in each field block).
3. **Exports each WITD**: 
   - Phase A: Clean export to a timestamped backup folder (no changes).
   - Phase B: Copies the backup to the root output folder and injects an XML comment at the top listing all matched EBR controls for that Project/WIT.
4. **Generates 0-import.txt**: A text file containing one witadmin importwitd command per Project/WIT, ready to re-import the injected XMLs.
5. **Supports dry-run**: When enabled, prints all planned actions and the import command list, but does not write files or call witadmin.

## Script Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| -FieldsFile | Yes | Path to the custom fields inventory file (e.g., fields_dev.txt). |
| -RootDir | Yes | Root folder for all outputs (backups, injected XMLs, import list). |
| -DryRun | Yes | Boolean flag ($true/$false). If true, script prints actions but does not write files. |
| -WitadminPath | Yes | Full path to witadmin.exe or folder containing it. |
| -CollectionUrl | No* | Azure DevOps collection URL (required for real export, optional for dry-run). |

*\* -CollectionUrl is required when -DryRun is $false.*

## Workflow

### 1. Parse Field Inventory
- Reads the file specified by -FieldsFile.
- Finds all Field: EBR.* blocks where Type: is String or Integer.
- For each block, parses the Use: matrix to determine which projects and work item types reference the field.

### 2. Build Export Matrix
- For each unique Project/WIT pair, aggregates all matched EBR controls (String/Integer only).
- Sanitizes output filenames by removing spaces and invalid Windows filename characters (< > : " / \ | ? *).

### 3. Export WITDs
- **Backup**: Exports each WITD to RootDir\backup-YYYYMMDD\[Project]-[WIT].xml (clean, no changes).
- **Injected Copy**: Copies the backup to RootDir\[Project]-[WIT].xml and injects an XML comment at the top:
```xml
<!-- Matched EBR controls (String/Integer): EBR.AccessReviewComplete, EBR.BusinessAnalyst, ... -->
```

### 4. Generate Import Command List
- For each Project/WIT, creates a line in RootDir\0-import.txt:
```powershell
"C:\path\to\witadmin.exe" importwitd /collection:https://dev.azure.com/yourorg /p:"ProjectName" /f:"C:\path\to\RootDir\ProjectName-WIT.xml"
```
- If -CollectionUrl is not provided (dry-run), uses <COLLECTION_URL> as a placeholder.

### 5. Dry-Run Mode
- If -DryRun:$true, prints all planned actions and the first 10 import commands, but does not write files or call witadmin.

## Usage Examples

### Dry-Run (Preview Only)
```powershell
.\export-witd.parametrized.witpath.importfile.ps1 `
-FieldsFile "C:\temp\fields_dev.txt" `
-RootDir "C:\temp\WITD-Exports" `
-DryRun $true `
-WitadminPath "C:\Program Files\Azure DevOps Server 2022\Tools"
```

### Real Export/Import
```powershell
.\export-witd.parametrized.witpath.importfile.ps1 `
-CollectionUrl "http://tfs-server:8080/tfs/DefaultCollection" `
-FieldsFile "C:\temp\fields_dev.txt" `
-RootDir "C:\temp\WITD-Exports" `
-DryRun $false `
-WitadminPath "C:\Program Files\Azure DevOps Server 2022\Tools\witadmin.exe"
```

## Output Structure

- **Backups**: RootDir\backup-YYYYMMDD\[Project]-[WIT].xml (clean, no injection)
- **Injected XMLs**: RootDir\[Project]-[WIT].xml (with top-of-file comment)
- **Import List**: RootDir\0-import.txt (one line per Project/WIT, ready for batch import)
- **Console Output**: Progress and summary of actions (or dry-run preview)

## Notes & Best Practices

- **Sanitization**: Output filenames are sanitized for Windows compatibility; /p: and /n: parameters remain quoted for witadmin.
- **De-duplication**: Each Project/WIT pair is exported/imported only once, even if multiple EBR controls match.
- **Field Filtering**: Only EBR controls of type String/Integer are considered.
- **Import List**: Review 0-import.txt before running batch imports; fill in <COLLECTION_URL> if needed.
- **Error Handling**: If a Project/WIT does not exist in the target collection, witadmin will error for that pair and continue.

## Troubleshooting

- **witadmin.exe not found**: Ensure -WitadminPath points to the correct executable or folder.
- **Collection URL required**: For real exports/imports, always provide -CollectionUrl.
- **Field inventory format**: The script expects a file structured like fields_dev.txt (with Field:, Type:, Use: blocks).

## Customization

- You can further extend the script to filter by project, add logging, or integrate with pipeline automation.
- For large inventories, consider running in dry-run mode first to preview actions and validate the export matrix.

## Example: Import Command

A typical line in 0-import.txt:
```powershell
"C:\\Program Files\\Azure DevOps Server 2022\\Tools\\witadmin.exe" importwitd /collection:https://dev.azure.com/yourorg /p:"SWIF" /f:"C:\\temp\\WITD-Exports\\SWIF-UserStory.xml"
```

## Summary

This script provides a robust, repeatable way to export, audit, and re-import WITDs for all projects/work item types using EBR custom controls (String/Integer), with full traceability and safety via backup and dry-run modes.