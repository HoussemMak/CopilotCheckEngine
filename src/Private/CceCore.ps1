#Requires -Version 7.0
<#
    Noyau du moteur : modele de resultat, journalisation, helpers d'execution.
    Ce fichier est dot-source par Invoke-CopilotCheckEngine.ps1.
#>

# Statuts normalises utilises par tout le moteur.
$script:CceStatus = @{
    Conforme    = 'Conforme'      # verifie automatiquement, conforme a la valeur attendue
    NonConforme = 'Non conforme'  # verifie automatiquement, ecart avere
    Attention   = 'Attention'     # verifie, conforme partiellement ou a arbitrer
    Manuel      = 'Manuel'        # aucune API publique : verification humaine requise
    NonEvalue   = 'Non evalue'    # service non connecte / droits insuffisants / erreur
}

function Write-CceLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')] [string] $Level = 'INFO'
    )

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }

    $stamp = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("[{0}] [{1,-5}] {2}" -f $stamp, $Level, $Message) -ForegroundColor $color

    if ($null -ne $script:CceContext) {
        $script:CceContext.Log.Add([pscustomobject]@{
            Timestamp = (Get-Date)
            Level     = $Level
            Message   = $Message
        }) | Out-Null
    }
}

function New-CceResult {
    <#
    .SYNOPSIS
        Fabrique le resultat normalise d'un controle.
    .PARAMETER Observed
        Valeur reellement constatee sur le tenant (colonne "Valeur constatee").
    .PARAMETER Evidence
        Preuve detaillee (objets, listes, comptages) reportee dans l'onglet Preuves.
    .PARAMETER Remediation
        Action concrete a mener lorsque le controle n'est pas conforme.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Conforme', 'Non conforme', 'Attention', 'Manuel', 'Non evalue')]
        [string] $Status,

        [string] $Observed = '',
        [string] $Evidence = '',
        [string] $Remediation = ''
    )

    [pscustomobject]@{
        Status      = $Status
        Observed    = $Observed
        Evidence    = $Evidence
        Remediation = $Remediation
    }
}

function Get-CceSafe {
    <#
    .SYNOPSIS
        Execute un bloc d'interrogation en neutralisant les erreurs de service.
    .DESCRIPTION
        Toute exception est convertie en $null et journalisee : un controle en echec
        ne doit jamais interrompre l'execution de bout en bout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $What = 'requete'
    )

    try {
        & $ScriptBlock
    }
    catch {
        Write-CceLog "Echec $What : $($_.Exception.Message)" -Level WARN
        $null
    }
}

function ConvertTo-CceText {
    <#
    .SYNOPSIS
        Aplatit une collection en texte lisible pour les colonnes de preuve.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] $InputObject,
        [int] $MaxItems = 15
    )

    begin { $buffer = [System.Collections.Generic.List[object]]::new() }
    process { if ($null -ne $InputObject) { $buffer.Add($InputObject) } }
    end {
        if ($buffer.Count -eq 0) { return '' }

        $shown = $buffer | Select-Object -First $MaxItems
        $lines = foreach ($entry in $shown) {
            if ($entry -is [string]) { $entry }
            else { ($entry | Format-List | Out-String).Trim() -replace '\r?\n\s*', ' ; ' }
        }

        $text = $lines -join [Environment]::NewLine
        if ($buffer.Count -gt $MaxItems) {
            $text += [Environment]::NewLine + ("... et {0} autre(s) element(s)" -f ($buffer.Count - $MaxItems))
        }
        $text
    }
}

function New-CceContext {
    <#
    .SYNOPSIS
        Cree le contexte partage par tous les controles.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Configuration = @{}
    )

    [pscustomobject]@{
        StartedAt     = Get-Date
        Tenant        = [ordered]@{ Id = ''; Name = ''; DefaultDomain = '' }
        Services      = [ordered]@{
            Graph      = $false
            Exchange   = $false
            Purview    = $false
            SharePoint = $false
            Teams      = $false
        }
        ServiceError  = [ordered]@{}
        Cache         = @{}
        Config        = $Configuration
        Log           = [System.Collections.Generic.List[object]]::new()
    }
}

function Get-CceCopilotSkuPattern { '*COPILOT*' }

function Test-CceService {
    <#
    .SYNOPSIS
        Renvoie $true si le service demande est connecte, sinon journalise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams')]
        [string] $Service,
        [Parameter(Mandatory)] $Context
    )

    [bool] $Context.Services.$Service
}

function New-CceNotEvaluated {
    <#
    .SYNOPSIS
        Resultat standard lorsqu'un service requis n'est pas disponible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Service,
        [Parameter(Mandatory)] $Context
    )

    $reason = if ($Context.ServiceError.Contains($Service)) { $Context.ServiceError[$Service] } else { 'service non connecte' }

    New-CceResult -Status 'Non evalue' `
        -Observed "Service $Service indisponible" `
        -Evidence "Le controle necessite une connexion $Service. Motif : $reason" `
        -Remediation "Relancer le moteur avec les droits requis sur $Service."
}
