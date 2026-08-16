# Copilot Check Engine

**Français : [README.md](README.md)**

Generates the **Microsoft 365 Copilot** configuration checklist already filled in with the real data of the tenant it runs against, and exports it to **XLSX**, **HTML** and **JSON**.

One command does everything: connect, collect, evaluate all 87 requirements, produce the reports.

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -AdminUpn admin@contoso.com -Language en -OpenReport
```

> **Read-only.** The engine never calls a state-changing cmdlet. It reads, evaluates and documents.

---

## What the engine produces

| Output | Contents |
| --- | --- |
| `CopilotCheck_<tenant>_<lang>_<timestamp>.xlsx` | Four sheets: **Summary** (indicators, rate by priority and by domain), **Checklist** (87 rows, conditional formatting, filters), **Evidence** (raw data collected), **Log** (execution trace). |
| `CopilotCheck_<tenant>_<lang>_<timestamp>.html` | Self-contained report: compliance gauge, KPI cards, bars by priority and by domain, full-text search, status and priority filters, print layout. No external resource. |
| `CopilotCheck_<tenant>_<lang>_<timestamp>.json` | Same content, ready for a CI pipeline or a dashboard. |

Every requirement is reported with its **observed value on the tenant**, the expected value, the **remediation**, the **evidence collected**, the business rationale, the configuration procedure, the verification command and the Microsoft Learn link.

### Statuses

| Status | Meaning |
| --- | --- |
| `Compliant` | Checked automatically, matches the expected value. |
| `Non-compliant` | Checked automatically, confirmed gap. |
| `Attention` | Partial configuration, or a governance decision to make. |
| `Manual` | No public API: the engine supplies the procedure, a human validates. |
| `Not evaluated` | Service not connected, insufficient permissions, or an error during the check. |
| `Not applicable` | The audited capability is not held by the tenant (add-on or licence absent). Out of score. |

The compliance rate only contains what the engine measured itself, on capabilities the tenant actually holds: it is computed over `Compliant + Non-compliant + Attention`. Manual, not applicable, informational and deprecated requirements appear in the report without affecting the figure.

---

## Coverage

Of the 87 requirements in the baseline:

- **73** are evaluated automatically by querying the tenant;
- **6** require inspecting a workstation (`-IncludeLocalChecks`);
- **8** are portal settings with no public API, or organisational deliverables, and are reported as `Manual` with the exact procedure.

The full breakdown, requirement by requirement with the source queried, is in [`docs/COVERAGE.en.md`](docs/COVERAGE.en.md).

---

## Prerequisites

**PowerShell 7.0 or later.**

```powershell
Install-Module Microsoft.Graph, ExchangeOnlineManagement, MicrosoftTeams, ImportExcel -Scope CurrentUser
Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser   # loaded in Windows PowerShell compatibility mode under PS7
```

### Required roles

| Service | Minimum role |
| --- | --- |
| Microsoft Graph | Global Reader (delegated), or an application with `Organization.Read.All`, `Directory.Read.All`, `User.Read.All`, `Group.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `Application.Read.All` |
| Exchange Online | Global Reader or View-Only Recipients |
| Purview | Compliance configuration reader; **View-Only Audit Logs** for check 47 |
| SharePoint Online | SharePoint Administrator |
| Microsoft Teams | Teams Administrator |

A **Global Reader** covers nearly every check. A service that fails to connect does not stop the run: the requirements it backs are reported as `Not evaluated` with the reason.

---

## Usage

### Full interactive audit

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -AdminUpn admin@contoso.com -Language en -OpenReport
```

### Unattended run (app-only, certificate)

```powershell
.\Invoke-CopilotCheckEngine.ps1 `
    -TenantId  00000000-0000-0000-0000-000000000000 `
    -ClientId  11111111-1111-1111-1111-111111111111 `
    -CertificateThumbprint A1B2C3D4E5F6... `
    -Organization contoso.onmicrosoft.com `
    -Language en `
    -OutputPath \\server\reports\copilot
```

### Partial audit

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -Services Graph,Teams -Language en
```

### Reuse sessions you already opened

```powershell
Connect-MgGraph -Scopes Organization.Read.All, Directory.Read.All, User.Read.All, Group.Read.All, Policy.Read.All, Reports.Read.All
.\Invoke-CopilotCheckEngine.ps1 -SkipConnect -Language en
```

### Include the current workstation

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -IncludeLocalChecks -Language en
```

Adds the ClickToRun registry read (Office product, update channel) and the Office privacy policies — the two requirements that cannot be evaluated remotely.

### Consume the result from a script

```powershell
$audit = .\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -Language en -PassThru
$audit.Statistics.TauxConformite
$audit.Results | Where-Object { $_.Priorite -eq 'Blocking' -and $_.Statut -eq 'NonCompliant' }
```

`Priorite` and `Statut` carry **language-neutral canonical tokens** (`Blocking` / `Recommended` / `Optimal` and `Compliant` / `NonCompliant` / `Warning` / `Manual` / `NotEvaluated`), so a script keeps working whichever report language is selected. The localised text sits in `PrioriteLibelle` and `StatutLibelle`.

### Parameters

| Parameter | Purpose |
| --- | --- |
| `-TenantId` | Tenant ID or domain. |
| `-AdminUpn` | Admin account for interactive Exchange / Purview sign-in. |
| `-ClientId`, `-CertificateThumbprint`, `-ClientSecret`, `-Organization` | Unattended run (app-only). |
| `-Language` | Report language: `fr` (default) or `en`. |
| `-SharePointAdminUrl` | Overrides the SharePoint admin URL (derived from the default domain otherwise). |
| `-Services` | Subset of `Graph`, `Exchange`, `Purview`, `SharePoint`, `Teams`, plus `PowerPlatform` and `Commerce` (optional, separate admin domains). |
| `-RetrievalProbeTerm` | A known, indexed business term for the semantic index probe. Without it the probe stays manual. |
| `-AllowReportGeneration` | Allows triggering SharePoint reports that do not exist yet. Off by default: the engine stays side-effect free. |
| `-AgentNamingPattern` | Regular expression for the agent naming convention. Without it the check inventories without judging. |
| `-OutputPath` | Output directory. Default: `.\output`. |
| `-IncludeLocalChecks` | Adds inspection of the current workstation. |
| `-MailboxSampleSize` | Number of mailboxes analysed for the Exchange checks. Default: 100. |
| `-SkipConnect` | Reuses open sessions. |
| `-KeepConnections` | Leaves sessions open when the run ends. |
| `-OpenReport` | Opens the HTML report. |
| `-PassThru` | Returns results, statistics and report paths. |

---

## Repository layout

```
Invoke-CopilotCheckEngine.ps1     Entry point: connections, orchestration, exports
data/checklist-catalog.json       Baseline, 87 requirements (French, source of truth)
data/checklist-catalog.en.json    Same baseline, English
data/strings.fr.json              Runtime message templates, French
data/strings.en.json              Runtime message templates, English
src/Private/                      Core: result model, connections, shared collectors, language resources
src/Checks/                       One file per domain, one Invoke-CceCheckNN function per requirement
src/Export/                       XLSX and HTML exports + statistics
tools/Convert-XlsxToCatalog.ps1   Rebuilds the catalogue from the reference workbook
tools/New-CceCoverageDoc.ps1      Rebuilds docs/COVERAGE.md and docs/COVERAGE.en.md
tools/New-CceDemoReport.ps1       Demonstration report (smoke test, no tenant needed)
tools/Test-CceI18n.ps1            Validates resource keys, placeholders and catalogues
tools/Test-CceChecks.ps1          Runs all 87 checks dry in both languages
samples/                          Sample output
docs/COVERAGE.en.md               Source queried for every requirement
```

### How localisation works

Check functions contain no literal text. They reference a key resolved at runtime:

```powershell
New-CceResult -Status 'Non conforme' `
    -Observed ((T 'c14.obs.ko') -f $disabled.Count) `
    -Evidence ($disabled | ForEach-Object { $_.UserPrincipalName } | ConvertTo-CceText) `
    -Remediation (T 'c14.rem.ko')
```

`T` returns the template for the active language from `data/strings.<lang>.json`; the caller applies `-f`. A key missing in the active language falls back to French, then to a visible `[[key]]` marker so a gap surfaces during testing rather than silently.

`tools/Test-CceI18n.ps1` enforces the contract in CI: every key referenced in the code exists in every language, and a template never loses a placeholder in translation.

### Data and logic are separate

The baseline (wording, rationale, procedures, priorities, references) lives in `data/checklist-catalog*.json`. The functions in `src/Checks/` only carry query logic. Evolving the checklist therefore does not mean touching the engine.

The catalogue is derived from a reference Excel workbook. That workbook is not published here — the versioned JSON is authoritative. To rebuild it from your own workbook (same columns, header on row 5):

```powershell
.\tools\Convert-XlsxToCatalog.ps1 -XlsxPath .\Copilot_Config_Checklist.xlsx
.\tools\New-CceCoverageDoc.ps1
```

### Adding a check

1. Add the requirement to the workbook, then rebuild the catalogue (both languages).
2. Create `Invoke-CceCheck<NN>` in the matching domain file.
3. Return `New-CceResult -Status <status> -Observed <observed> -Evidence <evidence> -Remediation <action>`, using `T` keys for every piece of text.
4. Add those keys to `data/strings.fr.json` and `data/strings.en.json`, then run `tools\Test-CceI18n.ps1`.

The function is discovered automatically by its name. A requirement with no matching function is reported as `Not evaluated`.

---

## Try it without a tenant

```powershell
.\tools\New-CceDemoReport.ps1 -Language en
```

Generates `samples/CopilotCheck_demo.en.xlsx` and `samples/CopilotCheck_demo.en.html` from synthetic data — useful to validate the export chain or to present the deliverable.

---

## Licence

MIT — see [LICENSE](LICENSE).
