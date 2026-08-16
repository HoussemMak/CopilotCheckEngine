#Requires -Version 7.0
<#
.SYNOPSIS
    Detecte les lectures de .Count exposees au mode strict, par analyse de l'arbre syntaxique.

.DESCRIPTION
    Le moteur s'execute en Set-StrictMode -Version Latest. Dans ce mode, deux pieges de
    PowerShell font echouer un audit en pleine execution :

      1. Un pipeline qui ne rend AUCUN element vaut $null, pas un tableau vide.
         $null.Count leve alors une exception.
      2. Un pipeline qui rend UN SEUL element est deroule en scalaire au retour d'une
         fonction. Selon le type obtenu, .Count peut ne pas exister.

    Les deux se corrigent de la meme facon : envelopper dans @(), qui garantit un tableau
    quel que soit le nombre d'elements.

    Ces deux defauts ont ete rencontres en conditions reelles, l'un arretant l'audit au
    moment precis ou il fallait afficher le bilan de connexion. Cet analyseur empeche
    leur retour.

    NIVEAUX DE SIGNALEMENT
      Certain    : (pipeline).Count sans @() englobant. Toujours un defaut.
      A verifier : $variable.Count ou la variable est affectee depuis une commande ou un
                   pipeline non enveloppe. Peut etre legitime si la commande rend toujours
                   un tableau, d'ou la relecture humaine.

.EXAMPLE
    .\tools\Test-CceStrictMode.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [switch] $IncludeSuspect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$certain = [System.Collections.Generic.List[object]]::new()
$suspect = [System.Collections.Generic.List[object]]::new()

# Commandes connues pour toujours rendre un tableau : leur resultat est sur.
$safeCommands = @('Get-CceResponseValue', 'ConvertTo-CceText')

function Test-SafeWrapper {
    <# Vrai si l'expression est deja enveloppee dans @() ou est un litteral de tableau. #>
    param($Expression)
    $Expression -is [System.Management.Automation.Language.ArrayExpressionAst] -or
    $Expression -is [System.Management.Automation.Language.ArrayLiteralAst]
}

function Get-PipelineCommandName {
    <# Nom de la premiere commande d'un pipeline, ou chaine vide. #>
    param($Pipeline)

    if ($Pipeline -isnot [System.Management.Automation.Language.PipelineAst]) { return '' }
    foreach ($element in $Pipeline.PipelineElements) {
        if ($element -is [System.Management.Automation.Language.CommandAst]) {
            return "$($element.GetCommandName())"
        }
    }
    ''
}

$files = Get-ChildItem -Path (Join-Path $Root 'src') -Recurse -Filter *.ps1
$files += Get-Item (Join-Path $Root 'Invoke-CopilotCheckEngine.ps1')

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
    if ($errors) { continue }

    # Toutes les affectations du fichier, pour tracer l'origine d'une variable.
    $assignments = @{}
    foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = $node.Left.VariablePath.UserPath
        if (-not $assignments.ContainsKey($name)) { $assignments[$name] = [System.Collections.Generic.List[object]]::new() }
        $assignments[$name].Add($node)
    }

    $members = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($n.Member)" -eq 'Count'
        }, $true)

    foreach ($member in $members) {
        $target = $member.Expression
        $line = $member.Extent.StartLineNumber
        $text = $member.Extent.Text -replace '\s+', ' '
        if ($text.Length -gt 90) { $text = $text.Substring(0, 90) + '...' }

        # Cas 1 : (pipeline).Count sans @()
        if ($target -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $inner = $target.Pipeline
            $commandName = Get-PipelineCommandName -Pipeline $inner

            if ($commandName -and $commandName -notin $safeCommands) {
                $certain.Add([pscustomobject]@{
                    File = $file.Name; Line = $line; Text = $text
                    Why  = "pipeline '$commandName' non enveloppe dans @()"
                })
            }
            continue
        }

        # Cas 2 : $variable.Count, on remonte a l'affectation
        if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $name = $target.VariablePath.UserPath
            if (-not $assignments.ContainsKey($name)) { continue }

            $risky = $null
            foreach ($assignment in $assignments[$name]) {
                if ($assignment.Extent.StartLineNumber -gt $line) { continue }

                $right = $assignment.Right
                if ($right -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    if (Test-SafeWrapper -Expression $right.Expression) { $risky = $null; continue }
                }

                $commandName = Get-PipelineCommandName -Pipeline $right
                if ($commandName -and $commandName -notin $safeCommands) {
                    $risky = $commandName
                }
                else {
                    $risky = $null
                }
            }

            if ($risky) {
                $suspect.Add([pscustomobject]@{
                    File = $file.Name; Line = $line; Text = $text
                    Why  = "`$$name affecte depuis '$risky' sans @()"
                })
            }
        }
    }
}

Write-Host ''
Write-Host '  Analyse du mode strict - Copilot Check Engine' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ("  Fichiers analyses          : {0}" -f @($files).Count)
Write-Host ("  Lectures de .Count certaines : {0}" -f $certain.Count)
Write-Host ("  A verifier                 : {0}" -f $suspect.Count)
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

foreach ($item in $certain) {
    Write-Host ("  DEFAUT  {0}:{1}" -f $item.File, $item.Line) -ForegroundColor Red
    Write-Host ("          {0}" -f $item.Text) -ForegroundColor DarkGray
    Write-Host ("          {0}" -f $item.Why) -ForegroundColor DarkGray
}

if ($IncludeSuspect) {
    foreach ($item in $suspect) {
        Write-Host ("  A VOIR  {0}:{1}  {2}" -f $item.File, $item.Line, $item.Why) -ForegroundColor Yellow
        Write-Host ("          {0}" -f $item.Text) -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($certain.Count -eq 0) {
    Write-Host '  Aucune lecture de .Count exposee au mode strict' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("  {0} defaut(s) a corriger" -f $certain.Count) -ForegroundColor Red
Write-Host ''
exit 1
