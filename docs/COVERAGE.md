# Couverture des controles

Genere par `tools/New-CceCoverageDoc.ps1`. Referentiel : Microsoft 365 Copilot - Checklist de configuration tenant v2.0 (59 exigences).

| Mode | Nombre | Signification |
| --- | ---: | --- |
| Automatique | 42 | Statut deduit d'une interrogation du tenant. |
| Poste local | 2 | Necessite `-IncludeLocalChecks` sur un poste de reference. |
| Manuel | 15 | Aucune API publique : le moteur documente la procedure et laisse le statut a valider. |

## ACTIVATION ET CONFIGURATION COPILOT

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 33 | Activer Copilot globalement au niveau du tenant | Bloquant | Automatique | Graph beta - rapport d'usage Copilot (preuve d'activite) |
| 34 | Activer tous les workloads Copilot (Word, Excel, PPT, Outlook, Teams, Web) | Bloquant | Automatique | Graph beta - rapport d'usage Copilot par workload |
| 35 | Activer Copilot Chat (Microsoft 365 Chat / Business Chat) | Recommande | Automatique | Graph beta - activite Copilot Chat |
| 36 | Configurer l'accès au contenu web et la source de données Copilot Chat | Recommande | Manuel | Decision de gouvernance a documenter |
| 37 | Vérifier la propagation de Copilot sur un utilisateur test | Bloquant | Automatique | Graph beta - rapport d'usage (propagation constatee) |
| 38 | Activer et consulter les rapports d'utilisation Copilot | Recommande | Automatique | Graph beta - accessibilite du rapport + detection d'anonymisation |
| 39 | Configurer Viva Insights pour le suivi d'adoption Copilot | Optimal | Manuel | Viva Insights (pas d'API d'etat) |
| 40 | Configurer la génération d'images Copilot (Designer) | Recommande | Manuel | Portail Copilot (pas d'API publique) |
| 41 | Configurer Copilot dans Bing, Microsoft Edge et Windows | Recommande | Manuel | Portail Copilot (pas d'API publique) |
| 42 | Configurer la clause d'exclusion de responsabilité IA Copilot | Recommande | Manuel | Portail Copilot (pas d'API publique) |

## AGENTS, PLUGINS ET GOUVERNANCE COPILOT

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 43 | Restreindre la création d'agents Copilot aux administrateurs | Recommande | Manuel | Portail Copilot > Agents |
| 44 | Définir qui peut publier des agents dans l'organisation | Recommande | Manuel | Portail Copilot > Agents |
| 45 | Contrôler les extensions et plugins tiers autorisés | Recommande | Automatique | Graph - inventaire servicePrincipals tiers |
| 46 | Contrôler les connecteurs Microsoft Graph autorisés | Recommande | Automatique | Graph - /external/connections |
| 47 | Activer l'audit des interactions avec les agents Copilot | Recommande | Automatique | Exchange - Search-UnifiedAuditLog (CopilotInteraction) |
| 48 | Établir une convention de nommage pour les agents | Optimal | Manuel | Livrable documentaire |
| 49 | Créer un processus d'approbation pour les nouveaux agents | Optimal | Manuel | Processus organisationnel |
| 50 | Documenter une politique d'usage des agents Copilot | Optimal | Manuel | Livrable documentaire |
| 51 | Revue périodique des agents déployés (trimestrielle) | Optimal | Manuel | Rituel de gouvernance |

## APPLICATIONS ET AUTHENTIFICATION

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 6 | Microsoft 365 Apps for Enterprise déployé sur les postes | Bloquant | Poste local | Registre ClickToRun (-IncludeLocalChecks) + rapport M365 Apps |
| 7 | Canal de mise à jour = Current Channel ou Monthly Enterprise | Bloquant | Automatique | Graph beta - /admin/microsoft365Apps/installationOptions (+ registre local) |
| 8 | Modern Authentication (OAuth2) activée sur le tenant | Bloquant | Automatique | Exchange - Get-OrganizationConfig |
| 9 | Expériences connectées (Connected Experiences) activées | Bloquant | Poste local | Registre Office privacy (-IncludeLocalChecks) |

## EXCHANGE ONLINE

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 24 | Vérifier que les boites aux lettres sont dans Exchange Online | Bloquant | Automatique | Exchange - Get-Mailbox (echantillon Copilot) |
| 25 | Vérifier que MAPI est activé sur les boites Copilot | Recommande | Automatique | Exchange - Get-CASMailbox |
| 26 | Activer l'audit unifié et l'audit des boites aux lettres | Bloquant | Automatique | Exchange - Get-AdminAuditLogConfig + Get-OrganizationConfig |

## IDENTITE ET ACCES CONDITIONNEL

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 10 | MFA activé pour tous les utilisateurs Copilot via Accès conditionnel | Bloquant | Automatique | Graph - /identity/conditionalAccess/policies |
| 11 | Vérifier qu'aucune stratégie CA ne bloque Microsoft Graph | Bloquant | Automatique | Graph - analyse des controles block sur Microsoft Graph |
| 12 | Vérifier qu'aucune CA policy ne bloque Office 365 | Bloquant | Automatique | Graph - analyse des controles block sur Office 365 |
| 13 | UPN des utilisateurs = adresse email principale (pas .local) | Recommande | Automatique | Graph - suffixes UPN |
| 14 | Retirer les licences Copilot des comptes désactivés | Recommande | Automatique | Graph - comptes desactives licencies |
| 15 | Retirer les licences Copilot des comptes invités (B2B) | Recommande | Automatique | Graph - comptes invites licencies |

## LICENCES COPILOT

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 1 | Licence M365 E3/E5 ou Business Premium attribuée aux utilisateurs cibles | Bloquant | Automatique | Graph - Get-MgSubscribedSku |
| 2 | SKU Microsoft 365 Copilot acheté et visible sur le tenant | Bloquant | Automatique | Graph - Get-MgSubscribedSku |
| 3 | Licence Copilot attribuée individuellement ou via groupe | Bloquant | Automatique | Graph - Get-MgUser (filtre assignedLicenses) |
| 4 | Attribution des licences via groupe Entra ID (pas manuelle) | Recommande | Automatique | Graph - /groups?$filter=assignedLicenses |
| 5 | Vérifier que l'abonnement Copilot n'expire pas dans les 60 jours | Recommande | Automatique | Graph beta - /directory/subscriptions |

## MICROSOFT TEAMS POUR COPILOT

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 27 | Autoriser l'application Copilot dans les stratégies Teams | Bloquant | Automatique | Teams - Get-CsTeamsAppPermissionPolicy + Graph appCatalogs |
| 28 | Épingler Copilot dans la barre latérale Teams | Recommande | Automatique | Teams - Get-CsTeamsAppSetupPolicy + Graph appCatalogs |
| 29 | Activer la transcription des réunions (obligatoire pour les résumés Copilot) | Bloquant | Automatique | Teams - Get-CsTeamsMeetingPolicy (AllowTranscription) |
| 30 | Activer l'enregistrement cloud des réunions | Recommande | Automatique | Teams - Get-CsTeamsMeetingPolicy (AllowCloudRecording) |
| 31 | Configurer le mode Copilot pour les réunions | Bloquant | Automatique | Teams - Get-CsTeamsMeetingPolicy (CopilotMode) |
| 32 | Activer les sous-titres en direct | Optimal | Automatique | Teams - Get-CsTeamsMeetingPolicy (sous-titres) |

## SECURITE ET PROTECTION DES DONNEES

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 52 | Configurer les labels de sensibilité (minimum 3 niveaux) | Bloquant | Automatique | Purview - Get-Label |
| 53 | Publier les labels vers les utilisateurs Copilot | Bloquant | Automatique | Purview - Get-LabelPolicy |
| 54 | Activer l'auto-labeling pour les nouveaux fichiers | Recommande | Automatique | Purview - Get-AutoSensitivityLabelPolicy |
| 55 | Configurer des politiques DLP couvrant les 4 workloads | Bloquant | Automatique | Purview - Get-DlpCompliancePolicy (couverture 4 workloads) |
| 56 | Configurer la rétention des interactions Copilot | Recommande | Automatique | Purview - Get-RetentionCompliancePolicy |
| 57 | Configurer la rétention des logs d'audit (>= 90 jours) | Recommande | Automatique | Purview - Get-UnifiedAuditLogRetentionPolicy |
| 58 | Configurer eDiscovery pour les données Copilot | Optimal | Manuel | Test fonctionnel eDiscovery |
| 59 | Activer Microsoft Purview Data Access Governance pour SharePoint | Optimal | Manuel | Rapports Purview DAG |

## SHAREPOINT ET ONEDRIVE

| # | Exigence | Priorite | Mode | Source interrogee |
| ---: | --- | --- | --- | --- |
| 16 | Configurer le partage global SharePoint en mode sécurisé | Bloquant | Automatique | SharePoint - Get-SPOTenant |
| 17 | Configurer l'expiration des liens anonymes à 7 jours maximum | Recommande | Automatique | SharePoint - Get-SPOTenant |
| 18 | Identifier et restreindre les sites SharePoint sur-partagés | Bloquant | Automatique | SharePoint - Get-SPOSite (detection mots-cles sensibles) |
| 19 | Provisionner OneDrive pour tous les utilisateurs Copilot | Recommande | Automatique | SharePoint - Get-SPOSite -IncludePersonalSite + Graph |
| 20 | Vérifier que Microsoft Search est activé et fonctionnelle | Bloquant | Manuel | Test fonctionnel Microsoft Search |
| 21 | Vérifier que NoCrawl est désactivé sur les sites critiques | Recommande | Manuel | PnP.PowerShell par site (Get-PnPWeb -Includes NoCrawl) |
| 22 | Vérifier la configuration de Restricted SharePoint Search | Recommande | Automatique | SharePoint - Get-SPOTenantRestrictedSearchMode |
| 23 | Configurer le quota OneDrive à 1 To minimum | Optimal | Automatique | SharePoint - Get-SPOTenant (OneDriveStorageQuota) |


