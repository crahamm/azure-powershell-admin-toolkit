#!/usr/bin/env pwsh
<#
.SYNOPSIS
Builds a structured inventory report for Azure resources.

.DESCRIPTION
Scans the current Azure subscription, a specified subscription, or a specific resource group and returns a report containing metadata, resource summaries, and resource records.

Requires an authenticated Azure PowerShell session and the Az.Accounts and Az.Resources modules.

The caller needs permission to read resources at the selected subscription or resource group scope, such as the Reader role. Inventory output can include sensitive operational metadata from resource names, tags, locations, SKUs, and expanded properties.

.PARAMETER SubscriptionId
The Azure subscription ID to scan. If omitted, the current Az context subscription is used.

.PARAMETER ResourceGroupName
The resource group to scan. If omitted, all resources in the selected subscription are scanned.

.PARAMETER OutputFormat
The output format. Object returns a PowerShell report object, Json returns JSON, and Csv returns resource rows as CSV.

.PARAMETER OutputPath
Writes the report to a file instead of the pipeline. Object and Json write JSON. Csv writes resource rows.

.PARAMETER IncludeProperties
Includes expanded resource properties in each resource record. This can make the report significantly larger.

.EXAMPLE
./Get-AzResourceInventory.ps1

Returns an inventory report for the current Azure context subscription.

.EXAMPLE
./Get-AzResourceInventory.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -OutputFormat Json -OutputPath './inventory.json'

Scans the specified subscription and writes the full report to JSON.

.EXAMPLE
./Get-AzResourceInventory.ps1 -ResourceGroupName 'rg-prod' -OutputFormat Csv -OutputPath './rg-prod-inventory.csv'

Scans one resource group and writes resource rows to CSV.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateSet('Object', 'Json', 'Csv')]
    [string]$OutputFormat = 'Object',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$IncludeProperties
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AzModule {
    $requiredModules = @('Az.Accounts', 'Az.Resources')

    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "The '$moduleName' module is required. Install it with: Install-Module $moduleName -Scope CurrentUser"
        }
    }
}

function ConvertTo-CompressedJson {
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [int]$Depth = 20
    )

    process {
        if ($null -eq $InputObject) {
            return $null
        }

        $InputObject | ConvertTo-Json -Depth $Depth -Compress
    }
}

function Get-ResourceGroupFromId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    if ($ResourceId -match '/resourceGroups/([^/]+)') {
        return [System.Uri]::UnescapeDataString($Matches[1])
    }

    return $null
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

function ConvertTo-ResourceInventoryRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,

        [Parameter(Mandatory = $true)]
        [string]$CurrentSubscriptionId,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeExpandedProperties
    )

    $resourceGroup = Get-ObjectPropertyValue -InputObject $Resource -Name 'ResourceGroupName'
    $resourceId = Get-ObjectPropertyValue -InputObject $Resource -Name 'ResourceId'
    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        $resourceId = Get-ObjectPropertyValue -InputObject $Resource -Name 'Id'
    }

    if ([string]::IsNullOrWhiteSpace($resourceGroup) -and -not [string]::IsNullOrWhiteSpace($resourceId)) {
        $resourceGroup = Get-ResourceGroupFromId -ResourceId $resourceId
    }

    $skuName = $null
    $skuTier = $null
    $sku = Get-ObjectPropertyValue -InputObject $Resource -Name 'Sku'
    if ($null -ne $sku) {
        $skuName = Get-ObjectPropertyValue -InputObject $sku -Name 'Name'
        $skuTier = Get-ObjectPropertyValue -InputObject $sku -Name 'Tier'
    }

    $record = [ordered]@{
        Name              = Get-ObjectPropertyValue -InputObject $Resource -Name 'Name'
        ResourceGroupName = $resourceGroup
        ResourceType      = Get-ObjectPropertyValue -InputObject $Resource -Name 'ResourceType'
        Location          = Get-ObjectPropertyValue -InputObject $Resource -Name 'Location'
        SubscriptionId    = $CurrentSubscriptionId
        ResourceId        = $resourceId
        Kind              = Get-ObjectPropertyValue -InputObject $Resource -Name 'Kind'
        SkuName           = $skuName
        SkuTier           = $skuTier
        Tags              = Get-ObjectPropertyValue -InputObject $Resource -Name 'Tags'
    }

    if ($IncludeExpandedProperties) {
        $record.Properties = Get-ObjectPropertyValue -InputObject $Resource -Name 'Properties'
    }

    [pscustomobject]$record
}

function Get-SummaryGroup {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Resources,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    $Resources |
    Group-Object -Property $PropertyName |
    Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name |
    ForEach-Object {
        [pscustomobject]@{
            Name  = if ([string]::IsNullOrWhiteSpace($_.Name)) { '<none>' } else { $_.Name }
            Count = $_.Count
        }
    }
}

function Export-InventoryReport {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Object', 'Json', 'Csv')]
        [string]$Format,

        [Parameter()]
        [string]$Path
    )

    switch ($Format) {
        'Object' {
            if ($Path) {
                $Report | ConvertTo-Json -Depth 50 | Set-Content -Path $Path -Encoding UTF8
                Write-Verbose "Inventory report written to '$Path'."
                return
            }

            $Report
        }
        'Json' {
            $json = $Report | ConvertTo-Json -Depth 50
            if ($Path) {
                $json | Set-Content -Path $Path -Encoding UTF8
                Write-Verbose "Inventory report written to '$Path'."
                return
            }

            $json
        }
        'Csv' {
            $csvRows = $Report.Resources | ForEach-Object {
                $row = [ordered]@{}
                foreach ($property in $_.PSObject.Properties) {
                    if ($property.Name -in @('Tags', 'Properties')) {
                        $row[$property.Name] = $property.Value | ConvertTo-CompressedJson -Depth 50
                    }
                    else {
                        $row[$property.Name] = $property.Value
                    }
                }

                [pscustomobject]$row
            }

            if ($Path) {
                $csvRows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
                Write-Verbose "Inventory resources written to '$Path'."
                return
            }

            $csvRows | ConvertTo-Csv -NoTypeInformation
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

$subscription = Get-AzSubscription -SubscriptionId $context.Subscription.Id -DefaultProfile $context
$scope = if ($ResourceGroupName) { 'ResourceGroup' } else { 'Subscription' }

$resourceParameters = @{
    DefaultProfile = $context
}
if ($ResourceGroupName) {
    $resourceParameters.ResourceGroupName = $ResourceGroupName
}
if ($IncludeProperties) {
    $resourceParameters.ExpandProperties = $true
}

$resources = @(Get-AzResource @resourceParameters)
$records = @(
    foreach ($resource in $resources) {
        ConvertTo-ResourceInventoryRecord `
            -Resource $resource `
            -CurrentSubscriptionId $subscription.Id `
            -IncludeExpandedProperties $IncludeProperties.IsPresent
    }
)
$records = @($records | Sort-Object -Property ResourceGroupName, ResourceType, Name, ResourceId)

$report = [pscustomobject]@{
    Metadata  = [pscustomobject]@{
        GeneratedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        TenantId          = $context.Tenant.Id
        SubscriptionId    = $subscription.Id
        SubscriptionName  = $subscription.Name
        Scope             = $scope
        ResourceGroupName = $ResourceGroupName
        ResourceCount     = $records.Count
    }
    Summary   = [pscustomobject]@{
        ByResourceGroup = @(Get-SummaryGroup -Resources $records -PropertyName 'ResourceGroupName')
        ByResourceType  = @(Get-SummaryGroup -Resources $records -PropertyName 'ResourceType')
        ByLocation      = @(Get-SummaryGroup -Resources $records -PropertyName 'Location')
    }
    Resources = $records
}

Export-InventoryReport -Report $report -Format $OutputFormat -Path $OutputPath
