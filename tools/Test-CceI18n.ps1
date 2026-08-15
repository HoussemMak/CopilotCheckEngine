#Requires -Version 7.0
<#
.SYNOPSIS
    Valide l'internationalisation : cles de ressources, gabarits et catalogues.

.DESCRIPTION
    Controles effectues :
      1. Toute cle referencee par T dans src/ existe dans chaque fichier de langue.
      2. Pour une meme cle, le nombre de placeholders est identique dans toutes les langues
         (une traduction qui perd un {1} produirait un rapport tronque).
      3. Aucun litteral en langue naturelle ne subsiste dans -Observed / -Evidence / -Remediation.
      4. Les catalogues traduits couvrent exactement les memes exigences que le catalogue de
         reference, sans champ vide la ou la source est renseignee.

    Code de sortie 1 si au moins une erreur est detectee : utilisable en CI.

.EXAMPLE
    .\tools\Test-CceI18n.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Languages = @('fr', 'en')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Read-StringTable {
    param([string] $Path)
    $table = @{}
    if (-not (Test-Path $Path)) { return $null }
    $json = Get-Content -Path $Path -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) { $table[$p.Name] = [string] $p.Value }
    $table
}

function Get-MaxPlaceholder {
    param([string] $Template)
    $found = [regex]::Matches($Template, '\{(\d+)\}')
    if ($found.Count -eq 0) { return -1 }
    ($found | ForEach-Object { [int] $_.Groups[1].Value } | Measure-Object -Maximum).Maximum
}

Write-Host ''
Write-Host '  Validation i18n - Copilot Check Engine' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

# --- 1. Chargement des tables ---------------------------------------------------
$tables = @{}
foreach ($lang in $Languages) {
    $path = Join-Path $Root "data\strings.$lang.json"
    $tables[$lang] = Read-StringTable -Path $path
    if ($null -eq $tables[$lang]) {
        $errors.Add("Fichier de langue absent : $path")
    }
    else {
        Write-Host ("  strings.{0,-3} : {1,4} cles" -f $lang, $tables[$lang].Count)
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  ERREUR  $_" -ForegroundColor Red }
    exit 1
}

# --- 2. Cles referencees dans le code ------------------------------------------
$used = @{}
$files = Get-ChildItem -Path (Join-Path $Root 'src') -Recurse -Filter *.ps1

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName -Raw
    foreach ($m in [regex]::Matches($content, "T\s+'([^']+)'")) {
        $key = $m.Groups[1].Value
        if (-not $used.ContainsKey($key)) { $used[$key] = [System.Collections.Generic.List[string]]::new() }
        if ($used[$key] -notcontains $file.Name) { $used[$key].Add($file.Name) }
    }
}

# Le script d'orchestration et les outils referencent eux aussi des cles.
$entryPath = Join-Path $Root 'Invoke-CopilotCheckEngine.ps1'
$extra = @($entryPath)
$extra += @(Get-ChildItem -Path (Join-Path $Root 'tools') -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'Test-CceI18n.ps1' } |   # ce script cite des cles en exemple
    ForEach-Object { $_.FullName })

foreach ($path in ($extra | Where-Object { Test-Path $_ })) {
    $name = Split-Path $path -Leaf
    $content = Get-Content -Path $path -Raw
    foreach ($m in [regex]::Matches($content, "T\s+'([^']+)'")) {
        $key = $m.Groups[1].Value
        if (-not $used.ContainsKey($key)) { $used[$key] = [System.Collections.Generic.List[string]]::new() }
        if ($used[$key] -notcontains $name) { $used[$key].Add($name) }
    }
}

Write-Host ("  cles referencees dans le code : {0}" -f $used.Count)

foreach ($key in ($used.Keys | Sort-Object)) {
    foreach ($lang in $Languages) {
        if (-not $tables[$lang].ContainsKey($key)) {
            $errors.Add("Cle manquante en '$lang' : $key (utilisee dans $($used[$key] -join ', '))")
        }
    }
}

# --- 3. Coherence des placeholders ---------------------------------------------
$reference = $Languages[0]
foreach ($key in ($tables[$reference].Keys | Sort-Object)) {
    $expected = Get-MaxPlaceholder -Template $tables[$reference][$key]
    foreach ($lang in ($Languages | Where-Object { $_ -ne $reference })) {
        if (-not $tables[$lang].ContainsKey($key)) {
            $errors.Add("Cle absente en '$lang' : $key")
            continue
        }
        $actual = Get-MaxPlaceholder -Template $tables[$lang][$key]
        if ($actual -ne $expected) {
            $errors.Add("Placeholders divergents pour '$key' : $reference attend {0..$expected}, $lang expose {0..$actual}")
        }
    }
}

# --- 4. Cles orphelines ---------------------------------------------------------
# Certaines familles sont resolues dynamiquement (T "status.$token") : la recherche
# statique ne peut pas les voir, on ne les signale donc pas comme orphelines.
$dynamicPrefixes = @('status.', 'priority.')
$orphans = @($tables[$reference].Keys | Where-Object {
    $key = $_
    (-not $used.ContainsKey($key)) -and (-not ($dynamicPrefixes | Where-Object { $key.StartsWith($_) }))
})
if ($orphans.Count -gt 0) {
    $warnings.Add("$($orphans.Count) cle(s) definie(s) mais jamais utilisee(s) : $(($orphans | Select-Object -First 8) -join ', ')$(if ($orphans.Count -gt 8) { ', ...' })")
}

# --- 5. Arguments de formatage ---------------------------------------------------
# Un gabarit qui attend {0}..{n} doit recevoir au moins n+1 arguments, sinon
# l'operateur -f leve une exception a l'execution.
function Measure-FormatArgument {
    param([string] $Expression)

    $depth = 0
    $count = 1
    $inSingle = $false
    $inDouble = $false

    foreach ($ch in $Expression.ToCharArray()) {
        switch ($ch) {
            "'" { if (-not $inDouble) { $inSingle = -not $inSingle } }
            '"' { if (-not $inSingle) { $inDouble = -not $inDouble } }
            '(' { if (-not $inSingle -and -not $inDouble) { $depth++ } }
            '[' { if (-not $inSingle -and -not $inDouble) { $depth++ } }
            '{' { if (-not $inSingle -and -not $inDouble) { $depth++ } }
            ')' { if (-not $inSingle -and -not $inDouble) { $depth-- } }
            ']' { if (-not $inSingle -and -not $inDouble) { $depth-- } }
            '}' { if (-not $inSingle -and -not $inDouble) { $depth-- } }
            ',' { if ($depth -eq 0 -and -not $inSingle -and -not $inDouble) { $count++ } }
        }
    }
    $count
}

function Get-LogicalLine {
    <# Recolle les continuations de ligne (backtick final) en conservant le numero d'origine. #>
    param([string[]] $Lines)

    $logical = [System.Collections.Generic.List[object]]::new()
    $buffer = ''
    $start = 0

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $raw = $Lines[$i]
        if ($buffer -eq '') { $start = $i }

        if ($raw -match '`\s*$') {
            $buffer += ($raw -replace '`\s*$', ' ')
            continue
        }

        $logical.Add([pscustomobject]@{ Line = $start + 1; Text = $buffer + $raw })
        $buffer = ''
    }

    if ($buffer -ne '') { $logical.Add([pscustomobject]@{ Line = $start + 1; Text = $buffer }) }
    $logical
}

$callSites = 0
foreach ($file in ($files + @(Get-Item $entryPath -ErrorAction SilentlyContinue) | Where-Object { $_ })) {
    foreach ($logical in (Get-LogicalLine -Lines (Get-Content -Path $file.FullName))) {
        $found = [regex]::Matches($logical.Text, "\(T\s+'([^']+)'\)\s*-f\s+")
        if ($found.Count -eq 0) { continue }

        for ($k = 0; $k -lt $found.Count; $k++) {
            $current = $found[$k]
            $argStart = $current.Index + $current.Length
            # Les arguments courent jusqu'au prochain appel formate, ou jusqu'a la fin de la ligne logique.
            $argEnd = if ($k + 1 -lt $found.Count) { $found[$k + 1].Index } else { $logical.Text.Length }
            $argText = $logical.Text.Substring($argStart, $argEnd - $argStart)

            $callSites++
            $key = $current.Groups[1].Value
            $argCount = Measure-FormatArgument -Expression $argText

            foreach ($lang in $Languages) {
                if (-not $tables[$lang].ContainsKey($key)) { continue }
                $needed = (Get-MaxPlaceholder -Template $tables[$lang][$key]) + 1
                if ($needed -gt $argCount) {
                    $errors.Add("Arguments insuffisants pour '$key' en '$lang' : gabarit attend $needed, appel fournit $argCount ($($file.Name):$($logical.Line))")
                }
            }
        }
    }
}
Write-Host ("  appels formates analyses      : {0}" -f $callSites)

# --- 6. Litteraux residuels dans les controles ----------------------------------
# Un texte destine a l'utilisateur ne doit plus apparaitre en dur : seuls les
# gabarits (T 'cle'), les valeurs techniques et les chaines vides sont admis.
$frenchHint = '[éèêëàâîïôûùçÉÈÊÀÂÎÔÛÙÇ]|\b(aucun|aucune|utilisateur|licence|strategie|verifier|activer|configurer|donnees|compte|conforme|exigence|parametre)\b'
$checkFiles = Get-ChildItem -Path (Join-Path $Root 'src\Checks') -Filter *.ps1

foreach ($file in $checkFiles) {
    $lines = Get-Content -Path $file.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch '-(Observed|Evidence|Remediation)\s') { continue }
        # On ignore les lignes qui delegent deja a une ressource ou a une variable.
        if ($line -match "T\s+'") { continue }
        if ($line -match '-(Observed|Evidence|Remediation)\s+\$') { continue }

        if ($line -match "-(Observed|Evidence|Remediation)\s+[`"']" -and $line -imatch $frenchHint) {
            $warnings.Add("Litteral residuel possible : $($file.Name):$($i + 1)")
        }
    }
}

# --- 6. Catalogues traduits -----------------------------------------------------
$refCatalogPath = Join-Path $Root 'data\checklist-catalog.json'
$refCatalog = Get-Content -Path $refCatalogPath -Raw -Encoding utf8 | ConvertFrom-Json
$refIds = @($refCatalog.items.Id) | Sort-Object

$textFields = 'Section', 'Category', 'Requirement', 'Rationale', 'HowTo', 'Expected', 'Verification', 'Priority', 'Reference'

foreach ($lang in ($Languages | Where-Object { $_ -ne 'fr' })) {
    $path = Join-Path $Root "data\checklist-catalog.$lang.json"
    if (-not (Test-Path $path)) {
        $errors.Add("Catalogue traduit absent : $path")
        continue
    }

    $catalog = Get-Content -Path $path -Raw -Encoding utf8 | ConvertFrom-Json
    $ids = @($catalog.items.Id) | Sort-Object

    if ($catalog.items.Count -ne $refCatalog.items.Count) {
        $errors.Add("Catalogue '$lang' : $($catalog.items.Count) exigences contre $($refCatalog.items.Count) attendues")
    }

    $missing = @($refIds | Where-Object { $_ -notin $ids })
    if ($missing.Count -gt 0) { $errors.Add("Catalogue '$lang' : exigences manquantes -> $($missing -join ', ')") }

    foreach ($item in $catalog.items) {
        $source = $refCatalog.items | Where-Object { $_.Id -eq $item.Id } | Select-Object -First 1
        if (-not $source) { continue }

        foreach ($field in $textFields) {
            $srcValue = "$($source.$field)"
            $dstValue = "$($item.$field)"
            if (-not [string]::IsNullOrWhiteSpace($srcValue) -and [string]::IsNullOrWhiteSpace($dstValue)) {
                $errors.Add("Catalogue '$lang' : exigence $($item.Id), champ '$field' vide alors que la source est renseignee")
            }
        }

        # Un Rationale traduit nettement plus court trahit un resume.
        $srcLen = "$($source.Rationale)".Length
        $dstLen = "$($item.Rationale)".Length
        if ($srcLen -gt 200 -and $dstLen -lt ($srcLen * 0.5)) {
            $warnings.Add("Catalogue '$lang' : exigence $($item.Id), justification potentiellement resumee ($dstLen contre $srcLen caracteres)")
        }
    }

    Write-Host ("  catalogue {0} : {1} exigences" -f $lang, $catalog.items.Count)
}

# --- Restitution ----------------------------------------------------------------
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

foreach ($w in $warnings) { Write-Host "  AVERTISSEMENT  $w" -ForegroundColor Yellow }
foreach ($e in $errors) { Write-Host "  ERREUR         $e" -ForegroundColor Red }

if ($errors.Count -eq 0) {
    Write-Host ("  Validation i18n reussie ({0} avertissement(s))" -f $warnings.Count) -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("  {0} erreur(s), {1} avertissement(s)" -f $errors.Count, $warnings.Count) -ForegroundColor Red
Write-Host ''
exit 1
