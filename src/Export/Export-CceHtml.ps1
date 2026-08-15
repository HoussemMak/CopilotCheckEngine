#Requires -Version 7.0
<# Export du rapport au format HTML autonome (aucune dependance externe). #>

function ConvertTo-CceHtmlEncoded {
    [CmdletBinding()] param([AllowNull()] [string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    [System.Net.WebUtility]::HtmlEncode($Text) -replace '\r?\n', '<br>'
}

function Get-CceStatusSlug {
    [CmdletBinding()] param([string] $Status)

    switch ($Status) {
        'Conforme'     { 'ok' }
        'Non conforme' { 'ko' }
        'Attention'    { 'warn' }
        'Manuel'       { 'manual' }
        default        { 'na' }
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

    $stats = Get-CceStatistics -Results $Results
    $tenantLabel = if ($Context.Tenant.Name) { $Context.Tenant.Name } else { $Context.Tenant.Id }
    $generated = $Context.StartedAt.ToString('dd/MM/yyyy HH:mm')

    # --- Cartes d'indicateurs ---
    $kpis = @(
        @{ Label = 'Conformes';        Value = $stats.Conforme;    Slug = 'ok' }
        @{ Label = 'Non conformes';    Value = $stats.NonConforme; Slug = 'ko' }
        @{ Label = 'Points d''attention'; Value = $stats.Attention; Slug = 'warn' }
        @{ Label = 'Verif. manuelle';  Value = $stats.Manuel;      Slug = 'manual' }
        @{ Label = 'Non evalues';      Value = $stats.NonEvalue;   Slug = 'na' }
    )

    $kpiHtml = ($kpis | ForEach-Object {
        "<div class=`"kpi kpi-$($_.Slug)`"><span class=`"kpi-value`">$($_.Value)</span><span class=`"kpi-label`">$($_.Label)</span></div>"
    }) -join "`n"

    # --- Repartition par priorite ---
    $priorityHtml = ($stats.ParPriorite | ForEach-Object {
        $pct = $_.TauxPourcent
        @"
<div class="bar-row">
  <div class="bar-head"><span>$([System.Net.WebUtility]::HtmlEncode($_.Priorite))</span><span class="bar-meta">$($_.Conforme)/$($_.Evaluables) evaluees &middot; $pct&nbsp;% <small>($($_.Total) exigences)</small></span></div>
  <div class="bar"><div class="bar-fill" style="width:$pct%"></div></div>
</div>
"@
    }) -join "`n"

    # --- Repartition par section ---
    $sectionStatsHtml = ($stats.ParSection | Sort-Object Section | ForEach-Object {
        $pct = $_.TauxPourcent
        @"
<div class="bar-row">
  <div class="bar-head"><span>$([System.Net.WebUtility]::HtmlEncode($_.Section))</span><span class="bar-meta">$($_.Conforme)/$($_.Evaluables) evaluees &middot; $pct&nbsp;% <small>($($_.Total))</small></span></div>
  <div class="bar"><div class="bar-fill" style="width:$pct%"></div></div>
</div>
"@
    }) -join "`n"

    # --- Etat des connexions ---
    $servicesHtml = ($Context.Services.GetEnumerator() | ForEach-Object {
        $cls = if ($_.Value) { 'svc-on' } else { 'svc-off' }
        $txt = if ($_.Value) { 'connecte' } else { 'non connecte' }
        "<span class=`"svc $cls`">$($_.Key) : $txt</span>"
    }) -join ' '

    # --- Detail des controles, groupes par section ---
    $sectionsHtml = [System.Collections.Generic.List[string]]::new()

    foreach ($group in ($Results | Group-Object Section)) {
        $rows = foreach ($r in ($group.Group | Sort-Object Id)) {
            $slug = Get-CceStatusSlug -Status $r.Statut
            $ref = if ($r.Reference) {
                "<a href=`"$([System.Net.WebUtility]::HtmlEncode($r.Reference))`" target=`"_blank`" rel=`"noopener`">Documentation Microsoft</a>"
            } else { '' }

            $remediation = if ($r.ActionCorrective) {
                "<div class=`"block block-fix`"><span class=`"block-title`">Action corrective</span>$(ConvertTo-CceHtmlEncoded $r.ActionCorrective)</div>"
            } else { '' }

            $evidence = if ($r.Preuve) {
                "<details class=`"evidence`"><summary>Preuve collectee</summary><pre>$([System.Net.WebUtility]::HtmlEncode($r.Preuve))</pre></details>"
            } else { '' }

            @"
<article class="item" data-status="$slug" data-priority="$([System.Net.WebUtility]::HtmlEncode($r.Priorite))" data-text="$([System.Net.WebUtility]::HtmlEncode(("$($r.Id) $($r.Requirement) $($r.Categorie) $($r.ValeurConstatee)").ToLower()))">
  <header class="item-head">
    <span class="item-id">#$($r.Id)</span>
    <h3>$([System.Net.WebUtility]::HtmlEncode($r.Requirement))</h3>
    <span class="badge badge-$slug">$([System.Net.WebUtility]::HtmlEncode($r.Statut))</span>
    <span class="prio prio-$([System.Net.WebUtility]::HtmlEncode($r.Priorite).ToLower())">$([System.Net.WebUtility]::HtmlEncode($r.Priorite))</span>
  </header>
  <div class="item-body">
    <div class="block"><span class="block-title">Valeur constatee sur le tenant</span>$(ConvertTo-CceHtmlEncoded $r.ValeurConstatee)</div>
    <div class="block"><span class="block-title">Valeur attendue</span>$(ConvertTo-CceHtmlEncoded $r.ValeurAttendue)</div>
    $remediation
    $evidence
    <details class="more">
      <summary>Pourquoi et comment configurer</summary>
      <div class="block"><span class="block-title">Pourquoi</span>$(ConvertTo-CceHtmlEncoded $r.Pourquoi)</div>
      <div class="block"><span class="block-title">Ou et comment configurer</span>$(ConvertTo-CceHtmlEncoded $r.Procedure)</div>
      <div class="block"><span class="block-title">Commande de verification</span><code>$([System.Net.WebUtility]::HtmlEncode($r.CommandeVerification))</code></div>
      <div class="block">$ref</div>
    </details>
  </div>
</article>
"@
        }

        $sectionsHtml.Add(@"
<section class="group">
  <h2>$([System.Net.WebUtility]::HtmlEncode($group.Name)) <span class="group-count">$($group.Count)</span></h2>
  $($rows -join "`n")
</section>
"@)
    }

    $css = @'
:root{
  --bg:#f5f6f8; --surface:#ffffff; --border:#e3e6ea; --text:#1c1f23; --muted:#5f6b7a;
  --ok:#1a7f4b; --ok-bg:#e6f4ec; --ko:#b42318; --ko-bg:#fdeceb; --warn:#a86a00; --warn-bg:#fdf3e0;
  --manual:#1f4e79; --manual-bg:#e8f0f9; --na:#5f6b7a; --na-bg:#eef0f2; --accent:#0f6cbd;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#14171a; --surface:#1c2126; --border:#2c333a; --text:#e8eaed; --muted:#9aa5b1;
    --ok:#4ade80; --ok-bg:#12291d; --ko:#f87171; --ko-bg:#2c1616; --warn:#fbbf24; --warn-bg:#2c2413;
    --manual:#7cc0f5; --manual-bg:#13232f; --na:#9aa5b1; --na-bg:#232a30; --accent:#4aa3f0;
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
.prio{font-size:.72rem;color:var(--muted);border:1px solid var(--border);border-radius:999px;padding:2px 9px}
.prio-bloquant{color:var(--ko);border-color:var(--ko)}
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

  var filters = { status: 'all', priority: 'all' };

  function apply() {
    var q = (search.value || '').trim().toLowerCase();

    items.forEach(function (item) {
      var okStatus = filters.status === 'all' || item.dataset.status === filters.status;
      var okPrio = filters.priority === 'all' || item.dataset.priority === filters.priority;
      var okText = q === '' || item.dataset.text.indexOf(q) !== -1;
      item.classList.toggle('hidden', !(okStatus && okPrio && okText));
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

    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Copilot Check Engine - $([System.Net.WebUtility]::HtmlEncode($tenantLabel))</title>
<style>$css</style>
</head>
<body>
<div class="wrap">

<header class="top">
  <h1>Microsoft 365 Copilot &mdash; etat de configuration du tenant</h1>
  <div class="sub">
    Tenant : <strong>$([System.Net.WebUtility]::HtmlEncode($tenantLabel))</strong>
    &nbsp;&middot;&nbsp; $([System.Net.WebUtility]::HtmlEncode($Context.Tenant.Id))
    &nbsp;&middot;&nbsp; Genere le $generated
  </div>
  <div>$servicesHtml</div>
</header>

<div class="score">
  <div class="gauge" style="background:conic-gradient($gaugeColor $($rate * 3.6)deg, var(--na-bg) 0)"><span>$rate&nbsp;%</span></div>
  <div class="score-text">
    <h2>Taux de conformite sur les controles evalues automatiquement</h2>
    <p>$($stats.Conforme) configuration(s) conforme(s) sur $($stats.Evaluables) evaluee(s) automatiquement, sur un referentiel de $($stats.Total) exigences.
    $($stats.Manuel) exigence(s) relevent d'une verification manuelle, $($stats.NonEvalue) n'ont pas pu etre evaluees.</p>
    <p><strong>$($stats.BloquantsKo.Count)</strong> exigence(s) <strong>bloquante(s)</strong> non conforme(s).</p>
  </div>
</div>

<div class="kpis">$kpiHtml</div>

<div class="panels">
  <div class="panel"><h2>Conformite par priorite</h2>$priorityHtml</div>
  <div class="panel"><h2>Conformite par domaine</h2>$sectionStatsHtml</div>
</div>

<div class="toolbar">
  <input id="search" type="search" placeholder="Rechercher une exigence, une categorie, une valeur...">
  <button class="chip active" data-kind="status" data-value="all">Tous</button>
  <button class="chip" data-kind="status" data-value="ko">Non conformes</button>
  <button class="chip" data-kind="status" data-value="warn">Attention</button>
  <button class="chip" data-kind="status" data-value="ok">Conformes</button>
  <button class="chip" data-kind="status" data-value="manual">Manuels</button>
  <button class="chip active" data-kind="priority" data-value="all">Toutes priorites</button>
  <button class="chip" data-kind="priority" data-value="Bloquant">Bloquant</button>
  <button class="chip" data-kind="priority" data-value="Recommande">Recommande</button>
</div>

$($sectionsHtml -join "`n")

<footer>
  Rapport genere par <strong>Copilot Check Engine</strong> le $generated &mdash;
  referentiel : $([System.Net.WebUtility]::HtmlEncode($Context.Config.CatalogTitle)) v$([System.Net.WebUtility]::HtmlEncode($Context.Config.CatalogVersion)).
  Les statuts « Manuel » signalent les exigences sans API publique : elles doivent etre validees a la main.
</footer>

</div>
<script>$js</script>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding utf8
    Write-CceLog "Export HTML : $Path" -Level OK
    $Path
}
