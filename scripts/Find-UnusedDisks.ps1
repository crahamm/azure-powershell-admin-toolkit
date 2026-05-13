#!/usr/bin/env pwsh
<#
.SYNOPSIS
Finds unattached Azure managed disks that may be generating unnecessary costs.

.DESCRIPTION
Queries managed disks in the current Azure subscription, a specified subscription, or a specific resource group and reports disks that are not attached to any VM.

By default, this script is report-only. Use -Delete to remove the reported disks. The script supports -WhatIf and -Confirm for deletion previews and approvals.

Requires an authenticated Azure PowerShell session and the Az.Accounts and Az.Compute modules.

The caller needs permission to read managed disks at the selected subscription or resource group scope, such as the Reader role. Removing disks requires permissions such as Disk Delete or Contributor on the target scope.

.PARAMETER SubscriptionId
The Azure subscription ID to scan. If omitted, the current Az context subscription is used.

.PARAMETER ResourceGroupName
The resource group to scan. If omitted, all managed disks in the selected subscription are scanned.

.PARAMETER Delete
Deletes the unattached disks found by the scan. Use -WhatIf to preview deletion without removing disks.

.PARAMETER OutputFormat
The output format. Object returns PowerShell objects, Json returns JSON rows, and Csv returns rows as CSV.

.PARAMETER OutputPath
Writes report rows to a file instead of the pipeline. Object and Json write JSON. Csv writes CSV.

.EXAMPLE
./Find-UnusedDisks.ps1

Reports unattached managed disks in the current Azure context subscription.

.EXAMPLE
./Find-UnusedDisks.ps1 -ResourceGroupName 'Lab-RG'

Reports unattached managed disks in one resource group.

.EXAMPLE
./Find-UnusedDisks.ps1 -Delete -WhatIf

Shows which unattached managed disks would be deleted without deleting them.

.EXAMPLE
./Find-UnusedDisks.ps1 -OutputFormat Csv -OutputPath './unused-disks.csv'

Writes the cleanup report to a CSV file.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [switch]$Delete,

    [Parameter()]
    [ValidateSet('Object', 'Json', 'Csv')]
    [string]$OutputFormat = 'Object',

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AzModule {
    $requiredModules = @('Az.Accounts', 'Az.Compute')

    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "The '$moduleName' module is required. Install it with: Install-Module $moduleName -Scope CurrentUser"
        }
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    $property.Value
}

function Test-UnattachedDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk
    )

    $managedBy = Get-ObjectPropertyValue -InputObject $Disk -Name 'ManagedBy'
    $managedByExtended = Get-ObjectPropertyValue -InputObject $Disk -Name 'ManagedByExtended'

    [string]::IsNullOrWhiteSpace($managedBy) -and ($null -eq $managedByExtended -or $managedByExtended.Count -eq 0)
}

function ConvertTo-UnusedDiskReportRow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk
    )

    [pscustomobject][ordered]@{
        DiskName      = $Disk.Name
        SizeGB        = $Disk.DiskSizeGB
        ResourceGroup = $Disk.ResourceGroupName
    }
}

function Export-UnusedDiskReport {
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Object', 'Json', 'Csv')]
        [string]$Format,

        [Parameter()]
        [string]$Path,

        [Parameter()]
        [bool]$PrintTable
    )

    switch ($Format) {
        'Object' {
            if ($Path) {
                ConvertTo-Json -InputObject $Rows -Depth 5 -AsArray | Set-Content -Path $Path -Encoding UTF8
                Write-Verbose "Unused disk report written to '$Path'."
                return
            }

            if ($PrintTable) {
                $Rows | Format-Table -Property DiskName, SizeGB, ResourceGroup -AutoSize
                return
            }

            $Rows
        }
        'Json' {
            $json = ConvertTo-Json -InputObject $Rows -Depth 5 -AsArray
            if ($Path) {
                $json | Set-Content -Path $Path -Encoding UTF8
                Write-Verbose "Unused disk report written to '$Path'."
                return
            }

            $json
        }
        'Csv' {
            if ($Path) {
                $Rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
                Write-Verbose "Unused disk report written to '$Path'."
                return
            }

            $Rows | ConvertTo-Csv -NoTypeInformation
        }
    }
}

Assert-AzModule

Disable-AzContextAutosave -Scope Process | Out-Null

$context = Get-AzContext
if ($null -eq $context) {
    throw 'No Azure context was found. Run Connect-AzAccount before running this script.'
}

if ($SubscriptionId) {
    $context = Set-AzContext -SubscriptionId $SubscriptionId
}

$diskParameters = @{
    DefaultProfile = $context
}
if ($ResourceGroupName) {
    $diskParameters.ResourceGroupName = $ResourceGroupName
}

$unusedDisks = @(
    Get-AzDisk @diskParameters |
    Where-Object { Test-UnattachedDisk -Disk $_ } |
    Sort-Object -Property ResourceGroupName, Name
)

$reportRows = @($unusedDisks | ForEach-Object { ConvertTo-UnusedDiskReportRow -Disk $_ })

if ($Delete) {
    foreach ($disk in $unusedDisks) {
        $target = "$($disk.ResourceGroupName)/$($disk.Name)"
        if ($PSCmdlet.ShouldProcess($target, 'Delete unattached managed disk')) {
            Remove-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Force -DefaultProfile $context | Out-Null
        }
    }
}

$printTable = -not $PSBoundParameters.ContainsKey('OutputFormat') -and [string]::IsNullOrWhiteSpace($OutputPath)
Export-UnusedDiskReport -Rows $reportRows -Format $OutputFormat -Path $OutputPath -PrintTable $printTable
