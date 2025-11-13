# Bulk Field Operations for Azure DevOps

This repository contains PowerShell scripts for performing bulk field operations in Azure DevOps projects, including copying field data and updating queries with new field references.

## Scripts Overview

### 1. `copy-fields-bulk.ps1`
Copies data from source fields to target fields across all work item types in a project.

### 2. `update-queries-bulk.ps1` 
Updates WIQL queries to replace source field references with target field references.

### 3. `field-mappings.json`
Configuration file containing the field mappings to process.

## Features

- **Batch Processing**: Runs completely automated without user prompts
- **Comprehensive Logging**: All operations logged to timestamped files
- **Error Resilience**: Continues processing other mappings if some fail
- **Independent Scripts**: Can run field copying and query updating separately
- **Copy Operation**: Data is copied (not moved) from source to target fields
- **Flexible Validation**: Handles missing source/target fields gracefully

## Prerequisites

- PowerShell 5.1 or higher
- Azure DevOps Personal Access Token (PAT) with appropriate permissions:
  - Work Items: Read & Write
  - Queries: Read & Write
- Network access to Azure DevOps

## Configuration

### Field Mappings Configuration

Edit `field-mappings.json` to define your source and target field mappings:

```json
{
  "fieldMappings": [
    {
      "sourceField": "Custom.OldField1",
      "targetField": "Custom.NewField1"
    },
    {
      "sourceField": "Custom.OldField2", 
      "targetField": "Custom.NewField2"
    },
    {
      "sourceField": "System.Description",
      "targetField": "Custom.LegacyDescription"
    }
  ]
}
```

**Field Reference Format**: Use the reference name (not display name) of fields:
- System fields: `System.Title`, `System.Description`, `System.State`
- Custom fields: `Custom.FieldName` or your organization's custom prefix

## Usage

### Step 1: Copy Field Data

```powershell
.\copy-fields-bulk.ps1 -CollectionUrl "https://dev.azure.com/yourorg" -ProjectName "YourProject" -PAT "yourpat" -ConfigFilePath ".\field-mappings.json"
```

**Parameters:**
- `CollectionUrl`: Your Azure DevOps organization URL
- `ProjectName`: Target project name
- `PAT`: Personal Access Token
- `ConfigFilePath`: Path to the JSON configuration file

### Step 2: Update Queries (Optional - Independent)

```powershell
.\update-queries-bulk.ps1 -CollectionUrl "https://dev.azure.com/yourorg" -ProjectName "YourProject" -PAT "yourpat" -ConfigFilePath ".\field-mappings.json"
```

**Note**: This script can be run independently at any time to update query field references.

## Script Behavior

### Copy Fields Script (`copy-fields-bulk.ps1`)

**Processing Logic:**
1. Loads field mappings from JSON configuration
2. Retrieves all work item types in the project
3. For each field mapping:
   - Scans each work item type for source field existence
   - If source field exists but target field doesn't: **ERRORS** and logs the issue
   - If both fields exist: Copies data from source to target field
   - If source field doesn't exist: **SKIPS** silently (expected behavior)

**Data Copying:**
- Queries work items with non-empty source field values
- Processes work items in batches of 200
- Copies data without modifying source field
- Logs success/failure for each work item

### Query Update Script (`update-queries-bulk.ps1`)

**Processing Logic:**
1. Loads field mappings from JSON configuration
2. Retrieves all queries from the project (including nested folders)
3. For each field mapping:
   - Scans query WIQL for source field references
   - Updates field references from source to target
   - Logs update success/failure

**Query Scanning:**
- Searches for field references in format `[FieldName]`
- Updates WIQL queries with new field references
- Handles nested folder structures
- Preserves query structure and formatting

## Output and Logging

### Log Files
Both scripts generate timestamped log files:
- `field-copy-log-yyyyMMdd-HHmmss.txt` (from copy-fields-bulk.ps1)
- `query-update-log-yyyyMMdd-HHmmss.txt` (from update-queries-bulk.ps1)

### Console Output
Real-time progress with color-coded messages:
- **Green**: Success operations
- **Red**: Errors and failures  
- **Yellow**: Warnings and processing steps
- **Cyan**: Headers and section dividers
- **White**: General information
- **Gray**: Skipped or neutral information

### Summary Reports
Each script provides a comprehensive summary including:
- Total mappings processed
- Success/failure counts
- Detailed breakdown by field mapping
- Work item types affected
- Queries updated

## Error Handling

### Common Scenarios

**Target Field Missing:**
- **Behavior**: Script logs error and continues with other mappings
- **Resolution**: Create the target field manually in the work item type
- **Log Message**: `[ERROR] Target Field: FieldName NOT FOUND!`

**Source Field Missing:**
- **Behavior**: Script silently skips (expected behavior)
- **Log Message**: No error logged (this is normal)

**Permission Issues:**
- **Behavior**: Script logs error and continues
- **Resolution**: Verify PAT permissions for work items and queries

**API Rate Limits:**
- **Behavior**: Script may fail on individual operations
- **Resolution**: Re-run the script (it will skip already processed items)

## Best Practices

### Before Running Scripts

1. **Backup**: Export work item type definitions and queries
2. **Test**: Run on a test project first
3. **Verify Fields**: Ensure target fields exist in all required work item types
4. **PAT Permissions**: Verify token has sufficient permissions

### Field Creation

Target fields must exist before running the copy script:
1. Navigate to Project Settings → Process
2. Select the appropriate work item type
3. Add the target field with correct data type
4. Ensure field is available in all work item types that use the source field

### Performance Considerations

- **Large Projects**: Scripts process in batches for better performance
- **Network**: Ensure stable connection to Azure DevOps
- **Rate Limits**: Scripts respect Azure DevOps API rate limits

## Troubleshooting

### Script Execution Issues

```powershell
# Enable detailed PowerShell execution
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted

# Run with verbose output
.\copy-fields-bulk.ps1 -Verbose
```

### Authentication Issues

```powershell
# Test PAT connectivity
$headers = @{Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT")))" }
Invoke-RestMethod -Uri "https://dev.azure.com/yourorg/_apis/projects" -Headers $headers
```

### Field Reference Issues

**Finding Field Reference Names:**
1. Open any work item in Azure DevOps
2. Export to Excel or use REST API to see field reference names
3. Use format: `Custom.FieldName` or `System.FieldName`

## Security Notes

- **PAT Storage**: Do not store PATs in scripts or source control
- **Permissions**: Use principle of least privilege for PAT permissions
- **Logging**: Log files may contain work item data - handle appropriately

## Support

For issues or questions:
1. Review log files for detailed error information
2. Check Azure DevOps permissions and field configurations
3. Verify JSON configuration syntax and field reference names
4. Test with a small subset of field mappings first

## Version History

- **v1.0**: Initial release with bulk field copying and query updating capabilities