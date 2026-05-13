#!/usr/bin/env pwsh
<#
.SYNOPSIS
Lists Azure resources in a concise inventory format.

.DESCRIPTION
Scans the current Azure subscription, a specified subscription, or a specific resource group and returns resource inventory rows. When OutputFormat is omitted, rows are printed as a console table.

CreationDate is populated on a best-effort basis because Azure does not expose creation time consistently for every resource type.

Requires an authenticated Azure PowerShell session and the Az.Accounts and Az.Resources modules.

The caller needs permission to read resources at the selected subscription or resource group scope, such as the Reader role. Inventory output can include sensitive operational metadata from resource names, resource group names, tags, and creation dates.

.PARAMETER SubscriptionId
The Azure subscription ID to scan. If omitted, the current Az context subscription is used.

.PARAMETER ResourceGroupName
The resource group to scan. If omitted, all resources in the selected subscription are scanned.

.PARAMETER OutputFormat
The output format. Object returns PowerShell objects, Json returns JSON resource rows, and Csv returns resource rows as CSV.

.PARAMETER OutputPath
Writes resource rows to a file instead of the pipeline. Object and Json write JSON. Csv writes CSV.

.EXAMPLE
./Get-AzResourceInventory.ps1

Returns inventory rows for the current Azure context subscription.

.EXAMPLE
./Get-AzResourceInventory.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -OutputFormat Json -OutputPath './inventory.json'

Scans the specified subscription and writes inventory rows to JSON.

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
    [string]$OutputPath
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

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $InputObject[$key]
            }
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    $property.Value
}

function Get-NestedObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $value = $InputObject
    foreach ($name in $Names) {
        if ($null -eq $value) {
            return $null
        }

        $value = Get-ObjectPropertyValue -InputObject $value -Name $name
    }

    $value
}

function ConvertTo-IsoDateString {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return ([datetime]$Value).ToUniversalTime().ToString('o')
    }
    catch {
        return [string]$Value
    }
}

function Get-ResourceCreationDate {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    $propertyPaths = @(
        'CreatedTime',
        'TimeCreated',
        'CreationTime',
        'CreatedAt',
        'CreatedDate',
        'SystemData.CreatedAt',
        'Properties.createdAt',
        'Properties.createdTime',
        'Properties.creationTime',
        'Properties.timeCreated',
        'Properties.createdDate',
        'Properties.dateCreated'
    )

    foreach ($propertyPath in $propertyPaths) {
        $value = Get-NestedObjectPropertyValue -InputObject $Resource -Names ($propertyPath -split '\.')
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return ConvertTo-IsoDateString -Value $value
        }
    }

    return $null
}

function ConvertTo-TagString {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Tags
    )

    if ($null -eq $Tags) {
        return $null
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        $tagEntries = @($Tags.GetEnumerator() | Sort-Object -Property Name)
        if ($tagEntries.Count -eq 0) {
            return $null
        }

        return ($tagEntries | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
    }

    $tagProperties = @(
        $Tags.PSObject.Properties |
        Where-Object { $_.MemberType -in @('NoteProperty', 'Property') } |
        Sort-Object -Property Name
    )
    if ($tagProperties.Count -eq 0) {
        return $null
    }

    ($tagProperties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
}

function ConvertTo-FriendlyResourceTypeName {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$ResourceType
    )

    if ([string]::IsNullOrWhiteSpace($ResourceType)) {
        return $null
    }

    $typeName = ($ResourceType -split '/')[-1]
    $typeName = $typeName -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2'
    $typeName = $typeName -creplace '([a-z0-9])([A-Z])', '$1 $2'
    $words = @($typeName -split '[^A-Za-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($words.Count -eq 0) {
        return $null
    }

    $textInfo = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
    $lastIndex = $words.Count - 1
    if ($words[$lastIndex] -match 'ies$') {
        $words[$lastIndex] = $words[$lastIndex] -replace 'ies$', 'y'
    }
    elseif ($words[$lastIndex] -match 'sses$') {
        $words[$lastIndex] = $words[$lastIndex] -replace 'es$', ''
    }
    elseif ($words[$lastIndex] -match 's$') {
        $words[$lastIndex] = $words[$lastIndex] -replace 's$', ''
    }

    ($words | ForEach-Object {
        if ($_ -cmatch '^[A-Z0-9]{2,}$') {
            $_
        }
        else {
            $textInfo.ToTitleCase($_.ToLowerInvariant())
        }
    }) -join ''
}

function ConvertTo-InventoryOutputRow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record,

        [Parameter()]
        [switch]$StringifyTags
    )

    [pscustomobject][ordered]@{
        Name          = $Record.Name
        Type          = ConvertTo-FriendlyResourceTypeName -ResourceType $Record.ResourceType
        Region        = $Record.Location
        ResourceGroup = $Record.ResourceGroupName
        Tags          = if ($StringifyTags) { ConvertTo-TagString -Tags $Record.Tags } else { $Record.Tags }
        CreationDate  = $Record.CreationDate
    }
}

function ConvertTo-ResourceInventoryRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    $resourceGroup = Get-ObjectPropertyValue -InputObject $Resource -Name 'ResourceGroupName'
    $resourceId = Get-ObjectPropertyValue -InputObject $Resource -Name 'ResourceId'
    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        $resourceId = Get-ObjectPropertyValue -InputObject $Resource -Name 'Id'
    }

    if ([string]::IsNullOrWhiteSpace($resourceGroup) -and -not [string]::IsNullOrWhiteSpace($resourceId)) {
        $resourceGroup = Get-ResourceGroupFromId -ResourceId $resourceId
    }

    [pscustomobject][ordered]@{
        Name              = Get-ObjectPropertyValue -InputObject $Resource -Name 'Name'
        ResourceGroupName = $resourceGroup
        ResourceType      = Get-ObjectPropertyValue -InputObject $Resource -Name 'ResourceType'
        Location          = Get-ObjectPropertyValue -InputObject $Resource -Name 'Location'
        Tags              = Get-ObjectPropertyValue -InputObject $Resource -Name 'Tags'
        CreationDate      = Get-ResourceCreationDate -Resource $Resource
        ResourceId        = $resourceId
    }
}

function Export-InventoryRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Resources,

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
            $rows = @($Resources | ForEach-Object { ConvertTo-InventoryOutputRow -Record $_ -StringifyTags })
            if ($Path) {
                $rows | ConvertTo-Json -Depth 10 -AsArray | Set-Content -Path $Path -Encoding UTF8
                Write-Verbose "Inventory resources written to '$Path'."
                return
            }

            if ($PrintTable) {
                $rows | Format-Table -Property Name, Type, Region, ResourceGroup, Tags, @{ Label = 'Creation date'; Expression = { $_.CreationDate } } -AutoSize
                return
            }

            $rows
        }
        'Json' {
            $rows = @($Resources | ForEach-Object { ConvertTo-InventoryOutputRow -Record $_ })
            $json = $rows | ConvertTo-Json -Depth 10 -AsArray
            if ($Path) {
                $json | Set-Content -Path $Path -Encoding UTF8
                Write-Verbose "Inventory resources written to '$Path'."
                return
            }

            $json
        }
        'Csv' {
            $csvRows = @($Resources | ForEach-Object { ConvertTo-InventoryOutputRow -Record $_ -StringifyTags })

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

$resourceParameters = @{
    DefaultProfile    = $context
    ExpandProperties = $true
}
if ($ResourceGroupName) {
    $resourceParameters.ResourceGroupName = $ResourceGroupName
}

$resources = @(Get-AzResource @resourceParameters)
$records = @(
    foreach ($resource in $resources) {
        ConvertTo-ResourceInventoryRecord -Resource $resource
    }
)
$records = @($records | Sort-Object -Property ResourceGroupName, ResourceType, Name, ResourceId)

$printTable = -not $PSBoundParameters.ContainsKey('OutputFormat') -and [string]::IsNullOrWhiteSpace($OutputPath)
Export-InventoryRows -Resources $records -Format $OutputFormat -Path $OutputPath -PrintTable $printTable
