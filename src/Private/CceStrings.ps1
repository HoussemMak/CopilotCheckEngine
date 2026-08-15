#Requires -Version 7.0
<#
    Ressources de langue / Language resources.

    Les fonctions de controle n'embarquent aucun texte : elles referencent une cle
    resolue par T. Les gabarits vivent dans data/strings.<lang>.json.

    Check functions embed no literal text: they reference a key resolved by T.
    Templates live in data/strings.<lang>.json.
#>

$script:CceStrings = $null            # langue active / active language
$script:CceStringsFallback = $null    # repli francais / French fallback
$script:CceLanguage = 'fr'

function Import-CceStrings {
    <#
    .SYNOPSIS
        Charge les ressources de la langue demandee, avec repli sur le francais.
    .PARAMETER Language
        'fr' ou 'en'.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('fr', 'en')] [string] $Language = 'fr',
        [string] $DataPath
    )

    if (-not $DataPath) { $DataPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data' }

    $script:CceLanguage = $Language

    $load = {
        param($lang)
        $path = Join-Path $DataPath "strings.$lang.json"
        if (-not (Test-Path $path)) { return $null }

        $table = @{}
        $json = Get-Content -Path $path -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($property in $json.PSObject.Properties) { $table[$property.Name] = [string] $property.Value }
        $table
    }

    $script:CceStringsFallback = & $load 'fr'
    $script:CceStrings = if ($Language -eq 'fr') { $script:CceStringsFallback } else { & $load $Language }

    if (-not $script:CceStrings) {
        throw "Ressources de langue introuvables : $(Join-Path $DataPath "strings.$Language.json")"
    }

    [pscustomobject]@{
        Language = $Language
        Loaded   = $script:CceStrings.Count
        Fallback = if ($script:CceStringsFallback) { $script:CceStringsFallback.Count } else { 0 }
    }
}

function T {
    <#
    .SYNOPSIS
        Resout une cle de ressource et renvoie le gabarit correspondant.
    .DESCRIPTION
        Renvoie le gabarit brut : l'appelant applique -f pour ses arguments.
        Cle absente dans la langue active -> repli francais -> marqueur [[cle]]
        (visible dans le rapport, donc detectable en recette).
    .EXAMPLE
        (T 'c03.obs.ok') -f $users.Count, $enabled.Count
    .EXAMPLE
        T 'c03.obs.none'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Key
    )

    if ($script:CceStrings -and $script:CceStrings.ContainsKey($Key)) { return $script:CceStrings[$Key] }
    if ($script:CceStringsFallback -and $script:CceStringsFallback.ContainsKey($Key)) { return $script:CceStringsFallback[$Key] }

    "[[$Key]]"
}

function Get-CceLanguage { $script:CceLanguage }

function Get-CceStringKey {
    <#
    .SYNOPSIS
        Liste les cles chargees (diagnostic et validation).
    #>
    [CmdletBinding()] param()
    if ($script:CceStrings) { $script:CceStrings.Keys | Sort-Object } else { @() }
}
