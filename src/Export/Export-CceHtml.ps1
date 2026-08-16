#Requires -Version 7.0
<# Export du rapport au format HTML autonome (aucune dependance externe). #>

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
        Produit un rapport HTML autonome (filtres, recherche, impression).
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

    # --- Cartes d'indicateurs ---
    $kpis = @(
        @{ Label = T 'html.kpi.compliant';    Value = $stats.Conforme;    Slug = 'ok' }
        @{ Label = T 'html.kpi.noncompliant'; Value = $stats.NonConforme; Slug = 'ko' }
        @{ Label = T 'html.kpi.warning';      Value = $stats.Attention;   Slug = 'warn' }
        @{ Label = T 'html.kpi.manual';        Value = $stats.Manuel;        Slug = 'manual' }
        @{ Label = T 'html.kpi.notapplicable'; Value = $stats.NonApplicable; Slug = 'nap' }
        @{ Label = T 'html.kpi.notevaluated';  Value = $stats.NonEvalue;     Slug = 'na' }
    )

    $kpiHtml = ($kpis | ForEach-Object {
        "<div class=`"kpi kpi-$($_.Slug)`"><span class=`"kpi-value`">$($_.Value)</span><span class=`"kpi-label`">$(& $enc $_.Label)</span></div>"
    }) -join "`n"

    # --- Repartition par priorite ---
    $priorityHtml = ($stats.ParPriorite | ForEach-Object {
        $pct = $_.TauxPourcent
        $meta = (T 'html.bar.meta') -f $_.Conforme, $_.Evaluables, $pct, $_.Total
        @"
<div class="bar-row">
  <div class="bar-head"><span>$(& $enc $_.Libelle)</span><span class="bar-meta">$meta</span></div>
  <div class="bar"><div class="bar-fill" style="width:$pct%"></div></div>
</div>
"@
    }) -join "`n"

    # --- Repartition par domaine ---
    $sectionStatsHtml = ($stats.ParSection | Sort-Object Section | ForEach-Object {
        $pct = $_.TauxPourcent
        $meta = (T 'html.bar.metasection') -f $_.Conforme, $_.Evaluables, $pct, $_.Total
        @"
<div class="bar-row">
  <div class="bar-head"><span>$(& $enc $_.Section)</span><span class="bar-meta">$meta</span></div>
  <div class="bar"><div class="bar-fill" style="width:$pct%"></div></div>
</div>
"@
    }) -join "`n"

    # --- Etat des connexions ---
    $servicesHtml = ($Context.Services.GetEnumerator() | ForEach-Object {
        $cls = if ($_.Value) { 'svc-on' } else { 'svc-off' }
        $state = if ($_.Value) { T 'html.svc.on' } else { T 'html.svc.off' }
        "<span class=`"svc $cls`">$(& $enc ((T 'html.svc') -f $_.Key, $state))</span>"
    }) -join ' '

    # --- Detail des controles, groupes par domaine ---
    $sectionsHtml = [System.Collections.Generic.List[string]]::new()

    foreach ($group in ($Results | Group-Object Section)) {
        $rows = foreach ($r in ($group.Group | Sort-Object Id)) {
            $slug = Get-CceStatusSlug -Status $r.Statut
            $ref = if ($r.Reference) {
                "<a href=`"$(& $enc $r.Reference)`" target=`"_blank`" rel=`"noopener`">$(& $enc (T 'html.link.doc'))</a>"
            } else { '' }

            $remediation = if ($r.ActionCorrective) {
                "<div class=`"block block-fix`"><span class=`"block-title`">$(& $enc (T 'html.block.remediation'))</span>$(ConvertTo-CceHtmlEncoded $r.ActionCorrective)</div>"
            } else { '' }

            $evidence = if ($r.Preuve) {
                "<details class=`"evidence`"><summary>$(& $enc (T 'html.details.evidence'))</summary><pre>$(& $enc $r.Preuve)</pre></details>"
            } else { '' }

            $searchText = & $enc ("$($r.Id) $($r.Requirement) $($r.Categorie) $($r.ValeurConstatee)").ToLower()
            $unscored = if ($r.Notee -eq $false) { "<span class=`"tag tag-info`">$(& $enc (T 'html.badge.informational'))</span>" } else { '' }
            $licence = if ($r.LicenceRequise) { "<span class=`"tag tag-lic`">$(& $enc $r.LicenceRequise)</span>" } else { '' }

            @"
<article class="item" data-status="$slug" data-priority="$(& $enc $r.Priorite)" data-phase="$(& $enc $r.Phase)" data-text="$searchText">
  <header class="item-head">
    <span class="item-id">#$($r.Id)</span>
    <h3>$(& $enc $r.Requirement)</h3>
    <span class="badge badge-$slug">$(& $enc $r.StatutLibelle)</span>
    <span class="prio prio-$($r.Priorite.ToLower())">$(& $enc $r.PrioriteLibelle)</span>
    <span class="tag tag-phase">$(& $enc $r.PhaseLibelle)</span>
    $licence
    $unscored
  </header>
  <div class="item-body">
    <div class="block"><span class="block-title">$(& $enc (T 'html.block.observed'))</span>$(ConvertTo-CceHtmlEncoded $r.ValeurConstatee)</div>
    <div class="block"><span class="block-title">$(& $enc (T 'html.block.expected'))</span>$(ConvertTo-CceHtmlEncoded $r.ValeurAttendue)</div>
    $remediation
    $evidence
    <details class="more">
      <summary>$(& $enc (T 'html.details.more'))</summary>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.why'))</span>$(ConvertTo-CceHtmlEncoded $r.Pourquoi)</div>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.howto'))</span>$(ConvertTo-CceHtmlEncoded $r.Procedure)</div>
      <div class="block"><span class="block-title">$(& $enc (T 'html.block.command'))</span><code>$(& $enc $r.CommandeVerification)</code></div>
      <div class="block">$ref</div>
    </details>
  </div>
</article>
"@
        }

        $sectionsHtml.Add(@"
<section class="group">
  <h2>$(& $enc $group.Name) <span class="group-count">$($group.Count)</span></h2>
  $($rows -join "`n")
</section>
"@)
    }

    $css = @'
:root{
  --bg:#f5f6f8; --surface:#ffffff; --border:#e3e6ea; --text:#1c1f23; --muted:#5f6b7a;
  --ok:#1a7f4b; --ok-bg:#e6f4ec; --ko:#b42318; --ko-bg:#fdeceb; --warn:#a86a00; --warn-bg:#fdf3e0;
  --manual:#1f4e79; --manual-bg:#e8f0f9; --na:#5f6b7a; --na-bg:#eef0f2; --accent:#0f6cbd;
  --nap:#5b3fa8; --nap-bg:#efeaf9;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#14171a; --surface:#1c2126; --border:#2c333a; --text:#e8eaed; --muted:#9aa5b1;
    --ok:#4ade80; --ok-bg:#12291d; --ko:#f87171; --ko-bg:#2c1616; --warn:#fbbf24; --warn-bg:#2c2413;
    --manual:#7cc0f5; --manual-bg:#13232f; --na:#9aa5b1; --na-bg:#232a30; --accent:#4aa3f0;
    --nap:#b39ddb; --nap-bg:#241f33;
  }
}
*{box-sizing:border-box}
body{margin:0;padding:0;background:var(--bg);color:var(--text);
  font-family:"Segoe UI",-apple-system,BlinkMacSystemFont,Roboto,Helvetica,Arial,sans-serif;line-height:1.55}
.wrap{max-width:1180px;margin:0 auto;padding:28px 20px 64px}
header.top{border-bottom:2px solid var(--accent);padding-bottom:18px;margin-bottom:26px}
header.top h1{margin:0 0 6px;font-size:1.65rem;letter-spacing:-.01em}
.sub{color:var(--muted);font-size:.92rem}
.svc{display:inline-block;font-size:.76rem;padding:2px 9px;border-radius:999px;margin:6px 6px 0 0;border:1px solid var(--border)}
.svc-on{background:var(--ok-bg);color:var(--ok)} .svc-off{background:var(--na-bg);color:var(--na)}
.score{display:flex;flex-wrap:wrap;gap:22px;align-items:center;background:var(--surface);border:1px solid var(--border);
  border-radius:14px;padding:22px;margin-bottom:22px}
.gauge{width:132px;height:132px;border-radius:50%;display:grid;place-items:center;flex:none}
.gauge span{background:var(--surface);width:104px;height:104px;border-radius:50%;display:grid;place-items:center;
  font-size:1.55rem;font-weight:700}
.score-text{flex:1;min-width:230px}
.score-text h2{margin:0 0 4px;font-size:1.05rem}
.score-text p{margin:0;color:var(--muted);font-size:.9rem}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:22px}
.kpi{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px;border-left-width:4px}
.kpi-value{display:block;font-size:1.7rem;font-weight:700;line-height:1.1}
.kpi-label{display:block;font-size:.82rem;color:var(--muted)}
.kpi-ok{border-left-color:var(--ok)} .kpi-ko{border-left-color:var(--ko)} .kpi-warn{border-left-color:var(--warn)}
.kpi-manual{border-left-color:var(--manual)} .kpi-na{border-left-color:var(--na)}
.kpi-nap{border-left-color:var(--nap)}
.tag{font-size:.68rem;padding:2px 8px;border-radius:999px;background:var(--na-bg);color:var(--muted);white-space:nowrap}
.tag-lic{background:var(--nap-bg);color:var(--nap)}
.tag-info{background:var(--manual-bg);color:var(--manual);font-style:italic}
.panels{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;margin-bottom:26px}
.panel{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px}
.panel h2{margin:0 0 14px;font-size:1rem}
.bar-row{margin-bottom:12px}
.bar-head{display:flex;justify-content:space-between;font-size:.84rem;margin-bottom:4px;gap:12px}
.bar-meta{color:var(--muted);white-space:nowrap}
.bar-meta small{opacity:.7}
.bar{height:8px;background:var(--na-bg);border-radius:999px;overflow:hidden}
.bar-fill{height:100%;background:var(--accent);border-radius:999px}
.toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:20px;position:sticky;top:0;
  background:var(--bg);padding:10px 0;z-index:5}
.toolbar input{flex:1;min-width:200px;padding:9px 12px;border:1px solid var(--border);border-radius:8px;
  background:var(--surface);color:var(--text);font-size:.9rem}
.chip{padding:7px 13px;border:1px solid var(--border);border-radius:999px;background:var(--surface);color:var(--text);
  cursor:pointer;font-size:.82rem}
.chip.active{background:var(--accent);border-color:var(--accent);color:#fff}
.group{margin-bottom:30px}
.group h2{font-size:1.02rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);
  border-bottom:1px solid var(--border);padding-bottom:8px;margin:0 0 14px}
.group-count{background:var(--na-bg);color:var(--muted);border-radius:999px;padding:1px 9px;font-size:.75rem;margin-left:6px}
.item{background:var(--surface);border:1px solid var(--border);border-radius:12px;margin-bottom:12px;overflow:hidden}
.item-head{display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:14px 16px;border-bottom:1px solid var(--border)}
.item-head h3{margin:0;font-size:.97rem;font-weight:600;flex:1;min-width:200px}
.item-id{color:var(--muted);font-size:.8rem;font-variant-numeric:tabular-nums}
.badge{font-size:.76rem;font-weight:600;padding:3px 11px;border-radius:999px;white-space:nowrap}
.badge-ok{background:var(--ok-bg);color:var(--ok)} .badge-ko{background:var(--ko-bg);color:var(--ko)}
.badge-warn{background:var(--warn-bg);color:var(--warn)} .badge-manual{background:var(--manual-bg);color:var(--manual)}
.badge-na{background:var(--na-bg);color:var(--na)}
.badge-nap{background:var(--nap-bg);color:var(--nap)}
.prio{font-size:.72rem;color:var(--muted);border:1px solid var(--border);border-radius:999px;padding:2px 9px}
.prio-blocking{color:var(--ko);border-color:var(--ko)}
.item-body{padding:14px 16px;font-size:.9rem}
.block{margin-bottom:10px}
.block-title{display:block;font-size:.73rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin-bottom:2px}
.block-fix{background:var(--warn-bg);border-left:3px solid var(--warn);padding:9px 12px;border-radius:6px}
code{background:var(--na-bg);padding:2px 6px;border-radius:5px;font-size:.83rem;word-break:break-word;display:inline-block}
details{margin-top:8px}
summary{cursor:pointer;color:var(--accent);font-size:.86rem;font-weight:500}
pre{background:var(--na-bg);padding:11px 13px;border-radius:8px;overflow-x:auto;font-size:.8rem;white-space:pre-wrap;
  word-break:break-word;margin:8px 0 0}
a{color:var(--accent)}
footer{margin-top:36px;padding-top:16px;border-top:1px solid var(--border);color:var(--muted);font-size:.82rem}
.hidden{display:none !important}
@media print{
  .toolbar{display:none} .item{break-inside:avoid} details{display:block} details>summary{display:none}
  details>*{display:block !important} body{background:#fff}
}
'@

    $js = @'
(function () {
  var search = document.getElementById('search');
  var chips = Array.prototype.slice.call(document.querySelectorAll('.chip'));
  var items = Array.prototype.slice.call(document.querySelectorAll('.item'));

  var filters = { status: 'all', priority: 'all', phase: 'all' };

  function apply() {
    var q = (search.value || '').trim().toLowerCase();

    items.forEach(function (item) {
      var okStatus = filters.status === 'all' || item.dataset.status === filters.status;
      var okPrio = filters.priority === 'all' || item.dataset.priority === filters.priority;
      // 'both' reste visible quelle que soit la phase demandee : ces exigences
      // se verifient avant ET apres la mise en place.
      var okPhase = filters.phase === 'all' || item.dataset.phase === filters.phase ||
                    item.dataset.phase === 'both';
      var okText = q === '' || item.dataset.text.indexOf(q) !== -1;
      item.classList.toggle('hidden', !(okStatus && okPrio && okPhase && okText));
    });

    document.querySelectorAll('.group').forEach(function (group) {
      var visible = group.querySelectorAll('.item:not(.hidden)').length;
      group.classList.toggle('hidden', visible === 0);
    });
  }

  chips.forEach(function (chip) {
    chip.addEventListener('click', function () {
      var kind = chip.dataset.kind;
      chips.filter(function (c) { return c.dataset.kind === kind; })
           .forEach(function (c) { c.classList.remove('active'); });
      chip.classList.add('active');
      filters[kind] = chip.dataset.value;
      apply();
    });
  });

  search.addEventListener('input', apply);
})();
'@

    $rate = $stats.TauxConformite
    $gaugeColor = if ($rate -ge 80) { 'var(--ok)' } elseif ($rate -ge 50) { 'var(--warn)' } else { 'var(--ko)' }

    $gaugeText = (T 'html.gauge.text') -f $stats.Conforme, $stats.Evaluables, $stats.Total, $stats.Manuel, $stats.NonEvalue
    $gaugeBlocking = (T 'html.gauge.blocking') -f $stats.BloquantsKo.Count
    $footer = (T 'html.footer') -f $generated, (& $enc $Context.Config.CatalogTitle), (& $enc $Context.Config.CatalogVersion)

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
  <h1>$(T 'html.h1')</h1>
  <div class="sub">
    $(& $enc (T 'html.tenant')) <strong>$(& $enc $tenantLabel)</strong>
    &nbsp;&middot;&nbsp; $(& $enc $Context.Tenant.Id)
    &nbsp;&middot;&nbsp; $(& $enc ((T 'html.generated') -f $generated))
  </div>
  <div>$servicesHtml</div>
</header>

<div class="score">
  <div class="gauge" style="background:conic-gradient($gaugeColor $($rate * 3.6)deg, var(--na-bg) 0)"><span>$rate&nbsp;%</span></div>
  <div class="score-text">
    <h2>$(& $enc (T 'html.gauge.title'))</h2>
    <p>$(& $enc $gaugeText)</p>
    <p>$gaugeBlocking</p>
  </div>
</div>

<div class="kpis">$kpiHtml</div>

<div class="panels">
  <div class="panel"><h2>$(& $enc (T 'html.panel.priority'))</h2>$priorityHtml</div>
  <div class="panel"><h2>$(& $enc (T 'html.panel.section'))</h2>$sectionStatsHtml</div>
</div>

<div class="toolbar">
  <input id="search" type="search" placeholder="$(& $enc (T 'html.search'))">
  <button class="chip active" data-kind="status" data-value="all">$(& $enc (T 'html.chip.all'))</button>
  <button class="chip" data-kind="status" data-value="ko">$(& $enc (T 'status.NonCompliant'))</button>
  <button class="chip" data-kind="status" data-value="warn">$(& $enc (T 'status.Warning'))</button>
  <button class="chip" data-kind="status" data-value="ok">$(& $enc (T 'status.Compliant'))</button>
  <button class="chip" data-kind="status" data-value="manual">$(& $enc (T 'status.Manual'))</button>
  <button class="chip" data-kind="status" data-value="nap">$(& $enc (T 'status.NotApplicable'))</button>
  <button class="chip active" data-kind="priority" data-value="all">$(& $enc (T 'html.chip.allprio'))</button>
  <button class="chip" data-kind="priority" data-value="Blocking">$(& $enc (T 'priority.Blocking'))</button>
  <button class="chip" data-kind="priority" data-value="Recommended">$(& $enc (T 'priority.Recommended'))</button>
  <button class="chip active" data-kind="phase" data-value="all">$(& $enc (T 'html.chip.allphase'))</button>
  <button class="chip" data-kind="phase" data-value="pre-deployment">$(& $enc (T 'phase.pre-deployment'))</button>
  <button class="chip" data-kind="phase" data-value="post-deployment">$(& $enc (T 'phase.post-deployment'))</button>
</div>

$($sectionsHtml -join "`n")

<footer>$footer</footer>

</div>
<script>$js</script>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding utf8
    Write-CceLog ((T 'cli.export.html') -f $Path) -Level OK
    $Path
}
