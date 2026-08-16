#Requires -Version 7.0
<#
    Noyau du moteur : modele de resultat, journalisation, helpers d'execution.
    Ce fichier est dot-source par Invoke-CopilotCheckEngine.ps1.
#>

# Jetons canoniques de statut, independants de la langue.
# Les fonctions de controle continuent d'emettre les libelles francais historiques :
# New-CceResult les convertit ici. Toute la logique aval (statistiques, filtres,
# mise en forme conditionnelle) raisonne sur le jeton canonique, jamais sur l'affichage.
$script:CceStatusCanonical = @{
    'Conforme'       = 'Compliant'
    'Non conforme'   = 'NonCompliant'
    'Attention'      = 'Warning'
    'Manuel'         = 'Manual'
    'Non evalue'     = 'NotEvaluated'
    'Non applicable' = 'NotApplicable'
}

$script:CceStatusOrder = @('Compliant', 'NonCompliant', 'Warning', 'Manual', 'NotEvaluated', 'NotApplicable')

# Seuls ces trois statuts entrent au denominateur du taux de conformite : le moteur
# ne note que ce qu'il a lui-meme mesure, sur des capacites que le tenant possede.
$script:CceScorableStatus = @('Compliant', 'NonCompliant', 'Warning')

# Idem pour les priorites : le catalogue est localise, le moteur ne l'est pas.
$script:CcePriorityCanonical = @{
    'Bloquant'    = 'Blocking'
    'Recommande'  = 'Recommended'
    'Optimal'     = 'Optimal'
    'Blocking'    = 'Blocking'
    'Recommended' = 'Recommended'
}

$script:CcePriorityOrder = @('Blocking', 'Recommended', 'Optimal')

function ConvertTo-CceCanonicalStatus {
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Status)
    if ($script:CceStatusCanonical.ContainsKey($Status)) { $script:CceStatusCanonical[$Status] } else { $Status }
}

function ConvertTo-CceCanonicalPriority {
    [CmdletBinding()] param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Priority)
    if ($script:CcePriorityCanonical.ContainsKey($Priority)) { $script:CcePriorityCanonical[$Priority] } else { $Priority }
}

function Get-CceStatusLabel {
    <# Libelle affichable du statut, dans la langue active. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [string] $Status)
    T "status.$(ConvertTo-CceCanonicalStatus -Status $Status)"
}

function Get-CcePriorityLabel {
    <# Libelle affichable de la priorite, dans la langue active. #>
    [CmdletBinding()] param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Priority)
    T "priority.$(ConvertTo-CceCanonicalPriority -Priority $Priority)"
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
        [Parameter(Mandatory)]
        [ValidateSet('Conforme', 'Non conforme', 'Attention', 'Manuel', 'Non evalue', 'Non applicable')]
        [string] $Status,

        [string] $Observed = '',
        [string] $Evidence = '',
        [string] $Remediation = ''
    )

    [pscustomobject]@{
        Status      = ConvertTo-CceCanonicalStatus -Status $Status
        StatusInput = $Status
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
        Write-CceLog ((T 'core.safe.failed') -f $What, $_.Exception.Message) -Level WARN
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
            $text += [Environment]::NewLine + ((T 'core.truncated') -f ($buffer.Count - $MaxItems))
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
            Graph         = $false
            Exchange      = $false
            Purview       = $false
            SharePoint    = $false
            Teams         = $false
            # Domaines d'administration distincts, hors perimetre par defaut :
            # ils exigent leur propre role et leur propre consentement.
            PowerPlatform = $false
            Commerce      = $false
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
        [Parameter(Mandatory)]
        [ValidateSet('Graph', 'Exchange', 'Purview', 'SharePoint', 'Teams', 'PowerPlatform', 'Commerce')]
        [string] $Service,
        [Parameter(Mandatory)] $Context
    )

    [bool] $Context.Services.$Service
}

function New-CceNotApplicable {
    <#
    .SYNOPSIS
        Resultat standard lorsque le controle ne peut pas s'appliquer au tenant.
    .DESCRIPTION
        A reserver aux cas ou la capacite auditee n'est pas detenue par l'organisation
        (module complementaire absent, licence non souscrite, fonctionnalite hors perimetre).
        Ce statut sort du denominateur du taux de conformite : compter en ecart une
        capacite que le client n'a pas achetee produirait un score faux.
        A ne pas confondre avec "Non evalue", qui signale un manque de droits ou une erreur.
    .PARAMETER Reason
        Ce qui rend le controle inapplicable, en clair.
    .PARAMETER RequiredLicense
        Licence ou module complementaire qui debloquerait le controle, le cas echeant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Reason,
        [string] $RequiredLicense = '',
        [string] $Evidence = ''
    )

    $observed = if ($RequiredLicense) {
        (T 'core.notapplicable.obs.license') -f $RequiredLicense
    }
    else {
        T 'core.notapplicable.obs'
    }

    $remediation = if ($RequiredLicense) { (T 'core.notapplicable.rem') -f $RequiredLicense } else { '' }

    New-CceResult -Status 'Non applicable' `
        -Observed $observed `
        -Evidence $(if ($Evidence) { $Evidence } else { $Reason }) `
        -Remediation $remediation
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

    $reason = if ($Context.ServiceError.Contains($Service)) { $Context.ServiceError[$Service] } else { T 'core.notevaluated.reason' }

    New-CceResult -Status 'Non evalue' `
        -Observed ((T 'core.notevaluated.obs') -f $Service) `
        -Evidence ((T 'core.notevaluated.ev') -f $Service, $reason) `
        -Remediation ((T 'core.notevaluated.rem') -f $Service)
}
