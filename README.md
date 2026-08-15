# Copilot Check Engine

Genere la checklist de configuration **Microsoft 365 Copilot** deja renseignee avec les donnees reelles du tenant sur lequel le script est execute, et l'exporte en **XLSX**, **HTML** et **JSON**.

Une seule commande : connexion, collecte, evaluation des 59 exigences, production des rapports.

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -AdminUpn admin@contoso.com -OpenReport
```

> **Lecture seule.** Le moteur n'appelle aucune commande de modification. Il lit, evalue et documente.

---

## Ce que produit le moteur

| Sortie | Contenu |
| --- | --- |
| `CopilotCheck_<tenant>_<horodatage>.xlsx` | 4 onglets : **Synthese** (indicateurs, taux par priorite et par domaine), **Checklist** (59 lignes, mise en forme conditionnelle, filtres), **Preuves** (donnees brutes collectees), **Journal** (trace d'execution). |
| `CopilotCheck_<tenant>_<horodatage>.html` | Rapport autonome : jauge de conformite, indicateurs, barres par priorite et par domaine, recherche plein texte, filtres par statut et par priorite, mise en page d'impression. Aucune ressource externe. |
| `CopilotCheck_<tenant>_<horodatage>.json` | Meme contenu, exploitable en CI ou par un tableau de bord. |

Chaque exigence est restituee avec : la **valeur constatee sur le tenant**, la valeur attendue, l'**action corrective**, la **preuve collectee**, la justification metier, la procedure de configuration, la commande de verification et le lien Microsoft Learn.

### Statuts

| Statut | Signification |
| --- | --- |
| `Conforme` | Verifie automatiquement, conforme a la valeur attendue. |
| `Non conforme` | Verifie automatiquement, ecart avere. |
| `Attention` | Configuration partielle ou arbitrage de gouvernance requis. |
| `Manuel` | Aucune API publique : le moteur fournit la procedure, la validation reste humaine. |
| `Non evalue` | Service non connecte, droits insuffisants ou erreur pendant le controle. |

Le taux de conformite est calcule sur la base evaluable automatiquement (`Conforme + Non conforme + Attention`), afin que les exigences manuelles ne faussent pas l'indicateur.

---

## Couverture

Sur les 59 exigences du referentiel :

- **42** sont evaluees automatiquement en interrogeant le tenant ;
- **2** necessitent l'inspection d'un poste (`-IncludeLocalChecks`) ;
- **15** relevent d'un parametre de portail sans API publique ou d'un livrable organisationnel, et sont restituees en `Manuel` avec la procedure exacte.

Le detail exigence par exigence, avec la source interrogee, est dans [`docs/COVERAGE.md`](docs/COVERAGE.md).

---

## Prerequis

**PowerShell 7.0 ou superieur.**

```powershell
Install-Module Microsoft.Graph, ExchangeOnlineManagement, MicrosoftTeams, ImportExcel -Scope CurrentUser
Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser   # charge en mode compatibilite sous PS7
```

### Roles requis

| Service | Role minimal |
| --- | --- |
| Microsoft Graph | Lecteur global (delegue) ou application avec `Organization.Read.All`, `Directory.Read.All`, `User.Read.All`, `Group.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `Application.Read.All` |
| Exchange Online | Lecteur global ou Destinataires en lecture seule |
| Purview | Lecteur de configuration de conformite ; **Journaux d'audit avec affichage seul** pour le controle 47 |
| SharePoint Online | Administrateur SharePoint |
| Microsoft Teams | Administrateur Teams |

Un **Lecteur global** couvre la quasi-totalite des controles. Les services non connectes ne bloquent pas l'execution : les exigences concernees passent en `Non evalue`.

---

## Utilisation

### Audit complet, interactif

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -AdminUpn admin@contoso.com -OpenReport
```

### Execution planifiee (app-only, certificat)

```powershell
.\Invoke-CopilotCheckEngine.ps1 `
    -TenantId  00000000-0000-0000-0000-000000000000 `
    -ClientId  11111111-1111-1111-1111-111111111111 `
    -CertificateThumbprint A1B2C3D4E5F6... `
    -Organization contoso.onmicrosoft.com `
    -OutputPath \\serveur\rapports\copilot
```

### Audit partiel

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -Services Graph,Teams
```

### Reutiliser des sessions deja ouvertes

```powershell
Connect-MgGraph -Scopes Organization.Read.All, Directory.Read.All, User.Read.All, Group.Read.All, Policy.Read.All, Reports.Read.All
.\Invoke-CopilotCheckEngine.ps1 -SkipConnect
```

### Inclure l'audit du poste courant

```powershell
.\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -IncludeLocalChecks
```

Ajoute la lecture du registre ClickToRun (produit Office, canal de mise a jour) et des strategies de confidentialite Office — les deux exigences non evaluables a distance.

### Exploiter le resultat dans un script

```powershell
$audit = .\Invoke-CopilotCheckEngine.ps1 -TenantId contoso.onmicrosoft.com -PassThru
$audit.Statistics.TauxConformite
$audit.Results | Where-Object { $_.Priorite -eq 'Bloquant' -and $_.Statut -eq 'Non conforme' }
```

### Parametres

| Parametre | Role |
| --- | --- |
| `-TenantId` | Identifiant ou domaine du tenant. |
| `-AdminUpn` | Compte d'administration pour les connexions interactives Exchange / Purview. |
| `-ClientId`, `-CertificateThumbprint`, `-ClientSecret`, `-Organization` | Execution non interactive (app-only). |
| `-SharePointAdminUrl` | Force l'URL d'administration SharePoint (deduite du domaine par defaut sinon). |
| `-Services` | Sous-ensemble parmi `Graph`, `Exchange`, `Purview`, `SharePoint`, `Teams`. |
| `-OutputPath` | Repertoire de sortie. Defaut : `.\output`. |
| `-IncludeLocalChecks` | Ajoute l'inspection du poste courant. |
| `-MailboxSampleSize` | Nombre de boites analysees pour les controles Exchange. Defaut : 100. |
| `-SkipConnect` | Reutilise les sessions ouvertes. |
| `-KeepConnections` | Ne ferme pas les sessions en fin d'execution. |
| `-OpenReport` | Ouvre le rapport HTML. |
| `-PassThru` | Retourne resultats, statistiques et chemins des rapports. |

---

## Structure du depot

```
Invoke-CopilotCheckEngine.ps1     Point d'entree : connexions, orchestration, exports
data/checklist-catalog.json       Referentiel des 59 exigences (source de verite)
src/Private/                      Noyau : modele de resultat, connexions, collecteurs mutualises
src/Checks/                       Un fichier par domaine, une fonction Invoke-CceCheckNN par exigence
src/Export/                       Exports XLSX et HTML + calcul des statistiques
tools/Convert-XlsxToCatalog.ps1   Regenere le catalogue depuis le classeur de reference
tools/New-CceCoverageDoc.ps1      Regenere docs/COVERAGE.md
tools/New-CceDemoReport.ps1       Rapport de demonstration (test de fumee, sans tenant)
samples/                          Exemples de sortie
docs/COVERAGE.md                  Source interrogee pour chaque exigence
```

### Separation donnees / logique

Le referentiel (libelles, justifications, procedures, priorites, references) vit dans `data/checklist-catalog.json`. Les fonctions de `src/Checks/` ne portent que la logique d'interrogation. Faire evoluer la checklist ne demande donc pas de toucher au moteur.

Le catalogue est derive d'un classeur Excel de reference. Ce classeur n'est pas publie ici — le JSON versionne fait foi. Pour le regenerer depuis votre propre classeur (memes colonnes : `#`, `Categorie`, `Configuration requise`, `Pourquoi`, `Ou et comment configurer`, `Valeur attendue`, `Verification`, `Priorite`, `Statut`, `Reference`, en-tete en ligne 5) :

```powershell
.\tools\Convert-XlsxToCatalog.ps1 -XlsxPath .\Copilot_Config_Checklist.xlsx
.\tools\New-CceCoverageDoc.ps1
```

### Ajouter un controle

1. Ajouter l'exigence dans le classeur puis regenerer le catalogue.
2. Creer `Invoke-CceCheck<NN>` dans le fichier de domaine correspondant.
3. Retourner `New-CceResult -Status <statut> -Observed <valeur constatee> -Evidence <preuve> -Remediation <action>`.

La fonction est decouverte automatiquement par son nom. Une exigence sans fonction correspondante ressort en `Non evalue`.

---

## Verifier sans tenant

```powershell
.\tools\New-CceDemoReport.ps1
```

Genere `samples/CopilotCheck_demo.xlsx` et `samples/CopilotCheck_demo.html` a partir de donnees synthetiques : utile pour valider la chaine d'export ou presenter le livrable.

---

## Licence

MIT — voir [LICENSE](LICENSE).
