#Requires -Version 7.0
<#
    Export du rapport au format HTML autonome (aucune dependance externe).

    PARTI PRIS
    Le rapport est consulte a l'ecran, souvent projete, et sert de support de travail
    aux equipes qui corrigent. Les memes regles que le classeur s'appliquent : la
    couleur porte une information, la hierarchie passe par la typographie et l'espace.
    S'y ajoute ce que le papier ne permet pas : filtrer, trier, chercher, et partager
    une vue filtree par son adresse.
#>

function ConvertTo-CceHtmlEncoded {
    [CmdletBinding()] param([AllowNull()] [string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    [System.Net.WebUtility]::HtmlEncode($Text) -replace '\r?\n', '<br>'
}

function Get-CceStatusSlug {
    <# Jeton canonique -> classe CSS. #>
    [CmdletBinding()] param([string] $Status)

    switch ($Status) {
        'Compliant'     { 'ok' }
        'NonCompliant'  { 'ko' }
        'Warning'       { 'warn' }
        'Manual'        { 'manual' }
        'NotApplicable' { 'nap' }
        default         { 'na' }
    }
}

function Export-CceHtml {
    <#
    .SYNOPSIS
        Produit un rapport HTML autonome : filtres, tri, recherche, impression.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Path
    )

    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string] $t) }

    $stats = Get-CceStatistics -Results $Results
    $tenantLabel = if ($Context.Tenant.Name) { $Context.Tenant.Name } else { $Context.Tenant.Id }
    $generated = $Context.StartedAt.ToString('dd/MM/yyyy HH:mm')

    # --- Indicateurs, cliquables : chaque carte est un filtre -------------
    $kpis = @(
        @{ Slug = 'ok';     Value = $stats.Conforme;      Label = T 'html.kpi.compliant' }
        @{ Slug = 'ko';     Value = $stats.NonConforme;   Label = T 'html.kpi.noncompliant' }
        @{ Slug = 'warn';   Value = $stats.Attention;     Label = T 'html.kpi.warning' }
        @{ Slug = 'manual'; Value = $stats.Manuel;        Label = T 'html.kpi.manual' }
        @{ Slug = 'nap';    Value = $stats.NonApplicable; Label = T 'html.kpi.notapplicable' }
        @{ Slug = 'na';     Value = $stats.NonEvalue;     Label = T 'html.kpi.notevaluated' }
    )

    $kpiHtml = ($kpis | ForEach-Object {
        @"
<button class="kpi kpi-$($_.Slug)" data-filter="$($_.Slug)" type="button">
  <span class="kpi-value">$($_.Value)</span>
  <span class="kpi-label">$(& $enc $_.Label)</span>
</button>
"@
    }) -join "`n"

    # --- Barre de repartition : la silhouette du tenant en un coup d'oeil --
    $legendTotal = [math]::Max(1, $stats.Notees)
    $legendHtml = ($kpis | Where-Object { $_.Value -gt 0 } | ForEach-Object {
        $pct = [math]::Round(100 * $_.Value / $legendTotal, 2)
        "<span class=`"seg seg-$($_.Slug)`" style=`"width:$pct%`" title=`"$(& $enc $_.Label) : $($_.Value)`"></span>"
    }) -join ''

    # --- Panneaux de repartition ------------------------------------------
    $barBlock = {
        param($Label, $Ok, $Base, $Pct, $Total, $Template)
        $meta = $Template -f $Ok, $Base, $Pct, $Total
        @"
<div class="bar-row">
  <div class="bar-head"><span class="bar-name">$(& $enc $Label)</span><span class="bar-meta">$meta</span></div>
  <div class="bar"><div class="bar-fill" style="width:$Pct%"></div></div>
</div>
"@
    }

    $phaseHtml = ($stats.ParPhase | ForEach-Object {
        & $barBlock $_.Libelle $_.Conforme $_.Evaluables $_.TauxPourcent $_.Total (T 'html.bar.meta')
    }) -join "`n"

    $priorityHtml = ($stats.ParPriorite | ForEach-Object {
        & $barBlock $_.Libelle $_.Conforme $_.Evaluables $_.TauxPourcent $_.Total (T 'html.bar.meta')
    }) -join "`n"

    # Les domaines les plus en retard en premier : c'est la que l'action porte.
    $sectionHtml = ($stats.ParSection | Sort-Object TauxPourcent | ForEach-Object {
        & $barBlock $_.Section $_.Conforme $_.Evaluables $_.TauxPourcent $_.Total (T 'html.bar.metasection')
    }) -join "`n"

    $servicesHtml = ($Context.Services.GetEnumerator() | ForEach-Object {
        $cls = if ($_.Value) { 'svc-on' } else { 'svc-off' }
        $state = if ($_.Value) { T 'html.svc.on' } else { T 'html.svc.off' }
        "<span class=`"svc $cls`">$(& $enc ((T 'html.svc') -f $_.Key, $state))</span>"
    }) -join ' '

    # --- Detail des controles ---------------------------------------------
    $priorityRank = @{ 'Blocking' = 0; 'Recommended' = 1; 'Optimal' = 2 }
    $statusRank = @{ 'NonCompliant' = 0; 'Warning' = 1; 'Manual' = 2; 'NotEvaluated' = 3; 'NotApplicable' = 4; 'Compliant' = 5 }

    $sectionsHtml = [System.Collections.Generic.List[string]]::new()
    $navHtml = [System.Collections.Generic.List[string]]::new()
    $index = 0

    foreach ($group in ($Results | Group-Object Section)) {
        $index++
        $anchor = "d$index"
        $navHtml.Add("<a class=`"nav-chip`" href=`"#$anchor`">$(& $enc $group.Name)</a>")

        $rows = foreach ($r in ($group.Group | Sort-Object Id)) {
            $slug = Get-CceStatusSlug -Status $r.Statut
            $pRank = if ($priorityRank.ContainsKey($r.Priorite)) { $priorityRank[$r.Priorite] } else { 9 }
            $sRank = if ($statusRank.ContainsKey($r.Statut)) { $statusRank[$r.Statut] } else { 9 }

            $ref = if ($r.Reference) {
                "<a class=`"doclink`" href=`"$(& $enc $r.Reference)`" target=`"_blank`" rel=`"noopener`">$(& $enc (T 'html.link.doc'))</a>"
            } else { '' }

            $remediation = if ($r.ActionCorrective) {
                @"
<div class="fix">
  <div class="fix-head">
    <span class="block-title">$(& $enc (T 'html.block.remediation'))</span>
    <button class="copy" type="button" data-copy="$(& $enc $r.ActionCorrective)">$(& $enc (T 'html.copy'))</button>
  </div>
  <div class="fix-body">$(ConvertTo-CceHtmlEncoded $r.ActionCorrective)</div>
</div>
"@
            } else { '' }

            $evidence = if ($r.Preuve) {
                "<details class=`"evidence`"><summary>$(& $enc (T 'html.details.evidence'))</summary><pre>$(& $enc $r.Preuve)</pre></details>"
            } else { '' }

            $tags = [System.Collections.Generic.List[string]]::new()
            $tags.Add("<span class=`"tag`">$(& $enc $r.PhaseLibelle)</span>")
            if ($r.LicenceRequise) { $tags.Add("<span class=`"tag tag-lic`">$(& $enc $r.LicenceRequise)</span>") }
            if ($r.Notee -eq $false) { $tags.Add("<span class=`"tag tag-info`">$(& $enc (T 'html.badge.informational'))</span>") }

            $searchText = & $enc ("$($r.Id) $($r.Requirement) $($r.Categorie) $($r.ValeurConstatee) $($r.Section)").ToLower()

            @"
<article class="item" data-status="$slug" data-priority="$(& $enc $r.Priorite)" data-phase="$(& $enc $r.Phase)"
         data-id="$($r.Id)" data-prank="$pRank" data-srank="$sRank" data-text="$searchText">
  <header class="item-head">
    <span class="dot dot-$slug" aria-hidden="true"></span>
    <span class="item-id">$($r.Id)</span>
    <h3>$(& $enc $r.Requirement)</h3>
    <span class="badge badge-$slug">$(& $enc $r.StatutLibelle)</span>
    <span class="prio prio-$($r.Priorite.ToLower())">$(& $enc $r.PrioriteLibelle)</span>
  </header>
  <div class="item-body">
    <div class="grid2">
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.observed'))</span><div>$(ConvertTo-CceHtmlEncoded $r.ValeurConstatee)</div></div>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.expected'))</span><div>$(ConvertTo-CceHtmlEncoded $r.ValeurAttendue)</div></div>
    </div>
    $remediation
    <div class="tags">$($tags -join '')</div>
    $evidence
    <details class="more">
      <summary>$(& $enc (T 'html.details.more'))</summary>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.why'))</span><div>$(ConvertTo-CceHtmlEncoded $r.Pourquoi)</div></div>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.howto'))</span><div>$(ConvertTo-CceHtmlEncoded $r.Procedure)</div></div>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.command'))</span><code>$(& $enc $r.CommandeVerification)</code></div>
      <div class="block">$ref</div>
    </details>
  </div>
</article>
"@
        }

        $sectionsHtml.Add(@"
<section class="group" id="$anchor">
  <h2><span>$(& $enc $group.Name)</span><span class="group-count">$($group.Count)</span></h2>
  <div class="group-items">
$($rows -join "`n")
  </div>
</section>
"@)
    }

    $rate = $stats.TauxConformite
    $ringLength = 326.7   # 2 * pi * 52
    $ringFill = [math]::Round($ringLength * $rate / 100, 1)
    $ringClass = if ($rate -ge 80) { 'ring-ok' } elseif ($rate -ge 50) { 'ring-warn' } else { 'ring-ko' }

    $gaugeText = (T 'html.gauge.text') -f $stats.Conforme, $stats.Evaluables, $stats.Total, $stats.Manuel, $stats.NonEvalue
    $gaugeBlocking = (T 'html.gauge.blocking') -f $stats.BloquantsKo.Count
    $footer = (T 'html.footer') -f $generated, (& $enc $Context.Config.CatalogTitle), (& $enc $Context.Config.CatalogVersion)

    $css = Get-CceHtmlStyle
    $js = Get-CceHtmlScript

    $html = @"
<!DOCTYPE html>
<html lang="$(Get-CceLanguage)">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $enc ((T 'html.title') -f $tenantLabel))</title>
<style>$css</style>
</head>
<body>
<div class="wrap">

<header class="top">
  <div class="top-main">
    <h1>$(T 'html.h1')</h1>
    <div class="sub">
      <strong>$(& $enc $tenantLabel)</strong>
      <span class="dotsep"></span>$(& $enc $Context.Tenant.Id)
      <span class="dotsep"></span>$(& $enc ((T 'html.generated') -f $generated))
    </div>
  </div>
  <div class="svcs">$servicesHtml</div>
</header>

<section class="hero">
  <div class="ring-wrap">
    <svg class="ring $ringClass" viewBox="0 0 120 120" role="img" aria-label="$rate %">
      <circle class="ring-bg" cx="60" cy="60" r="52"></circle>
      <circle class="ring-fg" cx="60" cy="60" r="52"
              stroke-dasharray="$ringFill $ringLength" transform="rotate(-90 60 60)"></circle>
      <text class="ring-val" x="60" y="62">$rate</text>
      <text class="ring-pct" x="60" y="78">%</text>
    </svg>
  </div>
  <div class="hero-text">
    <h2>$(& $enc (T 'html.gauge.title'))</h2>
    <p>$(& $enc $gaugeText)</p>
    <p class="blocking $(if ($stats.BloquantsKo.Count -gt 0) { 'blocking-on' } else { 'blocking-off' })">$gaugeBlocking</p>
    <div class="legend">
      <span class="legend-label">$(& $enc (T 'html.legend'))</span>
      <div class="segbar">$legendHtml</div>
    </div>
  </div>
</section>

<section class="kpis" aria-label="$(& $enc (T 'html.kpi.hint'))">$kpiHtml</section>

<section class="panels">
  <div class="panel"><h2>$(& $enc (T 'html.panel.priority'))</h2>$priorityHtml</div>
  <div class="panel"><h2>$(& $enc (T 'phase.both'))</h2>$phaseHtml</div>
  <div class="panel panel-wide"><h2>$(& $enc (T 'html.panel.section'))</h2>$sectionHtml</div>
</section>

<nav class="nav" aria-label="$(& $enc (T 'html.section.jump'))">$($navHtml -join '')</nav>

<div class="toolbar" id="toolbar">
  <div class="tb-row">
    <div class="search-wrap">
      <input id="search" type="search" placeholder="$(& $enc (T 'html.search'))" aria-label="$(& $enc (T 'html.search'))">
      <kbd>/</kbd>
    </div>
    <select id="sort" aria-label="$(& $enc (T 'html.sort.label'))">
      <option value="id">$(& $enc (T 'html.sort.id'))</option>
      <option value="prank">$(& $enc (T 'html.sort.priority'))</option>
      <option value="srank">$(& $enc (T 'html.sort.status'))</option>
    </select>
    <button class="btn" id="expand" type="button">$(& $enc (T 'html.toolbar.expand'))</button>
    <button class="btn" id="collapse" type="button">$(& $enc (T 'html.toolbar.collapse'))</button>
    <button class="btn" id="print" type="button">$(& $enc (T 'html.toolbar.print'))</button>
    <button class="btn btn-reset" id="reset" type="button">$(& $enc (T 'html.toolbar.reset'))</button>
  </div>
  <div class="tb-row chips">
    <button class="chip active" data-kind="status" data-value="all">$(& $enc (T 'html.chip.all'))</button>
    <button class="chip" data-kind="status" data-value="ko">$(& $enc (T 'status.NonCompliant'))</button>
    <button class="chip" data-kind="status" data-value="warn">$(& $enc (T 'status.Warning'))</button>
    <button class="chip" data-kind="status" data-value="ok">$(& $enc (T 'status.Compliant'))</button>
    <button class="chip" data-kind="status" data-value="manual">$(& $enc (T 'status.Manual'))</button>
    <button class="chip" data-kind="status" data-value="nap">$(& $enc (T 'status.NotApplicable'))</button>
    <span class="sep"></span>
    <button class="chip active" data-kind="priority" data-value="all">$(& $enc (T 'html.chip.allprio'))</button>
    <button class="chip" data-kind="priority" data-value="Blocking">$(& $enc (T 'priority.Blocking'))</button>
    <button class="chip" data-kind="priority" data-value="Recommended">$(& $enc (T 'priority.Recommended'))</button>
    <span class="sep"></span>
    <button class="chip active" data-kind="phase" data-value="all">$(& $enc (T 'html.chip.allphase'))</button>
    <button class="chip" data-kind="phase" data-value="pre-deployment">$(& $enc (T 'phase.pre-deployment'))</button>
    <button class="chip" data-kind="phase" data-value="post-deployment">$(& $enc (T 'phase.post-deployment'))</button>
  </div>
  <div class="tb-row"><span class="counter" id="counter"></span></div>
</div>

<div id="results">
$($sectionsHtml -join "`n")
</div>

<div class="empty" id="empty" hidden>
  <p class="empty-title">$(& $enc (T 'html.empty'))</p>
  <p>$(& $enc (T 'html.empty.hint'))</p>
</div>

<footer>$footer</footer>

</div>
<script>
window.CCE_I18N = {
  shown: $((T 'html.count.shown') | ConvertTo-Json),
  copied: $((T 'html.copied') | ConvertTo-Json),
  copy: $((T 'html.copy') | ConvertTo-Json)
};
$js
</script>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding utf8
    Write-CceLog ((T 'cli.export.html') -f $Path) -Level OK
    $Path
}

function Get-CceHtmlStyle {
    <# Feuille de style du rapport. Palette alignee sur celle du classeur Excel. #>
    [CmdletBinding()] param()

    @'
:root{
  --bg:#F7F8FA; --surface:#FFFFFF; --surface2:#FBFCFD; --border:#E5E7EB; --border2:#EFF1F4;
  --ink:#1B1F23; --muted:#6B7280; --accent:#0F6CBD;
  --ok:#0E6E3A; --ok-bg:#E8F5EE; --ko:#B32317; --ko-bg:#FDEDEB;
  --warn:#8A5300; --warn-bg:#FDF4E3; --manual:#2B579A; --manual-bg:#EAF0F9;
  --nap:#5B3FA8; --nap-bg:#F1EDFA; --na:#6B7280; --na-bg:#F3F4F6;
  --shadow:0 1px 2px rgba(16,24,40,.04), 0 1px 3px rgba(16,24,40,.06);
  --radius:12px;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#0F1215; --surface:#171B20; --surface2:#1C2126; --border:#272D34; --border2:#222831;
    --ink:#E8EAED; --muted:#9AA5B1; --accent:#4AA3F0;
    --ok:#4ADE80; --ok-bg:#10291D; --ko:#F87171; --ko-bg:#2C1616;
    --warn:#FBBF24; --warn-bg:#2C2413; --manual:#7CC0F5; --manual-bg:#132330;
    --nap:#B39DDB; --nap-bg:#231F33; --na:#9AA5B1; --na-bg:#222830;
    --shadow:0 1px 2px rgba(0,0,0,.4);
  }
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{
  margin:0;background:var(--bg);color:var(--ink);
  font-family:'Aptos','Segoe UI Variable Text','Segoe UI',system-ui,-apple-system,Roboto,sans-serif;
  font-size:15px;line-height:1.55;-webkit-font-smoothing:antialiased;
}
.wrap{max-width:1240px;margin:0 auto;padding:32px 24px 72px}

/* En-tete */
.top{display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:flex-start;
  padding-bottom:20px;margin-bottom:24px;border-bottom:1px solid var(--border)}
.top h1{margin:0 0 6px;font-size:1.6rem;font-weight:650;letter-spacing:-.02em}
.sub{color:var(--muted);font-size:.88rem}
.dotsep{display:inline-block;width:3px;height:3px;border-radius:50%;background:currentColor;
  margin:0 9px;vertical-align:middle;opacity:.6}
.svcs{display:flex;flex-wrap:wrap;gap:6px}
.svc{font-size:.72rem;padding:3px 10px;border-radius:99px;border:1px solid var(--border);white-space:nowrap}
.svc-on{background:var(--ok-bg);color:var(--ok);border-color:transparent}
.svc-off{background:var(--na-bg);color:var(--na);border-color:transparent}

/* Bandeau principal */
.hero{display:flex;flex-wrap:wrap;gap:28px;align-items:center;background:var(--surface);
  border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);padding:24px;margin-bottom:18px}
.ring-wrap{flex:none}
.ring{width:132px;height:132px}
.ring-bg{fill:none;stroke:var(--na-bg);stroke-width:10}
.ring-fg{fill:none;stroke-width:10;stroke-linecap:round;transition:stroke-dasharray .6s ease}
.ring-ok .ring-fg{stroke:var(--ok)} .ring-warn .ring-fg{stroke:var(--warn)} .ring-ko .ring-fg{stroke:var(--ko)}
.ring-val{font-size:30px;font-weight:700;text-anchor:middle;fill:var(--ink)}
.ring-pct{font-size:11px;text-anchor:middle;fill:var(--muted);letter-spacing:.08em}
.hero-text{flex:1;min-width:280px}
.hero-text h2{margin:0 0 6px;font-size:1.02rem;font-weight:600}
.hero-text p{margin:0 0 8px;color:var(--muted);font-size:.9rem}
.blocking{font-size:.92rem !important;padding:8px 12px;border-radius:8px;display:inline-block}
.blocking-on{background:var(--ko-bg);color:var(--ko) !important}
.blocking-off{background:var(--ok-bg);color:var(--ok) !important}
.legend{margin-top:14px}
.legend-label{display:block;font-size:.7rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);margin-bottom:6px}
.segbar{display:flex;height:10px;border-radius:99px;overflow:hidden;background:var(--na-bg)}
.seg{height:100%}
.seg-ok{background:var(--ok)} .seg-ko{background:var(--ko)} .seg-warn{background:var(--warn)}
.seg-manual{background:var(--manual)} .seg-nap{background:var(--nap)} .seg-na{background:var(--na);opacity:.45}

/* Indicateurs cliquables */
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:18px}
.kpi{display:flex;flex-direction:column;align-items:flex-start;gap:2px;background:var(--surface);
  border:1px solid var(--border);border-left:3px solid var(--na);border-radius:var(--radius);
  padding:14px 16px;cursor:pointer;font:inherit;text-align:left;box-shadow:var(--shadow);
  transition:transform .12s ease, box-shadow .12s ease}
.kpi:hover{transform:translateY(-1px);box-shadow:0 4px 12px rgba(16,24,40,.10)}
.kpi.on{outline:2px solid var(--accent);outline-offset:-2px}
.kpi-value{font-size:1.75rem;font-weight:700;line-height:1.1}
.kpi-label{font-size:.78rem;color:var(--muted)}
.kpi-ok{border-left-color:var(--ok)} .kpi-ok .kpi-value{color:var(--ok)}
.kpi-ko{border-left-color:var(--ko)} .kpi-ko .kpi-value{color:var(--ko)}
.kpi-warn{border-left-color:var(--warn)} .kpi-warn .kpi-value{color:var(--warn)}
.kpi-manual{border-left-color:var(--manual)} .kpi-manual .kpi-value{color:var(--manual)}
.kpi-nap{border-left-color:var(--nap)} .kpi-nap .kpi-value{color:var(--nap)}
.kpi-na{border-left-color:var(--na)} .kpi-na .kpi-value{color:var(--na)}

/* Panneaux */
.panels{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px;margin-bottom:22px}
.panel{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);
  padding:18px 20px;box-shadow:var(--shadow)}
.panel-wide{grid-column:1/-1}
.panel h2{margin:0 0 14px;font-size:.78rem;text-transform:uppercase;letter-spacing:.07em;color:var(--muted);font-weight:650}
.bar-row{margin-bottom:11px}
.bar-head{display:flex;justify-content:space-between;gap:14px;font-size:.83rem;margin-bottom:5px}
.bar-name{font-weight:500}
.bar-meta{color:var(--muted);white-space:nowrap;font-variant-numeric:tabular-nums}
.bar-meta small{opacity:.65}
.bar{height:6px;background:var(--na-bg);border-radius:99px;overflow:hidden}
.bar-fill{height:100%;background:var(--accent);border-radius:99px;transition:width .5s ease}

/* Navigation par domaine */
.nav{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:18px}
.nav-chip{font-size:.74rem;padding:4px 11px;border-radius:99px;background:var(--surface);
  border:1px solid var(--border);color:var(--muted);text-decoration:none;white-space:nowrap}
.nav-chip:hover{color:var(--accent);border-color:var(--accent)}

/* Barre d'outils */
.toolbar{position:sticky;top:0;z-index:20;background:var(--bg);padding:12px 0 10px;margin-bottom:14px;
  border-bottom:1px solid var(--border)}
.tb-row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px}
.tb-row:last-child{margin-bottom:0}
.search-wrap{position:relative;flex:1;min-width:220px}
.search-wrap input{width:100%;padding:9px 40px 9px 13px;border:1px solid var(--border);border-radius:9px;
  background:var(--surface);color:var(--ink);font:inherit;font-size:.88rem}
.search-wrap input:focus{outline:2px solid var(--accent);outline-offset:-1px;border-color:transparent}
.search-wrap kbd{position:absolute;right:10px;top:50%;transform:translateY(-50%);font-size:.68rem;
  color:var(--muted);border:1px solid var(--border);border-radius:4px;padding:1px 6px;background:var(--bg)}
select,.btn{font:inherit;font-size:.82rem;padding:8px 13px;border:1px solid var(--border);border-radius:9px;
  background:var(--surface);color:var(--ink);cursor:pointer}
.btn:hover{border-color:var(--accent);color:var(--accent)}
.btn-reset{color:var(--muted)}
.chip{font:inherit;font-size:.8rem;padding:6px 13px;border:1px solid var(--border);border-radius:99px;
  background:var(--surface);color:var(--ink);cursor:pointer;white-space:nowrap}
.chip:hover{border-color:var(--accent)}
.chip.active{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:500}
.chip .n{opacity:.65;margin-left:5px;font-variant-numeric:tabular-nums}
.sep{width:1px;height:20px;background:var(--border);margin:0 4px}
.counter{font-size:.78rem;color:var(--muted);font-variant-numeric:tabular-nums}

/* Groupes et exigences */
.group{margin-bottom:26px;scroll-margin-top:150px}
.group h2{display:flex;align-items:center;gap:8px;font-size:.8rem;text-transform:uppercase;letter-spacing:.07em;
  color:var(--muted);font-weight:650;margin:0 0 12px;padding-bottom:8px;border-bottom:1px solid var(--border)}
.group-count{background:var(--na-bg);color:var(--muted);border-radius:99px;padding:1px 9px;font-size:.7rem;letter-spacing:0}
.group-items{display:flex;flex-direction:column;gap:10px}
.item{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);
  overflow:hidden;box-shadow:var(--shadow)}
.item-head{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:13px 16px}
.dot{width:8px;height:8px;border-radius:50%;flex:none}
.dot-ok{background:var(--ok)} .dot-ko{background:var(--ko)} .dot-warn{background:var(--warn)}
.dot-manual{background:var(--manual)} .dot-nap{background:var(--nap)} .dot-na{background:var(--na)}
.item-id{color:var(--muted);font-size:.76rem;font-variant-numeric:tabular-nums;min-width:22px}
.item-head h3{margin:0;font-size:.95rem;font-weight:600;flex:1;min-width:200px;line-height:1.4}
.badge{font-size:.72rem;font-weight:600;padding:3px 10px;border-radius:99px;white-space:nowrap}
.badge-ok{background:var(--ok-bg);color:var(--ok)} .badge-ko{background:var(--ko-bg);color:var(--ko)}
.badge-warn{background:var(--warn-bg);color:var(--warn)} .badge-manual{background:var(--manual-bg);color:var(--manual)}
.badge-nap{background:var(--nap-bg);color:var(--nap)} .badge-na{background:var(--na-bg);color:var(--na)}
.prio{font-size:.7rem;color:var(--muted);border:1px solid var(--border);border-radius:99px;padding:2px 9px;white-space:nowrap}
.prio-blocking{color:var(--ko);border-color:var(--ko);font-weight:600}
.item-body{padding:0 16px 14px;font-size:.88rem;border-top:1px solid var(--border2)}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin:12px 0}
.block{margin-bottom:8px}
.block-title{display:block;font-size:.68rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:3px}
.fix{background:var(--warn-bg);border-left:3px solid var(--warn);border-radius:8px;padding:10px 13px;margin:10px 0}
.fix-head{display:flex;justify-content:space-between;align-items:center;gap:10px}
.copy{font:inherit;font-size:.7rem;padding:2px 9px;border:1px solid var(--border);border-radius:6px;
  background:var(--surface);color:var(--muted);cursor:pointer}
.copy:hover{color:var(--accent);border-color:var(--accent)}
.tags{display:flex;flex-wrap:wrap;gap:5px;margin:8px 0}
.tag{font-size:.68rem;padding:2px 9px;border-radius:99px;background:var(--na-bg);color:var(--muted)}
.tag-lic{background:var(--nap-bg);color:var(--nap)}
.tag-info{background:var(--manual-bg);color:var(--manual);font-style:italic}
code{background:var(--na-bg);padding:2px 7px;border-radius:5px;font-size:.8rem;word-break:break-word;
  display:inline-block;font-family:'Cascadia Mono',Consolas,monospace}
details{margin-top:8px}
summary{cursor:pointer;color:var(--accent);font-size:.82rem;font-weight:500;padding:3px 0}
summary:hover{text-decoration:underline}
pre{background:var(--surface2);border:1px solid var(--border2);padding:11px 13px;border-radius:8px;
  overflow-x:auto;font-size:.78rem;white-space:pre-wrap;word-break:break-word;margin:8px 0 0;
  font-family:'Cascadia Mono',Consolas,monospace}
.doclink{color:var(--accent);font-size:.82rem}

.empty{text-align:center;padding:60px 20px;color:var(--muted)}
.empty-title{font-size:1rem;color:var(--ink);font-weight:600;margin-bottom:4px}
footer{margin-top:34px;padding-top:16px;border-top:1px solid var(--border);color:var(--muted);font-size:.79rem}
.hidden{display:none !important}

@media (prefers-reduced-motion: reduce){*{transition:none !important;scroll-behavior:auto}}
@media print{
  .toolbar,.nav,.kpis button{display:none}
  .item{break-inside:avoid;box-shadow:none}
  details{display:block} details>summary{display:none} details>*{display:block !important}
  body{background:#fff;font-size:11px}
  .wrap{max-width:none;padding:0}
}
'@
}

function Get-CceHtmlScript {
    <# Comportement du rapport : filtres, tri, recherche, partage de vue. #>
    [CmdletBinding()] param()

    @'
(function () {
  var search = document.getElementById('search');
  var counter = document.getElementById('counter');
  var empty = document.getElementById('empty');
  var sortSel = document.getElementById('sort');
  var chips = [].slice.call(document.querySelectorAll('.chip'));
  var kpis = [].slice.call(document.querySelectorAll('.kpi'));
  var items = [].slice.call(document.querySelectorAll('.item'));
  var groups = [].slice.call(document.querySelectorAll('.group'));
  var total = items.length;

  var filters = { status: 'all', priority: 'all', phase: 'all', q: '' };

  function matches(item, f) {
    if (f.status !== 'all' && item.dataset.status !== f.status) return false;
    if (f.priority !== 'all' && item.dataset.priority !== f.priority) return false;
    // 'both' reste visible quelle que soit la phase demandee : ces exigences se
    // verifient avant ET apres la mise en place.
    if (f.phase !== 'all' && item.dataset.phase !== f.phase && item.dataset.phase !== 'both') return false;
    if (f.q && item.dataset.text.indexOf(f.q) === -1) return false;
    return true;
  }

  function apply() {
    var shown = 0;

    items.forEach(function (item) {
      var ok = matches(item, filters);
      item.classList.toggle('hidden', !ok);
      if (ok) shown++;
    });

    groups.forEach(function (g) {
      g.classList.toggle('hidden', g.querySelectorAll('.item:not(.hidden)').length === 0);
    });

    counter.textContent = (window.CCE_I18N.shown || '{0} / {1}')
      .replace('{0}', shown).replace('{1}', total);
    empty.hidden = shown !== 0;

    // Le compteur de chaque filtre se calcule sur les AUTRES criteres actifs :
    // il annonce ce que le clic donnerait, pas un total figé.
    chips.forEach(function (chip) {
      var kind = chip.dataset.kind, value = chip.dataset.value;
      var probe = Object.assign({}, filters);
      probe[kind] = value;
      var n = items.filter(function (i) { return matches(i, probe); }).length;
      var tag = chip.querySelector('.n');
      if (!tag) { tag = document.createElement('span'); tag.className = 'n'; chip.appendChild(tag); }
      tag.textContent = n;
      chip.disabled = n === 0 && value !== 'all';
      chip.style.opacity = chip.disabled ? .45 : 1;
    });

    kpis.forEach(function (k) { k.classList.toggle('on', filters.status === k.dataset.filter); });

    var hash = [];
    ['status', 'priority', 'phase'].forEach(function (k) {
      if (filters[k] !== 'all') hash.push(k + '=' + filters[k]);
    });
    if (filters.q) hash.push('q=' + encodeURIComponent(filters.q));
    history.replaceState(null, '', hash.length ? '#' + hash.join('&') : location.pathname);
  }

  function setFilter(kind, value) {
    filters[kind] = value;
    chips.filter(function (c) { return c.dataset.kind === kind; })
         .forEach(function (c) { c.classList.toggle('active', c.dataset.value === value); });
    apply();
  }

  chips.forEach(function (chip) {
    chip.addEventListener('click', function () { setFilter(chip.dataset.kind, chip.dataset.value); });
  });

  kpis.forEach(function (k) {
    k.addEventListener('click', function () {
      // Un second clic sur l'indicateur deja actif retire le filtre.
      setFilter('status', filters.status === k.dataset.filter ? 'all' : k.dataset.filter);
      document.getElementById('toolbar').scrollIntoView({ block: 'start' });
    });
  });

  search.addEventListener('input', function () {
    filters.q = search.value.trim().toLowerCase();
    apply();
  });

  sortSel.addEventListener('change', function () {
    var key = sortSel.value;
    groups.forEach(function (g) {
      var box = g.querySelector('.group-items');
      [].slice.call(box.children)
        .sort(function (a, b) {
          var x = parseInt(a.dataset[key], 10), y = parseInt(b.dataset[key], 10);
          return x !== y ? x - y : parseInt(a.dataset.id, 10) - parseInt(b.dataset.id, 10);
        })
        .forEach(function (n) { box.appendChild(n); });
    });
  });

  function toggleAll(open) {
    document.querySelectorAll('.item details').forEach(function (d) { d.open = open; });
  }
  document.getElementById('expand').addEventListener('click', function () { toggleAll(true); });
  document.getElementById('collapse').addEventListener('click', function () { toggleAll(false); });
  document.getElementById('print').addEventListener('click', function () { window.print(); });

  document.getElementById('reset').addEventListener('click', function () {
    search.value = '';
    filters = { status: 'all', priority: 'all', phase: 'all', q: '' };
    ['status', 'priority', 'phase'].forEach(function (k) {
      chips.filter(function (c) { return c.dataset.kind === k; })
           .forEach(function (c) { c.classList.toggle('active', c.dataset.value === 'all'); });
    });
    apply();
  });

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.copy');
    if (!btn) return;
    navigator.clipboard.writeText(btn.dataset.copy).then(function () {
      btn.textContent = window.CCE_I18N.copied;
      setTimeout(function () { btn.textContent = window.CCE_I18N.copy; }, 1600);
    });
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === '/' && document.activeElement !== search) { e.preventDefault(); search.focus(); }
    if (e.key === 'Escape' && document.activeElement === search) { search.value = ''; filters.q = ''; apply(); search.blur(); }
  });

  // Une vue filtree se partage par son adresse.
  if (location.hash.length > 1) {
    location.hash.slice(1).split('&').forEach(function (pair) {
      var kv = pair.split('=');
      if (kv[0] === 'q') { search.value = decodeURIComponent(kv[1]); filters.q = search.value.toLowerCase(); }
      else if (filters.hasOwnProperty(kv[0])) { filters[kv[0]] = kv[1]; }
    });
    ['status', 'priority', 'phase'].forEach(function (k) {
      chips.filter(function (c) { return c.dataset.kind === k; })
           .forEach(function (c) { c.classList.toggle('active', c.dataset.value === filters[k]); });
    });
  }

  apply();
})();
'@
}
