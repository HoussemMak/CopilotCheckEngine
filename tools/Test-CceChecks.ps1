#Requires -Version 7.0
<#
.SYNOPSIS
    Execute les 59 controles a vide, dans chaque langue, sans contacter de tenant.

.DESCRIPTION
    Aucun service n'est connecte : chaque controle doit soit renvoyer un resultat
    "Non evalue", soit produire son verdict autonome (cas des exigences manuelles).
    Le test echoue si un controle leve une exception, renvoie un statut inconnu,
    ou laisse apparaitre un marqueur [[cle]] revelant une ressource manquante.

    Complement d'execution a Test-CceI18n.ps1, qui verifie le meme contrat statiquement.

.EXAMPLE
    .\tools\Test-CceChecks.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Languages = @('fr', 'en')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($folder in 'Private', 'Checks', 'Export') {
    Get-ChildItem -Path (Join-Path $Root "src\$folder") -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
}

$validStatus = @('Compliant', 'NonCompliant', 'Warning', 'Manual', 'NotEvaluated')
$failures = [System.Collections.Generic.List[string]]::new()

Write-Host ''
Write-Host '  Execution a vide des controles - Copilot Check Engine' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

foreach ($lang in $Languages) {
    Import-CceStrings -Language $lang -DataPath (Join-Path $Root 'data') | Out-Null

    $script:CceContext = New-CceContext -Configuration @{
        IncludeLocalChecks = $false
        MailboxSampleSize  = 10
        CatalogTitle       = 'test'
        CatalogVersion     = '0'
    }
    $context = $script:CceContext
    $context.Tenant.Id = '00000000-0000-0000-0000-000000000000'

    $counts = @{}
    foreach ($s in $validStatus) { $counts[$s] = 0 }
    $executed = 0

    for ($id = 1; $id -le 59; $id++) {
        $name = 'Invoke-CceCheck{0:D2}' -f $id

        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            $failures.Add("[$lang] fonction absente : $name")
            continue
        }

        try {
            $result = & $name -Context $context
            $executed++
        }
        catch {
            $failures.Add("[$lang] $name a leve une exception : $($_.Exception.Message)")
            continue
        }

        if ($null -eq $result) {
            $failures.Add("[$lang] $name n'a rien renvoye")
            continue
        }

        if ($result.Status -notin $validStatus) {
            $failures.Add("[$lang] $name renvoie un statut inconnu : '$($result.Status)'")
        }
        else {
            $counts[$result.Status]++
        }

        foreach ($field in 'Observed', 'Evidence', 'Remediation') {
            $value = "$($result.$field)"
            if ($value -match '\[\[[^\]]+\]\]') {
                $failures.Add("[$lang] $name : ressource manquante dans $field -> $($Matches[0])")
            }
        }
    }

    $summary = ($validStatus | ForEach-Object { "$_=$($counts[$_])" }) -join ' '
    Write-Host ("  {0} : {1} controle(s) executes | {2}" -f $lang.ToUpper(), $executed, $summary)
}

Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

if ($failures.Count -eq 0) {
    Write-Host '  Execution a vide reussie' -ForegroundColor Green
    Write-Host ''
    exit 0
}

foreach ($f in $failures) { Write-Host "  ECHEC  $f" -ForegroundColor Red }
Write-Host ("  {0} echec(s)" -f $failures.Count) -ForegroundColor Red
Write-Host ''
exit 1
