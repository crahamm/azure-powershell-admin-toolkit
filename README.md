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

Builds a structured inventory report for Azure resources in the current subscription, a specified subscription, or a specific resource group.

The script returns a report containing:

- `Metadata`: generation time, tenant ID, subscription ID, subscription name, scan scope, resource group, and resource count.
- `Summary`: counts grouped by resource group, resource type, and Azure location.
- `Resources`: normalized resource records with common fields such as name, resource group, type, location, subscription ID, resource ID, kind, SKU, and tags.

Supported output formats:

- `Object`: returns a PowerShell object for pipeline use.
- `Json`: returns the full report as JSON.
- `Csv`: returns resource rows as CSV. Complex fields such as tags and expanded properties are serialized into compact JSON strings.

Key parameters:

- `-SubscriptionId`: scans a specific Azure subscription. If omitted, the current Az context subscription is used.
- `-ResourceGroupName`: limits inventory collection to a single resource group.
- `-OutputFormat`: controls output format. Valid values are `Object`, `Json`, and `Csv`.
- `-OutputPath`: writes output to a file instead of the pipeline.
- `-IncludeProperties`: includes expanded resource properties. This can significantly increase report size and may expose additional operational metadata.

Examples:

```powershell
./scripts/Get-AzResourceInventory.ps1
```

Returns an inventory report for the current Azure context subscription.

```powershell
./scripts/Get-AzResourceInventory.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -OutputFormat Json `
    -OutputPath './inventory.json'
```

Scans a specific subscription and writes the full report to JSON.

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

- Inventory output can include sensitive operational metadata such as resource names, tags, locations, SKUs, and expanded properties. Do not commit generated reports to the repository.

## Usage Guidance

- Review each script's comment-based help before running it: `Get-Help ./scripts/<script-name>.ps1 -Full`.
- Run reporting scripts against a limited resource group first when validating behavior.
- Treat output files as operational data and store them according to your organization's data-handling requirements.
- Use `-Verbose` when troubleshooting scripts that support diagnostic output.
- For scripts that modify Azure resources, use `-WhatIf` first when supported.

## Validation

When changing or adding scripts, validate syntax before use:

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    './scripts/Get-AzResourceInventory.ps1',
    [ref]$tokens,
    [ref]$errors
) | Out-Null
$errors
```

If `PSScriptAnalyzer` is installed, run it before committing script changes:

```powershell
Invoke-ScriptAnalyzer -Path ./scripts/Get-AzResourceInventory.ps1 -Severity Warning,Error
```

## License

This project is licensed under the MIT License. See `LICENSE` for details.
