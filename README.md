# Azure DevOps Custom Field Migration Script

Migrate custom fields in Azure DevOps by copying data from a source field to a target field and updating work item queries.

## Quick Start

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File ".\renamefields_with_queries.ps1" -CollectionUrl "https://dev.azure.com/yourorg" -ProjectName "YourProject" -PAT "your_pat_token" -SourceFieldId "Custom.SourceField" -TargetFieldId "Custom.TargetField"
```

## What It Does

1. **Finds** work item types that contain the source field
2. **Validates** that the target field exists (warns if missing)  
3. **Copies data** from source to target field for all work items
4. **Updates queries** that reference the old field
5. **Skips** work item types that don't have the source field (no messages shown)

## Requirements

- **PowerShell 5.1+**
- **Personal Access Token** with Work Items (Read & Write) and Work Item Query (Read & Write) permissions

### Get Your Personal Access Token
1. Go to Azure DevOps → **User Settings** → **Personal Access Tokens**
2. Create new token with **Work Items** and **Work Item Query** permissions

## Usage

```powershell
.\renamefields_with_queries.ps1 -CollectionUrl "https://dev.azure.com/myorg" -ProjectName "MyProject" -PAT "your_pat_here" -SourceFieldId "Custom.OldField" -TargetFieldId "Custom.NewField"
```

**If you get execution policy errors:**
```powershell
PowerShell -ExecutionPolicy Bypass -File ".\renamefields_with_queries.ps1" -CollectionUrl "https://dev.azure.com/myorg" -ProjectName "MyProject" -PAT "your_pat_here" -SourceFieldId "Custom.OldField" -TargetFieldId "Custom.NewField"
```

## What It Does

1. Copies data from source field to target field in work items
2. Updates all project queries to use the new field name
3. Processes items in batches of 200 for efficiency
4. Only processes work item types that have both fields

Field reference names are usually in format `Custom.FieldName`. Find them in:
- **Project Settings** → **Process** → **Work item type** → **Field details**

## Troubleshooting

**Execution Policy Error:**
```powershell
PowerShell -ExecutionPolicy Bypass -File ".\script.ps1" [parameters]
```

**Authentication Issues:** Verify your PAT has correct permissions and hasn't expired

**Field Not Found:** Check field reference names in Azure DevOps Process settings



### During Execution
1. **Monitor progress** and watch for errors
2. **Don't interrupt** the script during batch operations
3. **Take note** of the summary information provided

### After Migration
1. **Verify data migration** by spot-checking work items
2. **Test updated queries** to ensure they work correctly
3. **Update work item form layouts** to hide the old field
4. **Communicate changes** to your team

## Support

For issues with this script:
1. Check the troubleshooting section above
2. Verify your Azure DevOps permissions
3. Test with a small subset of data first
4. Check Azure DevOps service health if API calls are failing

---

**Note**: This script modifies work items and queries in your Azure DevOps project. Always test in a non-production environment first and ensure you have appropriate backups.