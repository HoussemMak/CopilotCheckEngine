#Requires -Version 7.0
<#
.SYNOPSIS
    Regenere data/checklist-catalog.json a partir du classeur Excel de reference.

.DESCRIPTION
    Le catalogue JSON est la source de verite du moteur : il porte les 59 exigences
    (categorie, description, justification, procedure, valeur attendue, priorite,
    reference Microsoft Learn). Les fonctions de controle (src/Checks) ne portent
    que la logique d'interrogation du tenant.

    A relancer uniquement lorsque le classeur de reference evolue.

.EXAMPLE
    .\tools\Convert-XlsxToCatalog.ps1 -XlsxPath .\Copilot_Config_Checklist.xlsx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $XlsxPath,

    [string] $OutputPath = (Join-Path $PSScriptRoot '..\data\checklist-catalog.json'),

    [string] $WorksheetName = 'Checklist',

    [int] $HeaderRow = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ImportExcel -ErrorAction Stop

$rows = Import-Excel -Path $XlsxPath -WorksheetName $WorksheetName -NoHeader -StartRow ($HeaderRow + 1)

$items = [System.Collections.Generic.List[object]]::new()
$currentSection = $null

foreach ($row in $rows) {
    $id = "$($row.P1)".Trim()
    $requirement = "$($row.P3)".Trim()

    # Ligne de section : un libelle en colonne A et rien dans les autres colonnes.
    if ([string]::IsNullOrWhiteSpace($requirement)) {
        if (-not [string]::IsNullOrWhiteSpace($id) -and $id -notmatch '^\d+$' -and $id -notmatch 'Checklist de configuration') {
            $currentSection = $id
        }
        continue
    }

    if ($id -notmatch '^\d+$') { continue }

    $items.Add([ordered]@{
        Id           = [int] $id
        Section      = $currentSection
        Category     = "$($row.P2)".Trim()
        Requirement  = $requirement
        Rationale    = "$($row.P4)".Trim()
        HowTo        = "$($row.P5)".Trim()
        Expected     = "$($row.P6)".Trim()
        Verification = "$($row.P7)".Trim()
        Priority     = "$($row.P8)".Trim()
        Reference    = "$($row.P10)".Trim()
    })
}

$catalog = [ordered]@{
    schemaVersion = '1.0'
    title         = 'Microsoft 365 Copilot - Checklist de configuration tenant'
    version       = '2.0'
    generatedFrom = [System.IO.Path]::GetFileName($XlsxPath)
    itemCount     = $items.Count
    items         = $items
}

$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$catalog | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding utf8NoBOM

Write-Host "Catalogue ecrit : $OutputPath ($($items.Count) exigences)" -ForegroundColor Green
