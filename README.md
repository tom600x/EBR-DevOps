# Azure DevOps Custom Field Migration Script

This PowerShell script helps migrate custom fields in Azure DevOps by copying data from a source field to a target field and updating work item queries that reference the old field.

## Quick Start

**If you encounter execution policy errors, use this command:**
```powershell
PowerShell.exe -ExecutionPolicy Bypass -File ".\renamefields_with_queries.ps1" -CollectionUrl "https://dev.azure.com/yourorg" -ProjectName "YourProject" -PAT "your_pat_token" -SourceFieldId "Custom.SourceField" -TargetFieldId "Custom.TargetField"
```

## Overview

The script performs the following operations:
1. **Validates** that both source and target fields exist in work item types
2. **Copies data** from the source field to the target field for all work items
3. **Updates work item queries** that reference the old field
4. **Provides guidance** for manually hiding the old field in layouts

## Prerequisites

### System Requirements
- **PowerShell 5.1** or higher
- **Network access** to your Azure DevOps organization
- **Internet connectivity** for API calls

### Azure DevOps Permissions
Your Personal Access Token (PAT) must have the following permissions:
- **Work Items**: Read & Write
- **Work Item Query**: Read & Write
- **Project and Team**: Read (for accessing project metadata)

### Create a Personal Access Token (PAT)
1. Sign in to your Azure DevOps organization
2. Go to **User Settings** > **Personal Access Tokens**
3. Click **+ New Token**
4. Set the following:
   - **Name**: Field Migration Script
   - **Expiration**: Choose appropriate timeframe
   - **Scopes**: Custom defined
   - Select: **Work Items (Read & Write)** and **Work Item Query (Read & Write)**
5. Click **Create** and copy the token immediately

## Usage

### Command Syntax
```powershell
.\renamefields_with_queries.ps1 -CollectionUrl "<organization_url>" -ProjectName "<project_name>" -PAT "<personal_access_token>" -SourceFieldId "<source_field_reference_name>" -TargetFieldId "<target_field_reference_name>"
```

### Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `CollectionUrl` | Your Azure DevOps organization URL | `https://dev.azure.com/myorg` |
| `ProjectName` | Name of the Azure DevOps project | `MyProject` |
| `PAT` | Personal Access Token with appropriate permissions | `abcd1234efgh5678ijkl9012mnop` |
| `SourceFieldId` | Reference name of the source field | `Custom.OldFieldName` |
| `TargetFieldId` | Reference name of the target field | `Custom.NewFieldName` |

### Example Usage

```powershell
# Basic example
.\renamefields_with_queries.ps1 `
    -CollectionUrl "https://dev.azure.com/contoso" `
    -ProjectName "WebApp" `
    -PAT "your_pat_token_here" `
    -SourceFieldId "Custom.Priority" `
    -TargetFieldId "Custom.BusinessPriority"

# Using variables for cleaner syntax
$CollectionUrl = "https://dev.azure.com/contoso"
$ProjectName = "WebApp"
$PAT = "your_pat_token_here"
$SourceField = "Custom.Priority"
$TargetField = "Custom.BusinessPriority"

.\renamefields_with_queries.ps1 -CollectionUrl $CollectionUrl -ProjectName $ProjectName -PAT $PAT -SourceFieldId $SourceField -TargetFieldId $TargetField
```

## How to Find Field Reference Names

### Method 1: Using Azure DevOps Web Interface
1. Go to **Project Settings** > **Process**
2. Select your process template
3. Choose a work item type (e.g., User Story)
4. Click on the field you want to migrate
5. The reference name is shown in the field details

### Method 2: Using REST API
```powershell
# Get all fields for a work item type
$headers = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT")))" }
$url = "https://dev.azure.com/yourorg/yourproject/_apis/wit/workitemtypes/User Story/fields?api-version=7.1"
Invoke-RestMethod -Uri $url -Headers $headers | Select-Object -ExpandProperty value | Select-Object name, referenceName
```

## Script Execution Flow

### Phase 1: Validation
- Fetches all work item types in the project
- Checks if source field exists in any work item type
- Verifies that target field exists
- Reports which work item types contain the source field

### Phase 2: Data Migration
- **User Confirmation**: Asks if you want to copy data from source to target field
- **Query Execution**: Finds all work items with data in the source field
- **Batch Processing**: Updates work items in batches of 200 for performance
- **Progress Reporting**: Shows progress for each work item updated

### Phase 3: Query Updates
- **Query Scanning**: Searches all work item queries for references to the source field
- **User Confirmation**: Shows list of queries that will be updated
- **Query Updates**: Replaces field references in WIQL queries
- **Results Summary**: Reports successful and failed query updates

### Phase 4: Manual Steps
- Provides instructions for hiding the old field in work item layouts

## Interactive Prompts

The script includes several confirmation prompts for safety:

1. **Data Copy Confirmation**:
   ```
   Do you want to copy data from 'Custom.OldField' to 'Custom.NewField'?
   Type 'yes' to proceed, or press Enter to skip
   ```

2. **Batch Processing Confirmation**:
   ```
   [X work items will be updated]
   Press any key to continue copying data or Ctrl+C to cancel...
   ```

3. **Query Update Confirmation**:
   ```
   [X queries will be updated]
   Press any key to continue updating queries or Ctrl+C to cancel...
   ```

## PowerShell Execution Policy

### Understanding Execution Policy Errors

You may encounter this error when running the script:
```
File cannot be loaded. The file is not digitally signed. You cannot run this script on the current system.
```

This is a Windows security feature that prevents unsigned PowerShell scripts from running.

### Check Current Execution Policy
```powershell
Get-ExecutionPolicy
```

Common policies:
- `Restricted` - No scripts allowed (Windows default)
- `AllSigned` - Only signed scripts allowed
- `RemoteSigned` - Local scripts allowed, remote scripts must be signed
- `Unrestricted` - All scripts allowed

### Solutions (Choose One)

#### Option 1: Bypass Policy for Single Execution (Recommended)
```powershell
PowerShell.exe -ExecutionPolicy Bypass -File ".\renamefields_with_queries.ps1" -CollectionUrl "https://dev.azure.com/yourorg" -ProjectName "YourProject" -PAT "your_pat_token" -SourceFieldId "Custom.SourceField" -TargetFieldId "Custom.TargetField"
```

#### Option 2: Temporarily Change Policy (Current Session Only)
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\renamefields_with_queries.ps1 -CollectionUrl "..." -ProjectName "..." -PAT "..." -SourceFieldId "..." -TargetFieldId "..."
```

#### Option 3: Change Policy Permanently (Requires Administrator)
```powershell
# Run PowerShell as Administrator
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

#### Option 4: Unblock the Script File
```powershell
Unblock-File -Path ".\renamefields_with_queries.ps1"
```

### Recommended Approach
Use **Option 1** (Bypass) as it's the safest method that doesn't permanently change your system's security settings.

## Security Considerations

### PAT Security
- **Never commit** PAT tokens to source control
- Use **environment variables** or **secure credential storage**
- Consider using **shorter expiration times** for PAT tokens

```powershell
# Using environment variable for PAT
$env:AZURE_DEVOPS_PAT = "your_pat_here"
.\renamefields_with_queries.ps1 -CollectionUrl "..." -ProjectName "..." -PAT $env:AZURE_DEVOPS_PAT -SourceFieldId "..." -TargetFieldId "..."
```

## Troubleshooting

### Common Issues

#### 1. "Access Denied" or "401 Unauthorized"
- **Cause**: Invalid PAT or insufficient permissions
- **Solution**: Verify PAT is correct and has Work Items (Read & Write) permissions

#### 2. "Target Field NOT FOUND" warnings
- **Cause**: Target field doesn't exist in one or more work item types
- **Solution**: 
  - Create the target field in Project Settings > Process
  - Or verify the field reference name is correct (case-sensitive)
  - Re-run the script after fixing the issue

#### 3. "Field not found" errors  
- **Cause**: Incorrect field reference name
- **Solution**: Use the exact reference name (case-sensitive), not the display name

#### 3. "TLS/SSL" connection errors
- **Cause**: Older PowerShell versions with outdated security protocols
- **Solution**: The script sets TLS 1.2, but you may need to update PowerShell

#### 4. "Too many requests" or rate limiting
- **Cause**: Azure DevOps API rate limits
- **Solution**: The script includes batching, but for very large datasets, you may need to run during off-peak hours

### Logging and Debugging

To capture full output for troubleshooting:

```powershell
.\renamefields_with_queries.ps1 -CollectionUrl "..." -ProjectName "..." -PAT "..." -SourceFieldId "..." -TargetFieldId "..." | Tee-Object -FilePath "migration-log.txt"
```

## Best Practices

### Before Running
1. **Test in a non-production environment** first
2. **Backup your project** if possible
3. **Verify field reference names** are correct
4. **Ensure target field exists** in all relevant work item types
5. **Coordinate with team** to avoid conflicts during migration

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