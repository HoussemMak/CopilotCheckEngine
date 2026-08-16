#Requires -Version 7.0
<#
.SYNOPSIS
    Tests de non-regression sur les pieges de PowerShell en mode strict.

.DESCRIPTION
    Deux defauts reels ont ete trouves par ce harnais et sont verrouilles ici :

      1. Un tableau d'un seul element est deroule en scalaire au retour d'une fonction.
         Sur un tenant ne possedant qu'un SEUL SKU Copilot, .Count levait alors sous
         Set-StrictMode Latest et l'audit s'arretait.

      2. Une requete Graph en echec renvoie $null. Lire .value dessus levait, et surtout
         une panne de lecture etait prise pour une collection vide, donc pour un ecart
         avere : le controle 4 declarait "aucun groupe de licence" alors qu'il n'avait
         simplement pas pu lire.

    Ces scenarios ne peuvent pas etre couverts par l'execution a vide (Test-CceChecks),
    qui ne traverse que les branches "service absent".

.EXAMPLE
    .\tools\Test-CceRegression.ps1
#>
[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($folder in 'Private', 'Checks', 'Export') {
    Get-ChildItem -Path (Join-Path $Root "src\$folder") -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
}

Import-CceStrings -Language fr -DataPath (Join-Path $Root 'data') | Out-Null

$failures = 0

function Assert-NoThrow {
    param([string] $Name, [scriptblock] $Action)
    try {
        $null = & $Action
        Write-Host "  OK    $Name" -ForegroundColor Green
    }
    catch {
        Write-Host "  ECHEC $Name : $($_.Exception.Message)" -ForegroundColor Red
        $script:failures++
    }
}

function New-TestContext {
    $script:CceContext = New-CceContext -Configuration @{ MailboxSampleSize = 10 }
    $script:CceContext.Services.Graph = $true
    $script:CceContext.Tenant.Id = '00000000-0000-0000-0000-000000000000'
    $script:CceContext
}

Write-Host ''
Write-Host '  Non-regression - Copilot Check Engine' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

# --- 1. Tenant avec un seul SKU Copilot -----------------------------------------
Write-Host '  Cas : un seul SKU Copilot (deroulement en scalaire)'
$context = New-TestContext
$context.Cache['Skus'] = @(
    [pscustomobject]@{
        SkuPartNumber = 'Microsoft_365_Copilot'
        SkuId         = '11111111-1111-1111-1111-111111111111'
        ConsumedUnits = 5
        PrepaidUnits  = [pscustomobject]@{ Enabled = 10 }
    }
)

Assert-NoThrow 'Get-CceCopilotSkuId' { @(Get-CceCopilotSkuId -Context $context) }
Assert-NoThrow 'Get-CceCopilotUser ' { $context.Cache['CopilotUsers'] = @(); Get-CceCopilotUser -Context $context }
Assert-NoThrow 'Invoke-CceCheck02  ' { Invoke-CceCheck02 -Context $context }

# --- 2. Reponse Graph nulle ------------------------------------------------------
Write-Host ''
Write-Host '  Cas : reponse Graph nulle (panne de lecture)'

Assert-NoThrow 'Get-CceResponseValue $null' { Get-CceResponseValue $null }
Assert-NoThrow 'Test-CceResponse $null    ' { Test-CceResponse $null }

# Une panne de lecture ne doit jamais se traduire par un ecart avere.
$result = Invoke-CceCheck04 -Context $context
if ($result.Status -eq 'NonCompliant') {
    Write-Host "  ECHEC Invoke-CceCheck04 : une panne de lecture est rendue comme un ecart ('$($result.Status)')" -ForegroundColor Red
    $failures++
}
else {
    Write-Host "  OK    Invoke-CceCheck04 : panne de lecture rendue '$($result.Status)', pas un ecart" -ForegroundColor Green
}

# --- 3. Aucun acces .value non garde dans le code --------------------------------
Write-Host ''
Write-Host '  Cas : aucun acces .value non garde'
# Recherche sensible a la casse : ".value" en minuscules designe la collection d'une
# reponse Graph, tandis que ".Value" designe la valeur d'un objet PSPropertyInfo deja
# teste par l'appelant. Confondre les deux produirait des alertes sans objet.
$unguarded = @(Select-String -Path (Join-Path $Root 'src\Checks\*.ps1'), (Join-Path $Root 'src\Private\*.ps1') `
        -Pattern '@\(\$\w+\.value\)' -CaseSensitive -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -notmatch '@\(\$Response\.value\)' })   # le corps de l'accesseur lui-meme

if ($unguarded.Count -eq 0) {
    Write-Host '  OK    toutes les reponses Graph passent par Get-CceResponseValue' -ForegroundColor Green
}
else {
    foreach ($u in $unguarded) { Write-Host "  ECHEC acces non garde : $(Split-Path $u.Path -Leaf):$($u.LineNumber)" -ForegroundColor Red }
    $failures += $unguarded.Count
}

Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
if ($failures -eq 0) { Write-Host '  Non-regression : verte' -ForegroundColor Green; Write-Host ''; exit 0 }
Write-Host "  $failures echec(s)" -ForegroundColor Red
Write-Host ''
exit 1
