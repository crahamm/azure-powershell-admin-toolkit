# Azure PowerShell Admin Toolkit

Azure PowerShell Admin Toolkit is a collection of reusable PowerShell automation scripts and Azure administration utilities for common cloud operations. The project is intended for Azure administrators, cloud engineers, platform teams, and operations teams that need safe, repeatable scripts for inventory, reporting, governance, security, and cost-optimization workflows.

The toolkit favors read-only reporting by default, explicit parameters, structured output, and automation-friendly behavior so scripts can be used interactively, in scheduled jobs, or as building blocks for larger operational workflows.

## Goals

- Provide practical Azure administration scripts that are easy to inspect, run, and adapt.
- Use modern PowerShell patterns with clear parameters, comment-based help, and structured output.
- Avoid hardcoded tenant, subscription, resource group, or resource names.
- Support safe execution across different Azure tenants and subscriptions.
- Make generated data easy to consume from PowerShell pipelines, JSON tooling, CSV workflows, and reporting systems.

## Repository Structure

- `scripts/`: Reusable PowerShell scripts and Azure automation utilities.
- `AGENTS.md`: Project guidance for automation agents and contributors.
- `LICENSE`: MIT license.

## Prerequisites

Most scripts are designed for PowerShell 7+ and the Azure PowerShell `Az` modules.

Install PowerShell modules as needed:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
Install-Module Az.Resources -Scope CurrentUser
Install-Module Az.Compute -Scope CurrentUser
```

Authenticate before running scripts that call Azure:

```powershell
Connect-AzAccount
```

If a script accepts `-SubscriptionId`, prefer passing it explicitly when running against a specific subscription:

```powershell
./scripts/Get-AzResourceInventory.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000'
```

## Available Scripts

### `scripts/Get-AzResourceInventory.ps1`

Lists Azure resources in the current subscription, a specified subscription, or a specific resource group.

The default console output includes:

- `Name`: resource name.
- `Type`: friendly resource type name.
- `Region`: Azure region.
- `ResourceGroup`: resource group name.
- `Tags`: resource tags.
- `CreationDate`: best-effort creation date when Azure exposes it for the resource type.

Supported output formats:

- `Object`: returns a PowerShell object for pipeline use.
- `Json`: returns resource rows as JSON.
- `Csv`: returns resource rows as CSV.

Key parameters:

- `-SubscriptionId`: scans a specific Azure subscription. If omitted, the current Az context subscription is used.
- `-ResourceGroupName`: limits inventory collection to a single resource group.
- `-OutputFormat`: controls output format. Valid values are `Object`, `Json`, and `Csv`.
- `-OutputPath`: writes output to a file instead of the pipeline.

Examples:

```powershell
./scripts/Get-AzResourceInventory.ps1
```

Returns inventory rows for the current Azure context subscription.

```powershell
./scripts/Get-AzResourceInventory.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -OutputFormat Json `
    -OutputPath './inventory.json'
```

Scans a specific subscription and writes inventory rows to JSON.

```powershell
./scripts/Get-AzResourceInventory.ps1 `
    -ResourceGroupName 'rg-prod' `
    -OutputFormat Csv `
    -OutputPath './rg-prod-inventory.csv'
```

Scans one resource group and writes resource rows to CSV.

Required permissions:

- Reader access at the target subscription or resource group scope is typically sufficient.

Security note:

- Inventory output can include sensitive operational metadata such as resource names, resource group names, tags, and creation dates. Do not commit generated reports to the repository.

### `scripts/Find-UnusedDisks.ps1`

Finds unattached Azure managed disks that may be generating unnecessary costs.

The default console output includes:

- `DiskName`: managed disk name.
- `SizeGB`: provisioned disk size in GiB.
- `ResourceGroup`: resource group name.

Supported output formats:

- `Object`: returns PowerShell objects for pipeline use.
- `Json`: returns report rows as JSON.
- `Csv`: returns report rows as CSV.

Key parameters:

- `-SubscriptionId`: scans a specific Azure subscription. If omitted, the current Az context subscription is used.
- `-ResourceGroupName`: limits disk discovery to a single resource group.
- `-Delete`: deletes the unattached disks found by the scan.
- `-OutputFormat`: controls output format. Valid values are `Object`, `Json`, and `Csv`.
- `-OutputPath`: writes output to a file instead of the pipeline.

Examples:

```powershell
./scripts/Find-UnusedDisks.ps1
```

Reports unattached managed disks in the current Azure context subscription.

```powershell
./scripts/Find-UnusedDisks.ps1 -ResourceGroupName 'Lab-RG'
```

Reports unattached managed disks in one resource group.

```powershell
./scripts/Find-UnusedDisks.ps1 -Delete -WhatIf
```

Shows which unattached managed disks would be deleted without deleting them.

```powershell
./scripts/Find-UnusedDisks.ps1 `
    -OutputFormat Csv `
    -OutputPath './unused-disks.csv'
```

Writes the cleanup report to a CSV file.

Required permissions:

- Reader access at the target subscription or resource group scope is typically sufficient for reporting.
- Deleting disks requires delete permissions, such as Disk Delete or Contributor, at the target scope.

Safety note:

- The script is report-only by default. Use `-Delete -WhatIf` before deleting disks, and verify that reported disks are not needed for recovery, backup, forensic, or migration workflows.

## Usage Guidance

- Review each script's comment-based help before running it: `Get-Help ./scripts/<script-name>.ps1 -Full`.
- Run reporting scripts against a limited resource group first when validating behavior.
- Treat output files as operational data and store them according to your organization's data-handling requirements.
- Use `-Verbose` when troubleshooting scripts that support diagnostic output.
- For scripts that modify Azure resources, use `-WhatIf` first when supported.

## Validation

When changing or adding scripts, validate syntax before use:

```powershell
Get-ChildItem ./scripts/*.ps1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    $errors
}
```

If `PSScriptAnalyzer` is installed, run it before committing script changes:

```powershell
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Severity Warning,Error
```

## License

This project is licensed under the MIT License. See `LICENSE` for details.
