#Requires -Version 7.0
<#
    Export du rapport au format Excel (module ImportExcel).

    Toute la logique raisonne sur les jetons canoniques (Compliant, Blocking, ...)
    et n'utilise les libelles localises qu'au moment de l'ecriture.

    PARTI PRIS DE MISE EN FORME
    Le classeur est un livrable client, lu en reunion et projete. Trois regles :
      - la couleur porte une information, jamais une decoration. Le statut colore la
        seule cellule de statut, pas la ligne entiere : une page couverte d'aplats
        empeche de voir ce qui compte ;
      - la hierarchie passe par la typographie et l'espace, pas par les bordures ;
      - les colonnes explicatives sont regroupees et repliees. Elles restent
        disponibles d'un clic sans encombrer la lecture courante.
#>

# Palette sobre. Les teintes de statut sont des fonds tres clairs associes a un
# texte fonce du meme ton : lisible a l'ecran comme a l'impression noir et blanc.
function ConvertTo-CceXlColor {
    <#
    .SYNOPSIS
        Convertit une couleur hexadecimale en System.Drawing.Color.
    .DESCRIPTION
        Set-ExcelRange transmet la valeur directement a SetColor, qui n'accepte pas
        de chaine : la conversion doit etre faite en amont, une seule fois.
    #>
    [CmdletBinding()] [OutputType([System.Drawing.Color])]
    param([Parameter(Mandatory)] [string] $Hex)

    [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

$script:CceXl = @{
    Ink        = ConvertTo-CceXlColor '#1B1F23'   # texte principal
    Muted      = ConvertTo-CceXlColor '#6B7280'   # texte secondaire
    Rule       = ConvertTo-CceXlColor '#E5E7EB'   # filets
    Band       = ConvertTo-CceXlColor '#F3F4F6'   # bandeaux de section
    Paper      = ConvertTo-CceXlColor '#FFFFFF'
    Accent     = ConvertTo-CceXlColor '#0F6CBD'   # bleu Microsoft, employe avec parcimonie
    AccentSoft = ConvertTo-CceXlColor '#EAF2FB'

    OkText     = ConvertTo-CceXlColor '#0E6E3A'; OkFill   = ConvertTo-CceXlColor '#E8F5EE'
    KoText     = ConvertTo-CceXlColor '#B32317'; KoFill   = ConvertTo-CceXlColor '#FDEDEB'
    WarnText   = ConvertTo-CceXlColor '#8A5300'; WarnFill = ConvertTo-CceXlColor '#FDF4E3'
    ManText    = ConvertTo-CceXlColor '#2B579A'; ManFill  = ConvertTo-CceXlColor '#EAF0F9'
    NapText    = ConvertTo-CceXlColor '#5B3FA8'; NapFill  = ConvertTo-CceXlColor '#F1EDFA'
    NaText     = ConvertTo-CceXlColor '#6B7280'; NaFill   = ConvertTo-CceXlColor '#F3F4F6'
}

# Aptos est la police par defaut d'Office depuis 2024 ; Segoe UI prend le relais
# sur un poste plus ancien, et Excel retombe seul sur Calibri si aucune n'existe.
$script:CceXlFont = 'Aptos'
$script:CceXlFontDisplay = 'Aptos Display'

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
    $evaluableTokens = $script:CceScorableStatus

    # Une exigence hors score (depreciee, informative, en preversion) reste dans le
    # rapport mais ne pese ni au numerateur ni au denominateur.
    $scored = @($all | Where-Object { $_.Notee -ne $false })
    $unscored = @($all | Where-Object { $_.Notee -eq $false })

    $byStatus = @{}
    foreach ($s in $script:CceStatusOrder) {
        $byStatus[$s] = @($scored | Where-Object { $_.Statut -eq $s }).Count
    }

    $evaluables = $byStatus['Compliant'] + $byStatus['NonCompliant'] + $byStatus['Warning']
    $rate = if ($evaluables -gt 0) { [math]::Round(100 * $byStatus['Compliant'] / $evaluables, 1) } else { 0 }

    $byPhase = foreach ($ph in @('pre-deployment', 'post-deployment', 'both')) {
        $subset = @($scored | Where-Object { $_.Phase -eq $ph })
        $ok = @($subset | Where-Object { $_.Statut -eq 'Compliant' }).Count
        $sub = @($subset | Where-Object { $_.Statut -in $evaluableTokens }).Count

        [pscustomobject]@{
            Phase        = $ph
            Libelle      = T "phase.$ph"
            Total        = $subset.Count
            Evaluables   = $sub
            Conforme     = $ok
            NonConforme  = @($subset | Where-Object { $_.Statut -eq 'NonCompliant' }).Count
            TauxPourcent = if ($sub -gt 0) { [math]::Round(100 * $ok / $sub, 1) } else { 0 }
        }
    }

    $byPriority = foreach ($p in $script:CcePriorityOrder) {
        $subset = @($scored | Where-Object { $_.Priorite -eq $p })
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

    $bySection = foreach ($group in ($scored | Group-Object Section)) {
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
        Notees         = $scored.Count
        HorsScore      = $unscored.Count
        Conforme       = $byStatus['Compliant']
        NonConforme    = $byStatus['NonCompliant']
        Attention      = $byStatus['Warning']
        Manuel         = $byStatus['Manual']
        NonEvalue      = $byStatus['NotEvaluated']
        NonApplicable  = $byStatus['NotApplicable']
        Evaluables     = $evaluables
        TauxConformite = $rate
        ParPhase       = @($byPhase)
        ParPriorite    = @($byPriority)
        ParSection     = @($bySection)
        BloquantsKo    = @($scored | Where-Object { $_.Priorite -eq 'Blocking' -and $_.Statut -eq 'NonCompliant' })
        NonApplicables = @($scored | Where-Object { $_.Statut -eq 'NotApplicable' })
    }
}

function Set-CceXlBand {
    <# Bandeau de section : petite capitale espacee sur fond neutre. #>
    [CmdletBinding()]
    param($Worksheet, [string] $Range, [string] $Text)

    $Worksheet.Cells[$Range].Merge = $true
    $Worksheet.Cells[$Range].Value = $Text
    Set-ExcelRange -Worksheet $Worksheet -Range $Range -FontName $script:CceXlFont -FontSize 9 -Bold `
        -FontColor $script:CceXl.Muted -BackgroundColor $script:CceXl.Band -VerticalAlign Center -HorizontalAlignment Left
}

function Set-CceXlStatusFormat {
    <#
    .SYNOPSIS
        Colore la seule colonne de statut, jamais la ligne entiere.
    .DESCRIPTION
        Une ligne entierement teintee sature la page et rend le balayage plus difficile :
        l'oeil ne distingue plus les quatre cellules qui portent reellement l'information.
    #>
    [CmdletBinding()]
    param($Worksheet, [string] $Range)

    $map = @(
        @{ Text = T 'status.Compliant';     Fill = $script:CceXl.OkFill;   Font = $script:CceXl.OkText }
        @{ Text = T 'status.NonCompliant';  Fill = $script:CceXl.KoFill;   Font = $script:CceXl.KoText }
        @{ Text = T 'status.Warning';       Fill = $script:CceXl.WarnFill; Font = $script:CceXl.WarnText }
        @{ Text = T 'status.Manual';        Fill = $script:CceXl.ManFill;  Font = $script:CceXl.ManText }
        @{ Text = T 'status.NotApplicable'; Fill = $script:CceXl.NapFill;  Font = $script:CceXl.NapText }
        @{ Text = T 'status.NotEvaluated';  Fill = $script:CceXl.NaFill;   Font = $script:CceXl.NaText }
    )

    foreach ($entry in $map) {
        Add-ConditionalFormatting -Worksheet $Worksheet -Range $Range -RuleType Equal `
            -ConditionValue "`"$($entry.Text)`"" -BackgroundColor $entry.Fill -ForegroundColor $entry.Font -Bold
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

    # =====================================================================
    # Onglet Checklist : le plan de travail
    # =====================================================================
    $checklist = $Results | Select-Object `
        @{N = (T 'col.id');          E = { $_.Id } },
        @{N = (T 'col.section');     E = { $_.Section } },
        @{N = (T 'col.requirement'); E = { $_.Requirement } },
        @{N = (T 'col.status');      E = { $_.StatutLibelle } },
        @{N = (T 'col.priority');    E = { $_.PrioriteLibelle } },
        @{N = (T 'col.phase');       E = { $_.PhaseLibelle } },
        @{N = (T 'col.observed');    E = { $_.ValeurConstatee } },
        @{N = (T 'col.expected');    E = { $_.ValeurAttendue } },
        @{N = (T 'col.remediation'); E = { $_.ActionCorrective } },
        @{N = (T 'col.category');    E = { $_.Categorie } },
        @{N = (T 'col.mode');        E = { $_.Mode } },
        @{N = (T 'col.license');     E = { $_.LicenceRequise } },
        @{N = (T 'col.rationale');   E = { $_.Pourquoi } },
        @{N = (T 'col.howto');       E = { $_.Procedure } },
        @{N = (T 'col.command');     E = { $_.CommandeVerification } },
        @{N = (T 'col.reference');   E = { $_.Reference } }

    $excel = $checklist | Export-Excel -Path $Path -WorksheetName $sheetChecklist -PassThru `
        -StartRow 3 -TableName 'Checklist' -TableStyle Light1

    $ws = $excel.Workbook.Worksheets[$sheetChecklist]
    $rows = @($checklist).Count
    $lastRow = $rows + 3

    $ws.View.ShowGridLines = $false
    $ws.Cells.Style.Font.Name = $script:CceXlFont
    $ws.Cells.Style.Font.Size = 10

    # Titre de l'onglet
    $ws.Cells['A1'].Value = (T 'xlsx.sheet.checklist')
    Set-ExcelRange -Worksheet $ws -Range 'A1:D1' -FontName $script:CceXlFontDisplay -FontSize 14 -Bold -FontColor $script:CceXl.Ink
    $ws.Cells['G1'].Value = (T 'xlsx.hint.filter')
    Set-ExcelRange -Worksheet $ws -Range 'G1:P1' -FontSize 9 -FontColor $script:CceXl.Muted -WrapText
    $ws.Row(1).Height = 26
    $ws.Row(2).Height = 6

    # En-tetes
    Set-ExcelRange -Worksheet $ws -Range "A3:P3" -FontSize 9 -Bold -FontColor $script:CceXl.Paper `
        -BackgroundColor $script:CceXl.Ink -VerticalAlign Center -WrapText
    $ws.Row(3).Height = 30

    # Largeurs : l'information de decision devant, l'explicatif replie derriere.
    $widths = @{ 1 = 5; 2 = 26; 3 = 46; 4 = 15; 5 = 13; 6 = 15; 7 = 46; 8 = 34; 9 = 42; 10 = 14; 11 = 13; 12 = 16; 13 = 60; 14 = 50; 15 = 44; 16 = 34 }
    foreach ($k in $widths.Keys) { $ws.Column($k).Width = $widths[$k] }

    foreach ($c in 3, 7, 8, 9, 13, 14, 15, 16) {
        $ws.Column($c).Style.WrapText = $true
        $ws.Column($c).Style.VerticalAlignment = 'Top'
    }
    foreach ($c in 1, 4, 5, 6, 10, 11, 12) {
        $ws.Column($c).Style.HorizontalAlignment = 'Center'
        $ws.Column($c).Style.VerticalAlignment = 'Center'
    }

    # Les colonnes explicatives sont repliees : disponibles, mais hors du champ de lecture.
    foreach ($c in 13, 14, 15) { $ws.Column($c).OutlineLevel = 1; $ws.Column($c).Collapsed = $true }
    $ws.OutLineSummaryRight = $false

    Set-ExcelRange -Worksheet $ws -Range "A4:P$lastRow" -FontSize 9 -VerticalAlign Top
    Set-CceXlStatusFormat -Worksheet $ws -Range "D4:D$lastRow"

    # Le bloquant se signale par la typographie, pas par un aplat de plus.
    Add-ConditionalFormatting -Worksheet $ws -Range "E4:E$lastRow" -RuleType Equal `
        -ConditionValue "`"$(T 'priority.Blocking')`"" -ForegroundColor $script:CceXl.KoText -Bold

    $ws.View.FreezePanes(4, 4)

    # =====================================================================
    # Onglet Preuves
    # =====================================================================
    $Results | Select-Object `
        @{N = (T 'col.id');          E = { $_.Id } },
        @{N = (T 'col.section');     E = { $_.Section } },
        @{N = (T 'col.requirement'); E = { $_.Requirement } },
        @{N = (T 'col.status');      E = { $_.StatutLibelle } },
        @{N = (T 'col.evidence');    E = { $_.Preuve } } |
        Export-Excel -ExcelPackage $excel -WorksheetName $sheetEvidence -TableName 'Preuves' -TableStyle Light1 -PassThru | Out-Null

    $wsE = $excel.Workbook.Worksheets[$sheetEvidence]
    $wsE.View.ShowGridLines = $false
    $wsE.Cells.Style.Font.Name = $script:CceXlFont
    $wsE.Cells.Style.Font.Size = 9
    Set-ExcelRange -Worksheet $wsE -Range 'A1:E1' -FontSize 9 -Bold -FontColor $script:CceXl.Paper `
        -BackgroundColor $script:CceXl.Ink -VerticalAlign Center
    $wsE.Row(1).Height = 24
    $evidenceWidths = @(6, 26, 44, 15, 96)
    for ($i = 0; $i -lt $evidenceWidths.Count; $i++) { $wsE.Column($i + 1).Width = $evidenceWidths[$i] }
    foreach ($c in 3, 5) { $wsE.Column($c).Style.WrapText = $true; $wsE.Column($c).Style.VerticalAlignment = 'Top' }
    Set-CceXlStatusFormat -Worksheet $wsE -Range "D2:D$(@($Results).Count + 1)"
    $wsE.View.FreezePanes(2, 1)

    # =====================================================================
    # Onglet Journal
    # =====================================================================
    if ($Context.Log.Count -gt 0) {
        $Context.Log | Select-Object `
            @{N = (T 'col.timestamp'); E = { $_.Timestamp.ToString('HH:mm:ss') } },
            @{N = (T 'col.level');     E = { $_.Level } },
            @{N = (T 'col.message');   E = { $_.Message } } |
            Export-Excel -ExcelPackage $excel -WorksheetName $sheetLog -TableName 'Journal' -TableStyle Light1 -PassThru | Out-Null

        $wsL = $excel.Workbook.Worksheets[$sheetLog]
        $wsL.View.ShowGridLines = $false
        $wsL.Cells.Style.Font.Name = $script:CceXlFont
        $wsL.Cells.Style.Font.Size = 9
        Set-ExcelRange -Worksheet $wsL -Range 'A1:C1' -FontSize 9 -Bold -FontColor $script:CceXl.Paper `
            -BackgroundColor $script:CceXl.Ink -VerticalAlign Center
        $wsL.Column(1).Width = 11; $wsL.Column(2).Width = 10; $wsL.Column(3).Width = 130
        $wsL.Column(3).Style.WrapText = $true
        $wsL.View.FreezePanes(2, 1)
    }

    # =====================================================================
    # Onglet Synthese : tableau de bord, place en tete
    # =====================================================================
    Add-CceSummarySheet -Excel $excel -Stats $stats -Context $Context -Tenant $tenantLabel -SheetName $sheetSummary
    $excel.Workbook.Worksheets.MoveToStart($sheetSummary)

    Close-ExcelPackage $excel

    Write-CceLog ((T 'cli.export.xlsx') -f $Path) -Level OK
    $Path
}

function Add-CceSummarySheet {
    <#
    .SYNOPSIS
        Tableau de bord : indicateurs, taux, repartitions et graphique.
    #>
    [CmdletBinding()]
    param($Excel, $Stats, $Context, [string] $Tenant, [string] $SheetName)

    $ws = Add-Worksheet -ExcelPackage $Excel -WorksheetName $SheetName
    $ws.View.ShowGridLines = $false
    $ws.Cells.Style.Font.Name = $script:CceXlFont
    $ws.Cells.Style.Font.Size = 10

    $ws.Column(1).Width = 2
    foreach ($c in 2..7) { $ws.Column($c).Width = 21 }
    $ws.Column(8).Width = 2

    # --- Titre -----------------------------------------------------------
    $ws.Row(1).Height = 10
    $ws.Cells['B2:G2'].Merge = $true
    $ws.Cells['B2'].Value = (T 'xlsx.title')
    Set-ExcelRange -Worksheet $ws -Range 'B2:G2' -FontName $script:CceXlFontDisplay -FontSize 18 -Bold -FontColor $script:CceXl.Ink
    $ws.Row(2).Height = 30

    $ws.Cells['B3:G3'].Merge = $true
    $ws.Cells['B3'].Value = (T 'xlsx.sub') -f $Tenant, $Context.Tenant.Id,
        $Context.StartedAt.ToString('dd/MM/yyyy HH:mm'), (Get-CceLanguage).ToUpper()
    Set-ExcelRange -Worksheet $ws -Range 'B3:G3' -FontSize 9 -FontColor $script:CceXl.Muted
    $ws.Row(3).Height = 16
    $ws.Row(4).Height = 12

    # --- Taux de conformite ---------------------------------------------
    $rateColour = if ($Stats.TauxConformite -ge 80) { $script:CceXl.OkText }
                  elseif ($Stats.TauxConformite -ge 50) { $script:CceXl.WarnText }
                  else { $script:CceXl.KoText }

    $ws.Cells['B5:C6'].Merge = $true
    $ws.Cells['B5'].Value = "$($Stats.TauxConformite) %"
    Set-ExcelRange -Worksheet $ws -Range 'B5:C6' -FontName $script:CceXlFontDisplay -FontSize 34 -Bold `
        -FontColor $rateColour -VerticalAlign Center -HorizontalAlignment Left

    $ws.Cells['D5:G5'].Merge = $true
    $ws.Cells['D5'].Value = (T 'xlsx.rate.label')
    Set-ExcelRange -Worksheet $ws -Range 'D5:G5' -FontSize 9 -Bold -FontColor $script:CceXl.Muted -VerticalAlign Bottom

    $ws.Cells['D6:G6'].Merge = $true
    $ws.Cells['D6'].Value = (T 'xlsx.rate.base') -f $Stats.Evaluables
    Set-ExcelRange -Worksheet $ws -Range 'D6:G6' -FontSize 10 -FontColor $script:CceXl.Ink -VerticalAlign Top
    $ws.Row(5).Height = 30
    $ws.Row(6).Height = 24

    # Bloquants : la seule alerte qui merite un aplat sur cette page.
    $ws.Cells['B7:G7'].Merge = $true
    $ws.Cells['B7'].Value = "  $($Stats.BloquantsKo.Count)   $(T 'xlsx.blocking.label')"
    $blockFill = if ($Stats.BloquantsKo.Count -gt 0) { $script:CceXl.KoFill } else { $script:CceXl.OkFill }
    $blockText = if ($Stats.BloquantsKo.Count -gt 0) { $script:CceXl.KoText } else { $script:CceXl.OkText }
    Set-ExcelRange -Worksheet $ws -Range 'B7:G7' -FontSize 11 -Bold -FontColor $blockText `
        -BackgroundColor $blockFill -VerticalAlign Center
    $ws.Row(7).Height = 26
    $ws.Row(8).Height = 12

    # --- Indicateurs -----------------------------------------------------
    Set-CceXlBand -Worksheet $ws -Range 'B9:G9' -Text (T 'xlsx.band.indicators')
    $ws.Row(9).Height = 20

    $kpis = @(
        @{ V = $Stats.Conforme;      L = T 'sum.compliant';     C = $script:CceXl.OkText }
        @{ V = $Stats.NonConforme;   L = T 'sum.noncompliant';  C = $script:CceXl.KoText }
        @{ V = $Stats.Attention;     L = T 'sum.warning';       C = $script:CceXl.WarnText }
        @{ V = $Stats.Manuel;        L = T 'sum.manual';        C = $script:CceXl.ManText }
        @{ V = $Stats.NonApplicable; L = T 'sum.notapplicable'; C = $script:CceXl.NapText }
        @{ V = $Stats.NonEvalue;     L = T 'sum.notevaluated';  C = $script:CceXl.NaText }
    )

    $col = 2
    foreach ($kpi in $kpis) {
        $letter = [char](64 + $col)
        $ws.Cells["$letter`10"].Value = $kpi.V
        Set-ExcelRange -Worksheet $ws -Range "$letter`10" -FontName $script:CceXlFontDisplay -FontSize 22 -Bold `
            -FontColor $kpi.C -HorizontalAlignment Center -VerticalAlign Bottom
        $ws.Cells["$letter`11"].Value = $kpi.L
        Set-ExcelRange -Worksheet $ws -Range "$letter`11" -FontSize 8 -FontColor $script:CceXl.Muted `
            -HorizontalAlignment Center -VerticalAlign Top -WrapText
        $col++
    }
    $ws.Row(10).Height = 30
    $ws.Row(11).Height = 24
    $ws.Row(12).Height = 12

    # --- Repartitions ----------------------------------------------------
    $row = 13
    $row = Add-CceSummaryTable -Worksheet $ws -Row $row -Band (T 'xlsx.band.phase') `
        -Items $Stats.ParPhase -KeyProperty 'Libelle'

    $row = Add-CceSummaryTable -Worksheet $ws -Row $row -Band (T 'xlsx.band.priority') `
        -Items $Stats.ParPriorite -KeyProperty 'Libelle'

    $sections = @($Stats.ParSection | Sort-Object TauxPourcent)
    $sectionStart = $row + 1
    $row = Add-CceSummaryTable -Worksheet $ws -Row $row -Band (T 'xlsx.band.domain') `
        -Items $sections -KeyProperty 'Section'

    # --- Services --------------------------------------------------------
    $row++
    Set-CceXlBand -Worksheet $ws -Range "B$row`:G$row" -Text (T 'xlsx.band.services')
    $ws.Row($row).Height = 20
    $row++

    $col = 2
    foreach ($svc in $Context.Services.GetEnumerator()) {
        $letter = [char](64 + $col)
        $ws.Cells["$letter$row"].Value = $svc.Key
        $on = [bool] $svc.Value
        Set-ExcelRange -Worksheet $ws -Range "$letter$row" -FontSize 9 -Bold `
            -FontColor $(if ($on) { $script:CceXl.OkText } else { $script:CceXl.NaText }) `
            -BackgroundColor $(if ($on) { $script:CceXl.OkFill } else { $script:CceXl.NaFill }) `
            -HorizontalAlignment Center
        $col++
        if ($col -gt 7) { $col = 2; $row++ }
    }

    # --- Graphique : les domaines les plus en retard en premier ----------
    $chart = New-ExcelChartDefinition -ChartType BarClustered -Title (T 'xlsx.chart.domain') `
        -XRange "'$SheetName'!B$sectionStart`:B$($sectionStart + $sections.Count - 1)" `
        -YRange "'$SheetName'!D$sectionStart`:D$($sectionStart + $sections.Count - 1)" `
        -Width 520 -Height (60 + 26 * $sections.Count) -Row 4 -Column 8 -NoLegend

    Export-Excel -ExcelPackage $Excel -WorksheetName $SheetName -ExcelChartDefinition $chart -PassThru | Out-Null
}

function Add-CceSummaryTable {
    <#
    .SYNOPSIS
        Bloc de repartition : bandeau, en-tetes discrets, barre de progression par ligne.
    .OUTPUTS
        La ligne suivant le bloc.
    #>
    [CmdletBinding()]
    param($Worksheet, [int] $Row, [string] $Band, $Items, [string] $KeyProperty)

    Set-CceXlBand -Worksheet $Worksheet -Range "B$Row`:G$Row" -Text $Band
    $Worksheet.Row($Row).Height = 20
    $Row++

    $headers = @((T 'col.total'), (T 'col.evaluable'), (T 'status.Compliant'), (T 'status.NonCompliant'), (T 'col.rate'))
    $col = 3
    foreach ($h in $headers) {
        $letter = [char](64 + $col)
        $Worksheet.Cells["$letter$Row"].Value = $h
        Set-ExcelRange -Worksheet $Worksheet -Range "$letter$Row" -FontSize 8 -Bold -FontColor $script:CceXl.Muted `
            -HorizontalAlignment Center -WrapText
        $col++
    }
    $Worksheet.Row($Row).Height = 22
    $Row++

    $first = $Row
    foreach ($item in @($Items)) {
        $Worksheet.Cells["B$Row"].Value = $item.$KeyProperty
        Set-ExcelRange -Worksheet $Worksheet -Range "B$Row" -FontSize 9 -FontColor $script:CceXl.Ink -VerticalAlign Center -WrapText

        $Worksheet.Cells["C$Row"].Value = $item.Total
        $Worksheet.Cells["D$Row"].Value = $item.Evaluables
        $Worksheet.Cells["E$Row"].Value = $item.Conforme
        $Worksheet.Cells["F$Row"].Value = $item.NonConforme
        $Worksheet.Cells["G$Row"].Value = $item.TauxPourcent / 100

        Set-ExcelRange -Worksheet $Worksheet -Range "C$Row`:F$Row" -FontSize 9 -HorizontalAlignment Center -VerticalAlign Center
        Set-ExcelRange -Worksheet $Worksheet -Range "G$Row" -FontSize 9 -NumberFormat '0.0 %' -HorizontalAlignment Center -VerticalAlign Center
        Set-ExcelRange -Worksheet $Worksheet -Range "B$Row`:G$Row" -BorderBottom Thin -BorderColor $script:CceXl.Rule
        $Worksheet.Row($Row).Height = 20
        $Row++
    }

    # La barre de donnees remplace un camembert : elle se lit dans la cellule meme.
    if ($Row -gt $first) {
        Add-ConditionalFormatting -Worksheet $Worksheet -Range "G$first`:G$($Row - 1)" `
            -DataBarColor $script:CceXl.Accent
    }

    $Row + 1
}
