# Couverture des controles

Genere par `tools/New-CceCoverageDoc.ps1` depuis le referentiel. Base : Microsoft 365 Copilot - Checklist de configuration tenant v2.0 (87 exigences).

| Mode | Nombre | Signification |
| --- | ---: | --- |
| Automatique | 73 | Statut deduit d'une interrogation du tenant. |
| Poste local | 6 | Necessite `-IncludeLocalChecks` sur un poste de reference. |
| Manuel | 8 | Aucune API publique : le moteur documente la procedure et laisse le statut a valider. |

### Par phase

| Phase | Total |
| --- | ---: |
| Avant | 53 |
| Apres | 13 |
| Avant et apres | 21 |

> Une exigence marquee « non notee » figure au rapport mais ne pese pas sur le taux de
> conformite : capacite en preversion, exigence depreciee, ou volet informatif.

## ACTIVATION ET CONFIGURATION COPILOT

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 33 | Activer Copilot globalement au niveau du tenant | Bloquant | Avant | Automatique | `graph` | oui |
| 34 | Activer tous les workloads Copilot (Word, Excel, PPT, Outlook, Teams, Web) | Bloquant | Avant | Automatique | `graph` | oui |
| 35 | Activer et epingler Microsoft 365 Copilot Chat | Recommande | Avant et apres | Automatique | `graph-beta` | oui |
| 36 | Trancher l'acces de Copilot au contenu web | Recommande | Avant et apres | Automatique | `graph-beta` | oui |
| 37 | Verifier la propagation de Copilot application par application | Bloquant | Apres | Automatique | `graph` | oui |
| 38 | Exploiter les rapports d'utilisation Copilot : disponibilite, fraicheur et anonymisation | Recommande | Apres | Automatique | `graph` | oui |
| 39 | Verifier l'acces au tableau de bord Copilot de Viva Insights et ses prerequis de mesure | Optimal | Apres | Automatique | `exchange` | oui |
| 40 | Trancher la generation d'images Copilot (Designer) | Recommande | Avant et apres | Automatique | `graph-beta` | oui |
| 41 | Verifier la strategie de configuration Microsoft Edge couvrant Copilot | Recommande | Avant | Automatique | `graph-beta` | oui |
| 42 | Trancher Vision (partage d'ecran et de camera) et publier la charte d'usage IA | Recommande | Avant | Manuel | `manual` | non |
| 65 | Vérifier que Microsoft Loop et Microsoft Whiteboard sont activés sur le tenant | Recommande | Avant | Automatique | `sharepoint` | oui |
| 88 | Arbitrer l'acces de Copilot au contenu ouvert et sa disponibilite dans les centres d'administration | Recommande | Avant | Automatique | `graph-beta` | oui |

## AGENTS, PLUGINS ET GOUVERNANCE COPILOT

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 43 | Restreindre la création d'agents Copilot aux administrateurs | Recommande | Avant | Manuel | `manual` | oui |
| 44 | Controler la portee de publication de chaque agent (availableTo, deployedTo, isBlocked) | Recommande | Apres | Automatique | `graph` - Microsoft Agent 365 | oui |
| 45 | Contrôler les extensions et plugins tiers autorisés | Recommande | Avant | Automatique | `graph` | oui |
| 46 | Controler les connecteurs Microsoft Graph et le mode d'autorisation de leur contenu indexe | Recommande | Avant et apres | Automatique | `graph` | oui |
| 47 | Activer l'audit des interactions avec les agents Copilot | Recommande | Apres | Automatique | `exchange` | oui |
| 48 | Etablir une convention de nommage pour les agents et mesurer son respect | Optimal | Avant et apres | Automatique | `graph` - Microsoft Agent 365 | oui |
| 49 | Créer un processus d'approbation pour les nouveaux agents | Optimal | Avant | Manuel | `manual` | oui |
| 50 | Documenter une politique d'usage des agents Copilot | Optimal | Avant | Manuel | `manual` | oui |
| 51 | Revue periodique des agents deployes (trimestrielle), adossee au registre d'agents | Recommande | Avant et apres | Automatique | `graph` - Microsoft Agent 365 | oui |
| 85 | Agents Copilot Studio à risque : authentification 'Aucune', connexions fournies par le créateur, créateurs hors périmètre | Bloquant | Apres | Automatique | `powerplatform` - Microsoft Copilot Studio | oui |
| 86 | Politique de données Power Platform encadrant les connecteurs et les serveurs MCP utilisables par les agents | Recommande | Avant | Automatique | `powerplatform` | oui |
| 87 | Identités d'agent Microsoft Entra : propriétaire et sponsor, correspondance avec le registre, couverture par l'accès conditionnel | Recommande | Apres | Automatique | `graph` - Microsoft Agent 365 | non |

## APPLICATIONS ET AUTHENTIFICATION

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 6 | Microsoft 365 Apps for Enterprise déployé sur les postes | Bloquant | Avant | Poste local | `workstation` | oui |
| 7 | Canal de mise à jour = Current Channel ou Monthly Enterprise | Bloquant | Avant | Automatique | `graph-beta` | oui |
| 8 | Modern Authentication (OAuth2) activée sur le tenant | Bloquant | Avant | Automatique | `exchange` | oui |
| 9 | Expériences connectées (Connected Experiences) activées | Recommande | Avant | Poste local | `workstation` | oui |

## COUT ET CYCLE DE VIE DES LICENCES

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 80 | Identifier et recycler les licences Copilot dormantes attribuées à des comptes actifs | Recommande | Apres | Automatique | `graph` | oui |
| 81 | Arbitrer et documenter le périmètre de Microsoft 365 Copilot Chat pour la population non licenciée | Recommande | Avant | Automatique | `exchange` | oui |
| 82 | Encadrer la facturation à l'usage des agents : stratégie de facturation, périmètre, budget et suivi des Copilot Credits | Recommande | Avant et apres | Manuel | `manual` | non |
| 83 | Bloquer les achats en libre-service de licences Microsoft 365 Copilot | Recommande | Avant | Automatique | `mscommerce` | oui |
| 84 | Assurer la veille du centre de messages sur les changements Copilot à action requise | Recommande | Apres | Automatique | `graph` | oui |

## EXCHANGE ONLINE

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 24 | Vérifier que chaque utilisateur licencié Copilot dispose d'une boîte aux lettres principale dans Exchange Online | Bloquant | Avant | Automatique | `exchange` | oui |
| 25 | Vérifier que MAPI est activé sur les boites Copilot | Recommande | Avant | Automatique | `exchange` | oui |
| 26 | Activer l'audit unifié et l'audit des boites aux lettres | Bloquant | Avant | Automatique | `exchange` | oui |

## IDENTITE ET ACCES CONDITIONNEL

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 10 | MFA activé pour tous les utilisateurs Copilot via Accès conditionnel | Bloquant | Avant | Automatique | `graph` | oui |
| 11 | Vérifier qu'aucune stratégie CA ne bloque Microsoft Graph | Bloquant | Avant | Automatique | `graph` | oui |
| 12 | Vérifier qu'aucune CA policy ne bloque Office 365 | Bloquant | Avant | Automatique | `graph` | oui |
| 13 | UPN des utilisateurs = adresse email principale (pas .local) | Recommande | Avant | Automatique | `graph` | oui |
| 14 | Retirer les licences Copilot des comptes désactivés | Recommande | Avant et apres | Automatique | `graph` | oui |
| 15 | Retirer les licences Copilot des comptes invités (B2B) | Recommande | Avant et apres | Automatique | `graph` | oui |

## LICENCES COPILOT

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 1 | Plan de base éligible à Copilot détenu par chaque utilisateur licencié | Bloquant | Avant | Automatique | `graph` | oui |
| 2 | SKU Microsoft 365 Copilot acheté et visible sur le tenant | Bloquant | Avant | Automatique | `graph` | oui |
| 3 | Licence Copilot attribuée et plan de service Copilot réellement provisionné | Bloquant | Avant | Automatique | `graph` | oui |
| 4 | Attribution des licences via groupe Entra ID (pas manuelle) | Recommande | Avant | Automatique | `graph` | oui |
| 5 | Vérifier que l'abonnement Copilot n'expire pas dans les 60 jours | Recommande | Avant et apres | Automatique | `graph` | oui |

## MICROSOFT TEAMS POUR COPILOT

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 27 | Autoriser l'application Copilot dans les stratégies Teams | Bloquant | Avant | Automatique | `teams` | oui |
| 28 | Épingler Copilot dans la barre latérale Teams | Recommande | Avant | Automatique | `teams` | oui |
| 29 | Activer la transcription des réunions (obligatoire pour les résumés Copilot) | Bloquant | Avant | Automatique | `teams` | oui |
| 30 | Activer l'enregistrement cloud des réunions | Recommande | Avant | Automatique | `teams` | oui |
| 31 | Configurer le mode Copilot des réunions Teams sur la transcription conservée | Bloquant | Avant | Automatique | `teams` | oui |
| 32 | Activer les sous-titres en direct | Optimal | Avant | Automatique | `teams` | oui |

## RESEAU ET POSTE DE TRAVAIL

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 68 | Connectivité Copilot : endpoints requis joignables, WebSocket (WSS) autorisé et aucune inspection TLS | Bloquant | Avant | Poste local | `workstation` | oui |
| 69 | Tâche planifiée Office Feature Updates active et CDN des expériences connectées joignable | Recommande | Avant et apres | Poste local | `workstation` | oui |
| 70 | Runtime WebView2 présent et cookies tiers autorisés pour les applications Office web | Recommande | Avant et apres | Poste local | `workstation` | oui |
| 71 | Aucune activation par licence d'appareil (device-based licensing) sur les postes Copilot | Recommande | Avant | Poste local | `workstation` | oui |

## RESIDENCE ET SOUVERAINETE DES DONNEES

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 72 | Attribuer le rôle AI Administrator pour l'administration de Copilot et appliquer le moindre privilège | Recommande | Avant | Automatique | `graph` | oui |
| 73 | Activer Customer Lockbox et déclarer au moins deux approbateurs | Recommande | Avant | Automatique | `exchange` - Microsoft 365 E5 (ou module complementaire Microsoft 365 E5 Conformite) | oui |
| 74 | Établir la géographie effective des données Copilot et la Preferred Data Location des utilisateurs en Multi-Geo | Recommande | Avant | Automatique | `graph` | oui |
| 75 | Garantir la préservation des interactions Copilot au départ d'un collaborateur (rétention ou conservation pour litige) | Recommande | Apres | Automatique | `exchange` | oui |
| 76 | Statuer sur les sous-traitants IA tiers et interdire les modèles en préversion avec rétention de données | Recommande | Avant | Manuel | `manual` | oui |
| 77 | Aligner le paramètre flex routing sur les exigences de souveraineté et la frontière de données européenne | Recommande | Avant | Manuel | `manual` | oui |
| 78 | Statuer sur le mode limité de Copilot dans les réunions Teams (analyse du ressenti des participants) | Recommande | Avant | Automatique | `graph` | oui |
| 79 | Décider explicitement de l'accès au programme Frontier (fonctionnalités Copilot en préversion) | Recommande | Apres | Manuel | `manual` | oui |

## SECURITE ET PROTECTION DES DONNEES

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 52 | Configurer les étiquettes de confidentialité (minimum 3 niveaux) et accorder les droits d'usage VIEW et EXTRACT aux populations Copilot | Bloquant | Avant et apres | Automatique | `purview` | oui |
| 53 | Publier les labels vers les utilisateurs Copilot | Bloquant | Avant | Automatique | `purview` | oui |
| 54 | Activer l'auto-labeling pour les nouveaux fichiers | Recommande | Avant | Automatique | `purview` | oui |
| 55 | Configurer des politiques DLP couvrant les 4 workloads et l'emplacement Microsoft 365 Copilot | Bloquant | Avant et apres | Automatique | `purview` | oui |
| 56 | Configurer la rétention des interactions Copilot sur les emplacements IA de Purview | Recommande | Avant | Automatique | `purview` | oui |
| 57 | Configurer la rétention des journaux d'audit (>= 180 jours) et couvrir les types d'enregistrement IA | Recommande | Avant | Automatique | `purview` | oui |
| 58 | Vérifier eDiscovery sur les données Copilot : accessibilité de l'API, gestionnaires nommés et recherche des interactions | Optimal | Apres | Automatique | `graph` - Microsoft Purview eDiscovery (Premium) | oui |
| 59 | Générer et suivre les rapports de gouvernance d'accès aux données SharePoint | Recommande | Avant et apres | Automatique | `sharepoint` - SharePoint Advanced Management (incluse avec Microsoft 365 Copilot) | oui |
| 60 | Activer les étiquettes de confidentialité pour les fichiers Office dans SharePoint et OneDrive | Bloquant | Avant | Automatique | `sharepoint` | oui |
| 66 | Déployer DSPM for AI : stratégies par défaut et détection de l'usage à risque de l'IA | Recommande | Avant et apres | Automatique | `purview` - Microsoft Purview (E5 ou module complémentaire Insider Risk Management) | oui |

## SHAREPOINT ET ONEDRIVE

| # | Exigence | Priorite | Phase | Mode | Source interrogee | Notee |
| ---: | --- | --- | --- | --- | --- | :---: |
| 16 | Configurer le partage global SharePoint et la portée des liens de partage par défaut | Bloquant | Avant | Automatique | `sharepoint` | oui |
| 17 | Configurer l'expiration des liens anonymes à 7 jours maximum | Recommande | Avant | Automatique | `sharepoint` | oui |
| 18 | Identifier et restreindre le sur-partage réel des sites SharePoint | Bloquant | Avant et apres | Automatique | `sharepoint` - SharePoint Advanced Management (incluse avec Microsoft 365 Copilot) | oui |
| 19 | Provisionner OneDrive pour tous les utilisateurs Copilot | Recommande | Avant | Automatique | `sharepoint` | oui |
| 20 | Vérifier que l'index sémantique restitue du contenu (sonde Retrieval) | Bloquant | Avant et apres | Automatique | `graph` - Microsoft 365 Copilot | oui |
| 21 | Contrôler l'exclusion de la découverte Copilot (Restricted Content Discovery) | Recommande | Avant et apres | Automatique | `sharepoint` - SharePoint Advanced Management (incluse avec Microsoft 365 Copilot) | oui |
| 22 | Vérifier la sortie de Restricted SharePoint Search | Recommande | Avant et apres | Automatique | `sharepoint` | oui |
| 23 | Configurer le quota OneDrive à 1 To minimum | Optimal | Avant | Automatique | `sharepoint` | oui |
| 61 | Masquer les revendications de partage à l'échelle de l'organisation dans le sélecteur de personnes | Recommande | Avant | Automatique | `sharepoint` | oui |
| 62 | Couvrir par Restricted Content Discovery les sites sensibles non encore remédiés | Recommande | Avant | Automatique | `sharepoint` - SharePoint Advanced Management (incluse avec Microsoft 365 Copilot) | oui |
| 63 | Statuer explicitement sur la portée de Copilot in SharePoint (KnowledgeAgentScope) | Recommande | Avant et apres | Automatique | `sharepoint` - Microsoft 365 Copilot | oui |
| 64 | Inventorier les agents créés dans SharePoint et les sites qui les concentrent | Recommande | Apres | Automatique | `sharepoint` - SharePoint Advanced Management (incluse avec Microsoft 365 Copilot) | oui |


