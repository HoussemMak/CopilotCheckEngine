#Requires -Version 7.0
<# Export du rapport au format Excel (module ImportExcel). #>

function Get-CceStatistics {
    <#
    .SYNOPSIS
        Agrege les indicateurs consommes par les deux exports.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)] $Results)

    $all = @($Results)
    $byStatus = @{}
    foreach ($s in 'Conforme', 'Non conforme', 'Attention', 'Manuel', 'Non evalue') {
        $byStatus[$s] = @($all | Where-Object { $_.Statut -eq $s }).Count
    }

    $evaluables = $byStatus['Conforme'] + $byStatus['Non conforme'] + $byStatus['Attention']
    $rate = if ($evaluables -gt 0) { [math]::Round(100 * $byStatus['Conforme'] / $evaluables, 1) } else { 0 }

    $byPriority = foreach ($p in 'Bloquant', 'Recommande', 'Optimal') {
        $subset = @($all | Where-Object { $_.Priorite -eq $p })
        $ok = @($subset | Where-Object { $_.Statut -eq 'Conforme' }).Count
        $ko = @($subset | Where-Object { $_.Statut -eq 'Non conforme' }).Count
        $sub = @($subset | Where-Object { $_.Statut -in @('Conforme', 'Non conforme', 'Attention') }).Count

        [pscustomobject]@{
            Priorite     = $p
            Total        = $subset.Count
            Evaluables   = $sub
            Conforme     = $ok
            NonConforme  = $ko
            Attention    = @($subset | Where-Object { $_.Statut -eq 'Attention' }).Count
            Manuel       = @($subset | Where-Object { $_.Statut -eq 'Manuel' }).Count
            NonEvalue    = @($subset | Where-Object { $_.Statut -eq 'Non evalue' }).Count
            TauxPourcent = if ($sub -gt 0) { [math]::Round(100 * $ok / $sub, 1) } else { 0 }
        }
    }

    $bySection = foreach ($group in ($all | Group-Object Section)) {
        $ok = @($group.Group | Where-Object { $_.Statut -eq 'Conforme' }).Count
        $sub = @($group.Group | Where-Object { $_.Statut -in @('Conforme', 'Non conforme', 'Attention') }).Count

        [pscustomobject]@{
            Section      = $group.Name
            Total        = $group.Count
            Evaluables   = $sub
            Conforme     = $ok
            NonConforme  = @($group.Group | Where-Object { $_.Statut -eq 'Non conforme' }).Count
            Attention    = @($group.Group | Where-Object { $_.Statut -eq 'Attention' }).Count
            Manuel       = @($group.Group | Where-Object { $_.Statut -eq 'Manuel' }).Count
            NonEvalue    = @($group.Group | Where-Object { $_.Statut -eq 'Non evalue' }).Count
            TauxPourcent = if ($sub -gt 0) { [math]::Round(100 * $ok / $sub, 1) } else { 0 }
        }
    }

    [pscustomobject]@{
        Total           = $all.Count
        Conforme        = $byStatus['Conforme']
        NonConforme     = $byStatus['Non conforme']
        Attention       = $byStatus['Attention']
        Manuel          = $byStatus['Manuel']
        NonEvalue       = $byStatus['Non evalue']
        Evaluables      = $evaluables
        TauxConformite  = $rate
        ParPriorite     = @($byPriority)
        ParSection      = @($bySection)
        BloquantsKo     = @($all | Where-Object { $_.Priorite -eq 'Bloquant' -and $_.Statut -eq 'Non conforme' })
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

    # ---------- Onglet Synthese ----------
    $summary = [System.Collections.Generic.List[object]]::new()
    $add = { param($k, $v) $summary.Add([pscustomobject]@{ Indicateur = $k; Valeur = $v }) }

    & $add 'Tenant'                       $tenantLabel
    & $add 'Identifiant de tenant'        $Context.Tenant.Id
    & $add 'Domaine par defaut'           $Context.Tenant.DefaultDomain
    & $add 'Date d''execution'            $Context.StartedAt.ToString('yyyy-MM-dd HH:mm:ss')
    & $add 'Duree (secondes)'             ([math]::Round(((Get-Date) - $Context.StartedAt).TotalSeconds, 1))
    & $add ''                             ''
    & $add 'Configurations controlees'    $stats.Total
    & $add 'Conformes'                    $stats.Conforme
    & $add 'Non conformes'                $stats.NonConforme
    & $add 'Points d''attention'          $stats.Attention
    & $add 'Verification manuelle requise' $stats.Manuel
    & $add 'Non evalues'                  $stats.NonEvalue
    & $add ''                             ''
    & $add 'Base evaluable automatiquement' $stats.Evaluables
    & $add 'Taux de conformite (%)'       $stats.TauxConformite
    & $add 'Bloquants non conformes'      $stats.BloquantsKo.Count
    & $add ''                             ''

    foreach ($svc in $Context.Services.GetEnumerator()) {
        & $add ("Service : {0}" -f $svc.Key) $(if ($svc.Value) { 'Connecte' } else { 'Non connecte' })
    }

    $summary | Export-Excel -Path $Path -WorksheetName 'Synthese' -AutoSize -BoldTopRow `
        -Title "Microsoft 365 Copilot - Etat de configuration du tenant" -TitleBold -TitleSize 14

    $stats.ParPriorite | Export-Excel -Path $Path -WorksheetName 'Synthese' -StartRow ($summary.Count + 4) `
        -AutoSize -BoldTopRow -TableName 'ParPriorite' -TableStyle Medium2

    $stats.ParSection | Sort-Object Section | Export-Excel -Path $Path -WorksheetName 'Synthese' `
        -StartRow ($summary.Count + 4 + $stats.ParPriorite.Count + 3) `
        -AutoSize -BoldTopRow -TableName 'ParSection' -TableStyle Medium2

    # ---------- Onglet Checklist ----------
    $checklist = $Results | Select-Object `
        @{N = '#'; E = { $_.Id } },
        Section, Categorie,
        @{N = 'Configuration requise'; E = { $_.Requirement } },
        Priorite, Statut,
        @{N = 'Valeur constatee'; E = { $_.ValeurConstatee } },
        @{N = 'Valeur attendue'; E = { $_.ValeurAttendue } },
        @{N = 'Action corrective'; E = { $_.ActionCorrective } },
        @{N = 'Pourquoi'; E = { $_.Pourquoi } },
        @{N = 'Ou et comment configurer'; E = { $_.Procedure } },
        @{N = 'Commande de verification'; E = { $_.CommandeVerification } },
        @{N = 'Reference'; E = { $_.Reference } }

    $conditions = @(
        New-ConditionalText -Text 'Non conforme' -BackgroundColor '#F8CBAD' -ConditionalTextColor '#843C0C'
        New-ConditionalText -Text 'Conforme'     -BackgroundColor '#C6EFCE' -ConditionalTextColor '#006100'
        New-ConditionalText -Text 'Attention'    -BackgroundColor '#FFEB9C' -ConditionalTextColor '#9C6500'
        New-ConditionalText -Text 'Manuel'       -BackgroundColor '#DDEBF7' -ConditionalTextColor '#1F4E78'
        New-ConditionalText -Text 'Non evalue'   -BackgroundColor '#E7E6E6' -ConditionalTextColor '#595959'
    )

    $excel = $checklist | Export-Excel -Path $Path -WorksheetName 'Checklist' -AutoSize -BoldTopRow `
        -FreezeTopRow -AutoFilter -ConditionalText $conditions -PassThru

    $ws = $excel.Workbook.Worksheets['Checklist']
    $ws.Column(4).Width = 55   # Configuration requise
    $ws.Column(7).Width = 55   # Valeur constatee
    $ws.Column(8).Width = 45   # Valeur attendue
    $ws.Column(9).Width = 55   # Action corrective
    $ws.Column(10).Width = 70  # Pourquoi
    $ws.Column(11).Width = 60  # Procedure
    $ws.Column(12).Width = 55  # Commande
    $ws.Column(13).Width = 50  # Reference
    foreach ($c in 4, 7, 8, 9, 10, 11, 12) {
        $ws.Column($c).Style.WrapText = $true
        $ws.Column($c).Style.VerticalAlignment = 'Top'
    }
    Close-ExcelPackage $excel

    # ---------- Onglet Preuves ----------
    $Results | Select-Object `
        @{N = '#'; E = { $_.Id } }, Section,
        @{N = 'Configuration requise'; E = { $_.Requirement } },
        Statut,
        @{N = 'Preuve collectee'; E = { $_.Preuve } } |
        Export-Excel -Path $Path -WorksheetName 'Preuves' -AutoSize -BoldTopRow -FreezeTopRow -AutoFilter

    # ---------- Onglet Journal ----------
    if ($Context.Log.Count -gt 0) {
        $Context.Log | Select-Object @{N = 'Horodatage'; E = { $_.Timestamp.ToString('yyyy-MM-dd HH:mm:ss') } }, Level, Message |
            Export-Excel -Path $Path -WorksheetName 'Journal' -AutoSize -BoldTopRow -FreezeTopRow
    }

    Write-CceLog "Export Excel : $Path" -Level OK
    $Path
}
