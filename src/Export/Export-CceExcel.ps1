#Requires -Version 7.0
<#
    Export du rapport au format Excel (module ImportExcel).

    Toute la logique raisonne sur les jetons canoniques (Compliant, Blocking, ...)
    et n'utilise les libelles localises qu'au moment de l'ecriture.
#>

function Get-CceStatistics {
    <#
    .SYNOPSIS
        Agrege les indicateurs consommes par les deux exports.
    .DESCRIPTION
        Les champs Statut et Priorite des resultats portent des jetons canoniques,
        independants de la langue du rapport.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Results)

    $all = @($Results)
    $evaluableTokens = @('Compliant', 'NonCompliant', 'Warning')

    $byStatus = @{}
    foreach ($s in $script:CceStatusOrder) {
        $byStatus[$s] = @($all | Where-Object { $_.Statut -eq $s }).Count
    }

    $evaluables = $byStatus['Compliant'] + $byStatus['NonCompliant'] + $byStatus['Warning']
    $rate = if ($evaluables -gt 0) { [math]::Round(100 * $byStatus['Compliant'] / $evaluables, 1) } else { 0 }

    $byPriority = foreach ($p in $script:CcePriorityOrder) {
        $subset = @($all | Where-Object { $_.Priorite -eq $p })
        $ok = @($subset | Where-Object { $_.Statut -eq 'Compliant' }).Count
        $sub = @($subset | Where-Object { $_.Statut -in $evaluableTokens }).Count

        [pscustomobject]@{
            Priorite     = $p
            Libelle      = Get-CcePriorityLabel -Priority $p
            Total        = $subset.Count
            Evaluables   = $sub
            Conforme     = $ok
            NonConforme  = @($subset | Where-Object { $_.Statut -eq 'NonCompliant' }).Count
            Attention    = @($subset | Where-Object { $_.Statut -eq 'Warning' }).Count
            Manuel       = @($subset | Where-Object { $_.Statut -eq 'Manual' }).Count
            NonEvalue    = @($subset | Where-Object { $_.Statut -eq 'NotEvaluated' }).Count
            TauxPourcent = if ($sub -gt 0) { [math]::Round(100 * $ok / $sub, 1) } else { 0 }
        }
    }

    $bySection = foreach ($group in ($all | Group-Object Section)) {
        $ok = @($group.Group | Where-Object { $_.Statut -eq 'Compliant' }).Count
        $sub = @($group.Group | Where-Object { $_.Statut -in $evaluableTokens }).Count

        [pscustomobject]@{
            Section      = $group.Name
            Total        = $group.Count
            Evaluables   = $sub
            Conforme     = $ok
            NonConforme  = @($group.Group | Where-Object { $_.Statut -eq 'NonCompliant' }).Count
            Attention    = @($group.Group | Where-Object { $_.Statut -eq 'Warning' }).Count
            Manuel       = @($group.Group | Where-Object { $_.Statut -eq 'Manual' }).Count
            NonEvalue    = @($group.Group | Where-Object { $_.Statut -eq 'NotEvaluated' }).Count
            TauxPourcent = if ($sub -gt 0) { [math]::Round(100 * $ok / $sub, 1) } else { 0 }
        }
    }

    [pscustomobject]@{
        Total          = $all.Count
        Conforme       = $byStatus['Compliant']
        NonConforme    = $byStatus['NonCompliant']
        Attention      = $byStatus['Warning']
        Manuel         = $byStatus['Manual']
        NonEvalue      = $byStatus['NotEvaluated']
        Evaluables     = $evaluables
        TauxConformite = $rate
        ParPriorite    = @($byPriority)
        ParSection     = @($bySection)
        BloquantsKo    = @($all | Where-Object { $_.Priorite -eq 'Blocking' -and $_.Statut -eq 'NonCompliant' })
    }
}

function Export-CceExcel {
    <#
    .SYNOPSIS
        Produit le classeur de restitution (Synthese, Checklist, Preuves, Journal).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Path
    )

    Import-Module ImportExcel -ErrorAction Stop

    if (Test-Path $Path) { Remove-Item $Path -Force }

    $stats = Get-CceStatistics -Results $Results
    $tenantLabel = if ($Context.Tenant.Name) { $Context.Tenant.Name } else { $Context.Tenant.Id }

    $sheetSummary   = T 'xlsx.sheet.summary'
    $sheetChecklist = T 'xlsx.sheet.checklist'
    $sheetEvidence  = T 'xlsx.sheet.evidence'
    $sheetLog       = T 'xlsx.sheet.log'

    # ---------- Onglet Synthese ----------
    $summary = [System.Collections.Generic.List[object]]::new()
    $colIndicator = T 'xlsx.col.indicator'
    $colValue = T 'xlsx.col.value'

    $add = {
        param($k, $v)
        $row = [ordered]@{}
        $row[$colIndicator] = $k
        $row[$colValue] = $v
        $summary.Add([pscustomobject] $row)
    }

    & $add (T 'sum.tenant')       $tenantLabel
    & $add (T 'sum.tenantid')     $Context.Tenant.Id
    & $add (T 'sum.domain')       $Context.Tenant.DefaultDomain
    & $add (T 'sum.date')         $Context.StartedAt.ToString('yyyy-MM-dd HH:mm:ss')
    & $add (T 'sum.duration')     ([math]::Round(((Get-Date) - $Context.StartedAt).TotalSeconds, 1))
    & $add (T 'sum.language')     (Get-CceLanguage).ToUpper()
    & $add '' ''
    & $add (T 'sum.total')        $stats.Total
    & $add (T 'sum.compliant')    $stats.Conforme
    & $add (T 'sum.noncompliant') $stats.NonConforme
    & $add (T 'sum.warning')      $stats.Attention
    & $add (T 'sum.manual')       $stats.Manuel
    & $add (T 'sum.notevaluated') $stats.NonEvalue
    & $add '' ''
    & $add (T 'sum.evaluable')    $stats.Evaluables
    & $add (T 'sum.rate')         $stats.TauxConformite
    & $add (T 'sum.blockingko')   $stats.BloquantsKo.Count
    & $add '' ''

    foreach ($svc in $Context.Services.GetEnumerator()) {
        $label = if ($svc.Value) { T 'sum.connected' } else { T 'sum.notconnected' }
        & $add ((T 'sum.service') -f $svc.Key) $label
    }

    $summary | Export-Excel -Path $Path -WorksheetName $sheetSummary -AutoSize -BoldTopRow `
        -Title (T 'xlsx.title') -TitleBold -TitleSize 14

    $priorityTable = $stats.ParPriorite | Select-Object `
        @{N = (T 'col.priority');   E = { $_.Libelle } },
        @{N = (T 'col.total');      E = { $_.Total } },
        @{N = (T 'col.evaluable');  E = { $_.Evaluables } },
        @{N = (T 'status.Compliant');    E = { $_.Conforme } },
        @{N = (T 'status.NonCompliant'); E = { $_.NonConforme } },
        @{N = (T 'status.Warning');      E = { $_.Attention } },
        @{N = (T 'status.Manual');       E = { $_.Manuel } },
        @{N = (T 'status.NotEvaluated'); E = { $_.NonEvalue } },
        @{N = (T 'col.rate');       E = { $_.TauxPourcent } }

    $sectionTable = $stats.ParSection | Sort-Object Section | Select-Object `
        @{N = (T 'col.section');    E = { $_.Section } },
        @{N = (T 'col.total');      E = { $_.Total } },
        @{N = (T 'col.evaluable');  E = { $_.Evaluables } },
        @{N = (T 'status.Compliant');    E = { $_.Conforme } },
        @{N = (T 'status.NonCompliant'); E = { $_.NonConforme } },
        @{N = (T 'status.Warning');      E = { $_.Attention } },
        @{N = (T 'status.Manual');       E = { $_.Manuel } },
        @{N = (T 'status.NotEvaluated'); E = { $_.NonEvalue } },
        @{N = (T 'col.rate');       E = { $_.TauxPourcent } }

    $priorityTable | Export-Excel -Path $Path -WorksheetName $sheetSummary -StartRow ($summary.Count + 4) `
        -AutoSize -BoldTopRow -TableName 'ParPriorite' -TableStyle Medium2

    $sectionTable | Export-Excel -Path $Path -WorksheetName $sheetSummary `
        -StartRow ($summary.Count + 4 + @($stats.ParPriorite).Count + 3) `
        -AutoSize -BoldTopRow -TableName 'ParSection' -TableStyle Medium2

    # ---------- Onglet Checklist ----------
    $checklist = $Results | Select-Object `
        @{N = (T 'col.id');          E = { $_.Id } },
        @{N = (T 'col.section');     E = { $_.Section } },
        @{N = (T 'col.category');    E = { $_.Categorie } },
        @{N = (T 'col.requirement'); E = { $_.Requirement } },
        @{N = (T 'col.priority');    E = { $_.PrioriteLibelle } },
        @{N = (T 'col.status');      E = { $_.StatutLibelle } },
        @{N = (T 'col.observed');    E = { $_.ValeurConstatee } },
        @{N = (T 'col.expected');    E = { $_.ValeurAttendue } },
        @{N = (T 'col.remediation'); E = { $_.ActionCorrective } },
        @{N = (T 'col.rationale');   E = { $_.Pourquoi } },
        @{N = (T 'col.howto');       E = { $_.Procedure } },
        @{N = (T 'col.command');     E = { $_.CommandeVerification } },
        @{N = (T 'col.reference');   E = { $_.Reference } }

    # La mise en forme conditionnelle porte sur le libelle affiche, donc localise.
    $conditions = @(
        New-ConditionalText -Text (T 'status.NonCompliant') -BackgroundColor '#F8CBAD' -ConditionalTextColor '#843C0C'
        New-ConditionalText -Text (T 'status.Compliant')    -BackgroundColor '#C6EFCE' -ConditionalTextColor '#006100'
        New-ConditionalText -Text (T 'status.Warning')      -BackgroundColor '#FFEB9C' -ConditionalTextColor '#9C6500'
        New-ConditionalText -Text (T 'status.Manual')       -BackgroundColor '#DDEBF7' -ConditionalTextColor '#1F4E78'
        New-ConditionalText -Text (T 'status.NotEvaluated') -BackgroundColor '#E7E6E6' -ConditionalTextColor '#595959'
    )

    $excel = $checklist | Export-Excel -Path $Path -WorksheetName $sheetChecklist -AutoSize -BoldTopRow `
        -FreezeTopRow -AutoFilter -ConditionalText $conditions -PassThru

    $ws = $excel.Workbook.Worksheets[$sheetChecklist]
    $ws.Column(4).Width = 55   # exigence
    $ws.Column(7).Width = 55   # valeur constatee
    $ws.Column(8).Width = 45   # valeur attendue
    $ws.Column(9).Width = 55   # action corrective
    $ws.Column(10).Width = 70  # pourquoi
    $ws.Column(11).Width = 60  # procedure
    $ws.Column(12).Width = 55  # commande
    $ws.Column(13).Width = 50  # reference
    foreach ($c in 4, 7, 8, 9, 10, 11, 12) {
        $ws.Column($c).Style.WrapText = $true
        $ws.Column($c).Style.VerticalAlignment = 'Top'
    }
    Close-ExcelPackage $excel

    # ---------- Onglet Preuves ----------
    $Results | Select-Object `
        @{N = (T 'col.id');          E = { $_.Id } },
        @{N = (T 'col.section');     E = { $_.Section } },
        @{N = (T 'col.requirement'); E = { $_.Requirement } },
        @{N = (T 'col.status');      E = { $_.StatutLibelle } },
        @{N = (T 'col.evidence');    E = { $_.Preuve } } |
        Export-Excel -Path $Path -WorksheetName $sheetEvidence -AutoSize -BoldTopRow -FreezeTopRow -AutoFilter

    # ---------- Onglet Journal ----------
    if ($Context.Log.Count -gt 0) {
        $Context.Log | Select-Object `
            @{N = (T 'col.timestamp'); E = { $_.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } },
            @{N = (T 'col.level');     E = { $_.Level } },
            @{N = (T 'col.message');   E = { $_.Message } } |
            Export-Excel -Path $Path -WorksheetName $sheetLog -AutoSize -BoldTopRow -FreezeTopRow
    }

    Write-CceLog ((T 'cli.export.xlsx') -f $Path) -Level OK
    $Path
}
