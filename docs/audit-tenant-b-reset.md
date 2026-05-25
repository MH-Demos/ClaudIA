# Audit d'execution — ClaudIA
## Tenant B Reset (MngEnvMCAP437602.onmicrosoft.com)
**Date** : 2026-05-07  
**Objectif** : Revue de code, identification des bugs, recommandations documentation  
**Mode** : End-user strict — aucune correction, aucun troubleshooting

---

## 1. ETAPES EXECUTEES (ordre reel)

### Pre-execution (README Steps 1-3)

| # | Commande | Resultat |
|---|----------|----------|
| 0a | `$PSVersionTable.PSVersion` | 7.6.1 — OK |
| 0b | `Get-ChildItem -Recurse -Filter *.ps1 \| Unblock-File` | OK (silencieux) |
| 0c | `az account show` | Deja connecte sur le bon tenant |

### Step 0 : Prerequisite Check (`.\prerequisites\Test-Prerequisites.ps1`)

| # | Check | Resultat | Detail |
|---|-------|----------|--------|
| 1 | Azure CLI installed | PASS | az 2.8x |
| 2 | Azure CLI logged in | PASS | nasenous@... |
| 3 | PowerShell 7+ | PASS | PS 7.6.1 |
| 4 | Az PowerShell module | **FAIL** | Module non installe |
| 5 | ExchangeOnlineManagement | PASS | |
| 6 | Subscription accessible | PASS | |
| 7 | Azure resource providers | PASS | Auto-registered |
| 8 | gpt-4o in eastus2 | PASS | |
| 9 | M365 E3/E5/E7 licenses | **FAIL** | TEST_SPE_E7 : 0 disponible |
| 10 | Copilot M365 licenses | **FAIL** | Non trouvees |
| 11 | Global Admin | PASS | |

**Score** : 8/11 (README annonce "13 validations")

### Step 1 : Create Agent Accounts

| Commande | `.\Install-AutonomousAgents.ps1` (wizard interactif) |
|----------|------|
| Config | Tenant: MngEnvMCAP437602.onmicrosoft.com, Sub: bb6dc1c7-..., Region: eastus2, Country: FR |
| 10 users | Tous `[EXISTS]` |
| Password genere | `JAhPqMoFwGQHtK1a` |

### Step 2 : Licenses + MFA Exclusion

| Action | Resultat |
|--------|----------|
| License SKU detecte | TEST_SPE_E7 (0 available) |
| Assignation | Tous "no seats left (tenant-wide)" |
| Groupe MFA | `[OK]` grp-agent-mfa-exclusion (4a82a554-...) |
| Ajout membres | "All agents added" |
| **Pause manuelle** | "Press Enter when done" (CA exclusion) |

### Step 3 : Register Entra App

| Action | Resultat |
|--------|----------|
| app-dataagent | `[EXISTS]` AppId: ee3f2822-a3dc-4be8-80e4-a84a9571fb6f |

### Step 4 : Deploy Azure Infrastructure

| Ressource | Resultat |
|-----------|----------|
| Resource Group rg-agents-lab | `[OK]` |
| Azure OpenAI oai-agents | `[EXISTS]` |
| Deploy gpt-4o (TPM=30) | `[OK]` |
| Automation Account aa-agents | `[EXISTS]` |
| OpenAI RBAC -> MI | `[OK]` |
| Log Analytics la-agents | `[OK]` (long ~60s) |
| OpenAI diagnostics | `[OK]` |
| **Sentinel on la-agents** | **`[WARN] 409 Conflict`** |
| Sentinel rule: High-Volume-Prompts | `[WARN]` |
| Sentinel rule: Off-Hours-Activity | `[WARN]` |
| Sentinel rule: Large-Token-Usage | `[WARN]` |
| Sentinel rule: Agent-Privilege-Escalation | `[WARN]` |
| Remediation runbook | `[OK]` |

### Step 4a : M365 Collaboration

| Action | Resultat |
|--------|----------|
| Teams team CorpLab - Departments | `[EXISTS]` 06000a79-... |
| Add 10 members | `[OK]` |
| SharePoint site | `[OK]` mngenvmcap437602.sharepoint.com,... |
| Department folders | `[OK]` 0 new folders |
| Team channels | `[OK]` 6 channels |
| AA variables stored | `[OK]` |

### Step 4b : Sensitivity Labels

| Action | Resultat |
|--------|----------|
| Connect-IPPSSession | Auto-connect OK (apres prompt "Try auto-connect?") |
| WARNING: OnAfterGetLabels | `failed to get template:[d9dfb868-...]` x3 |
| Label General | `[EXISTS]` |
| Label Confidential | `[EXISTS]` |
| Label Conf-HR | `[OK]` cree |
| Label Conf-Finance | `[OK]` cree |
| Label Highly Confidential | `[EXISTS]` |
| Labels total | 2 crees, 3 existaient |
| **Label Policy** | **`[FAIL]` "Please ensure presence of atleast one of ExchangeLocation or ModernGroupLocation in the policy."** |

### Step 4c : Fabric

| Action | Resultat |
|--------|----------|
| Fabric | `[DISABLED]` (fabricEnabled=false dans config) |

### Step 5 : Secrets + Runbook

| Action | Resultat |
|--------|----------|
| Password entre | JAhPqMoFwGQHtK1a |
| Locale | FR (SIT reference + file types + scan templates) |
| 17 encrypted variables | `[OK]` |
| Runbook upload | `[OK]` |
| Schedule daily-morning | `[OK]` |
| Schedule daily-midday | `[OK]` |
| Schedule daily-afternoon | `[OK]` |

### Step 6a : Core DLP Policies

| Action | Resultat |
|--------|----------|
| Tax ID SIT resolved | France Tax Identification Number (numero SPI.) |
| 8 DLP policies | Tous `[skip]` (deja existants) |
| Incident reports | admin@MngEnvMCAP437602.onmicrosoft.com |

### Step 6b : DSPM Policies (1er run)

| Action | Resultat |
|--------|----------|
| Connecting to S&C PS | `[MANUAL]` apres ~3-5 min de latence |
| 3 DSPM policies | **NON DEPLOYEES** — le script ne detecte pas la session IPPS |
| Instructions affichees | "Run manually: Connect-IPPSSession" |

> Le wizard a affiche `[MANUAL]` et a continue vers Step 6c (contrairement a mon observation initiale).

### Step 6c : IRM Policies (1er run)

| Action | Resultat |
|--------|----------|
| Prompt | "Deploy IRM policies? (Y/n)" — en attente d'input |

> Le terminal a ete tue pendant que Step 6c attendait l'input.

---

## REPRISE : `-Step 6 -SkipPrerequisites` (2e run)

Pre-requis : `Connect-IPPSSession` execute manuellement avant le wizard.

### Step 6a (re-run)

| Action | Resultat |
|--------|----------|
| 8 DLP policies | Tous `[skip]` (exists) — idempotent OK |

### Step 6b (re-run, avec IPPS pre-connectee)

| Action | Resultat |
|--------|----------|
| Connecting to S&C PS | **`[MANUAL]`** a nouveau (~5 min de latence) |
| 3 DSPM policies | **NON DEPLOYEES** |
| Observation | IPPS pre-connectee dans le meme terminal, mais `Configure-DLP.ps1` ne la detecte PAS |

### Step 6c : IRM Policies

| Action | Resultat |
|--------|----------|
| IRM-DataLeaks-Lab | **`[WARN]` "A parameter cannot be found that matches parameter name 'ThresholdLevel'"** |
| IRM-RiskyAI-Lab | **`[WARN]` "A parameter cannot be found that matches parameter name 'ThresholdLevel'"** |
| IRM Analytics | `[INFO]` enable manually |
| Instructions manuelles | Portail IRM : indicators, Priority User Groups, DSPM for AI |

### Step 7 : Workbook

| Action | Resultat |
|--------|----------|
| Deploy workbook | `[OK]` Agent Activity Monitor |
| Portal URL | `https://portal.azure.com/#resource/.../069c67a9-a534-4212-bca0-f392069db650/workbook` |

### Wizard final

```
================================================================
  DEPLOYMENT COMPLETE
================================================================
  Agents: 10 (5 Wave 1 + 5 Wave 2)
  Schedules: 3x daily
  Monitoring: Log Analytics + Sentinel + Workbook
```

---

## 2. CATALOGUE DES ERREURS

### ERR-001 : Prerequisite count mismatch
- **Contexte** : README.md
- **Message** : README annonce "13 validations" mais `Test-Prerequisites.ps1` n'execute que 11 checks
- **Impact** : Documentation trompeuse pour l'end user
- **Fichier** : `README.md` lignes ~86, ~620 + `prerequisites/Test-Prerequisites.ps1`

### ERR-002 : Password genere pour des users existants
- **Contexte** : Step 1, tous users `[EXISTS]`
- **Message** : "Password for all agents: JAhPqMoFwGQHtK1a / SAVE THIS PASSWORD"
- **Impact** : **CRITIQUE** — Le password affiche ne correspond a AUCUN user (les existants gardent leur ancien password). L'end user va l'entrer au Step 5 pensant que c'est le bon. Le runbook ROPC echouera systematiquement.
- **Fichier** : `Install-AutonomousAgents.ps1` ligne ~578

### ERR-003 : Label Policy creation failure
- **Contexte** : Step 4b, `Provision-SensitivityLabels.ps1`
- **Message** : `[FAIL] Please ensure presence of atleast one of ExchangeLocation or ModernGroupLocation in the policy.`
- **Impact** : Label policy non publiee. Les labels existent mais ne sont pas distribues aux utilisateurs.
- **Fichier** : `modules/Provision-SensitivityLabels.ps1`

### ERR-004 : Sentinel 409 Conflict
- **Contexte** : Step 4, `Deploy-AzureInfra.ps1`
- **Message** : `[WARN] Response status code does not indicate success: 409 (Conflict).`
- **Impact** : Fonctionnel — Sentinel deja active. Mais les 4 analytics rules affichent aussi `[WARN]` sans detail.
- **Fichier** : `modules/Deploy-AzureInfra.ps1`

### ERR-005 : OnAfterGetLabels template warnings
- **Contexte** : Step 4b
- **Message** : `WARNING: OnAfterGetLabels: failed to get template:[d9dfb868-...]` (repete 3 fois)
- **Impact** : Non bloquant mais confusant pour l'end user. Provient du module IPPS lui-meme.
- **Fichier** : `modules/Provision-SensitivityLabels.ps1`

### ERR-006 : DSPM IPPS session non detectee
- **Contexte** : Step 6b, `Configure-DLP.ps1`
- **Message** : `Connecting to Security & Compliance PowerShell... [MANUAL]`
- **Impact** : Le script ne detecte PAS la session IPPS existante (pre-connectee dans le meme terminal). Les 3 DSPM policies ne sont jamais deployees. Le script affiche `[MANUAL]` apres ~3-5 min de latence puis continue.
- **Fichier** : `modules/Configure-DLP.ps1`
- **Note** : Comportement identique sur les 2 runs (avec et sans pre-connexion IPPS).

### ERR-007 : IRM ThresholdLevel parameter deprecie
- **Contexte** : Step 6c, `Configure-IRM.ps1`
- **Message** : `[WARN] IRM-DataLeaks-Lab -- A parameter cannot be found that matches parameter name 'ThresholdLevel'`
- **Impact** : Les 2 policies IRM ne sont PAS creees. Le script affiche des instructions manuelles.
- **Fichier** : `modules/Configure-IRM.ps1`
- **Cause probable** : Le parametre `ThresholdLevel` de `New-InsiderRiskPolicy` a ete deprecie dans les versions recentes du module S&C PowerShell.

---

## 3. RECOMMANDATIONS DOCUMENTATION

### DOC-001 : Corriger "13 validations" → "11 checks"
- **Fichier** : `README.md` (EN + FR)
- **Action** : Remplacer "13 validations" par "11 checks" ou ajouter les 2 checks manquants

### DOC-002 : Documenter le comportement "users existants + password"
- **Fichier** : `README.md` section "Re-running the wizard"
- **Action** : Ajouter un avertissement explicite : "Si les users existent deja, le password genere par le wizard n'est PAS applique aux users. Vous devez connaitre le password actuel des agents ou le reinitialiser manuellement avant le Step 5."

### DOC-003 : Documenter le delai de propagation des labels
- **Fichier** : `README.md` + `modules/Provision-SensitivityLabels.ps1`
- **Action** : Ajouter : "Les labels prennent 24-48h pour se propager dans les apps Office. Le script mentionne cette info mais elle n'est pas dans la table des etapes du README."

### DOC-004 : Documenter l'etape manuelle Conditional Access
- **Fichier** : `README.md`
- **Action** : La table "Deployment Steps" dit Step 2 "Assign E5 + Copilot + MFA exclusion group" mais ne mentionne PAS l'etape manuelle CA. Ajouter une ligne "MANUAL" dans la table.

### DOC-005 : Documenter que Connect-IPPSSession est requis avant Steps 4b, 6a, 6b, 6c
- **Fichier** : `README.md` Prerequisites section
- **Action** : Ajouter : `Connect-IPPSSession` dans les pre-requis OU documenter que le wizard le fait automatiquement (avec potentiel popup navigateur)

### DOC-006 : Documenter les 4 warnings Sentinel comme attendus sur re-run
- **Fichier** : `README.md` Known Limitations ou troubleshooting.md
- **Action** : Ajouter : "Sentinel 409 Conflict et analytics rules [WARN] sont normaux lors d'un re-deploiement."

### DOC-007 : Ajouter une section "RESET tenant" dans le README
- **Fichier** : `README.md`
- **Action** : Documenter la procedure pour nettoyer completement un tenant avant re-deploiement (supprimer users, app registration, groupe MFA, DLP policies, labels, Azure resources)

### DOC-008 : Documenter le nombre reel de prompts interactifs
- **Fichier** : `README.md` section "Run the deployment wizard"
- **Action** : Le README dit "7. One manual pause at Step 2 / 8. One prompt at Step 5" mais il y a en realite ~20 prompts interactifs (config setup + choix C/E + DLP Y/n etc.)

### DOC-009 : Version francaise incomplete
- **Fichier** : `README.md` version francaise
- **Action** : La version FR dit "7 etapes de deploiement" alors qu'il y a 9 steps (4a/4b/4c + 6a/6b/6c). Harmoniser.

### DOC-010 : Ajouter un prerequis explicite pour Az module
- **Fichier** : `README.md`
- **Action** : Le module Az est dans les prerequisites (Step 1) mais le test dit [FAIL]. Le wizard continue quand meme. Documenter que Az est optionnel (utilise uniquement pour Manage-Costs.ps1?) ou le rendre obligatoire.

---

## 4. BUGS ET DEFAUTS IDENTIFIES

### BUG-001 : Password inutile genere sur re-run (CRITIQUE)
- **Script** : `Install-AutonomousAgents.ps1` ligne ~578
- **Description** : Quand tous les users sont `[EXISTS]`, le script genere quand meme un nouveau password et dit "SAVE THIS". Ce password n'est jamais applique aux users existants. L'utilisateur va l'entrer au Step 5 → les AA variables contiendront un mauvais password → le runbook ROPC echouera.
- **Fix suggere** : Si tous les users existent, demander le password actuel au lieu d'en generer un nouveau.

### BUG-002 : Label Policy creation echoue sans ExchangeLocation
- **Script** : `modules/Provision-SensitivityLabels.ps1`
- **Description** : `New-LabelPolicy` echoue avec "Please ensure presence of atleast one of ExchangeLocation or ModernGroupLocation in the policy." Le script ne passe pas `-ExchangeLocation All` ou `-ModernGroupLocation All`.
- **Fix suggere** : Ajouter `-ExchangeLocation All` au `New-LabelPolicy`.

### BUG-003 : IPPS session hang sur 2e connexion
- **Script** : `modules/Configure-DLP.ps1`
- **Description** : Le script tente Connect-IPPSSession alors qu'une session est deja active depuis Step 4b/6a. La 2e connexion bloque indefiniment sans timeout.
- **Fix suggere** : Verifier si une session IPPS est deja active avant de tenter Connect-IPPSSession. Utiliser `Get-PSSession` ou tester avec `Get-DlpCompliancePolicy` avant de reconnecter.

### BUG-004 : Wizard dit "9 steps" mais execute 12+ etapes
- **Script** : `Install-AutonomousAgents.ps1`
- **Description** : L'en-tete dit "Step X/9" mais il y a en realite Steps 0, 1, 2, 3, 4, 4a, 4b, 4c, 5, 6a, 6b, 6c, 7 = 13 etapes. Le denominateur "/9" est trompeur.
- **Fix suggere** : Mettre a jour la numerotation ou utiliser un denominateur correct.

### BUG-005 : Pas de timeout sur IPPS connection
- **Script** : `modules/Configure-DLP.ps1`, `modules/Configure-IRM.ps1`, `modules/Provision-SensitivityLabels.ps1`
- **Description** : Aucun timeout sur `Connect-IPPSSession`. Si l'auth echoue silencieusement, le script bloque indefiniment.
- **Fix suggere** : Ajouter un timeout (`-TimeoutSeconds 60`) ou un check de session pre-existante.

### BUG-006 : Sentinel rules [WARN] sans detail
- **Script** : `modules/Deploy-AzureInfra.ps1`
- **Description** : Les 4 analytics rules affichent `[WARN]` mais aucun message d'erreur n'est visible. L'end user ne peut pas savoir si c'est un probleme ou un comportement attendu.
- **Fix suggere** : Afficher le message d'erreur catch apres `[WARN]`.

### BUG-007 : agents.json ecrase avec "REPLACE_WITH" detecte meme apres config
- **Script** : `Install-AutonomousAgents.ps1`
- **Description** : A chaque run, le script detecte `REPLACE_WITH` dans agents.json et lance la config interactive. Mais il a deja sauvegarde la config precedente. C'est parce que la sauvegarde initiale remplace les placeholders — ce bug ne se produit qu'au 1er run. Confirme : pas de bug ici en re-run (la config est correcte).

### BUG-008 : Workbook creates duplicates on re-run
- **Script** : `modules/Deploy-Workbook.ps1`
- **Description** : (Code review) Chaque execution genere un nouveau GUID (`[guid]::NewGuid()`), creant des workbooks dupliques a chaque re-run.
- **Fix suggere** : Utiliser un GUID deterministe base sur le nom du workbook/RG.

### BUG-009 : Hardcoded SIT GUIDs (Configure-DLP.ps1)
- **Script** : `modules/Configure-DLP.ps1`
- **Description** : (Code review) Les GUIDs des SIT (NIR, IBAN, Tax ID) sont hardcodes. Ils peuvent varier par tenant/locale.
- **Fix suggere** : Resoudre dynamiquement via `Get-DlpSensitiveInformationType` comme le fait `Configure-CoreDLP.ps1`.

### BUG-010 : Non-ASCII characters stripped from runbook
- **Script** : `modules/Deploy-Runbook.ps1`
- **Description** : (Code review) `-replace '[^\x00-\x7F]', '-'` remplace tous les accents francais (e, a, etc.) par des tirets dans le contenu du runbook. Degrade la qualite des prompts AI et des SIT patterns.
- **Fix suggere** : Utiliser l'encodage UTF-8 pour l'upload du runbook au lieu de supprimer les accents.

### BUG-011 : IRM ThresholdLevel deprecie — policies jamais creees
- **Script** : `modules/Configure-IRM.ps1`
- **Description** : `New-InsiderRiskPolicy` avec `-ThresholdLevel 'L1'` echoue : "A parameter cannot be found that matches parameter name 'ThresholdLevel'". Les 2 policies IRM-DataLeaks-Lab et IRM-RiskyAI-Lab ne sont PAS creees.
- **Fix suggere** : Retirer le parametre `-ThresholdLevel` ou utiliser le parametre de remplacement selon la doc Microsoft actuelle.

### BUG-012 : Configure-DLP.ps1 ne detecte pas la session IPPS existante
- **Script** : `modules/Configure-DLP.ps1`
- **Description** : Le script tente une verification IPPS (~3-5 min) puis affiche `[MANUAL]` meme quand une session IPPS est deja active dans le meme terminal PowerShell. Les 3 DSPM policies ne sont jamais deployees automatiquement.
- **Fix suggere** : Utiliser `Get-PSSession | Where-Object { $_.ComputerName -match 'compliance' -and $_.State -eq 'Opened' }` pour detecter la session existante, ou tester directement avec `Get-DlpCompliancePolicy -ErrorAction SilentlyContinue`.

### BUG-013 : `-Step 6` re-execute aussi Step 7 (Workbook duplique)
- **Script** : `Install-AutonomousAgents.ps1`
- **Description** : La logique `if ($Step -le 7)` fait que `-Step 6` execute aussi Step 7. Le workbook est cree avec un nouveau GUID a chaque run, produisant des doublons.
- **Fix suggere** : Pour le workbook, utiliser un GUID deterministe ou verifier l'existence avant creation.

---

## 5. ATTENTES / DELAIS NON DOCUMENTES

| Moment | Delai observe | Documente ? |
|--------|---------------|-------------|
| Log Analytics creation | ~60s | Non |
| Teams team provisioning | ~5s (exists) | Partiellement (retry dans le script) |
| SharePoint site resolution | ~5s (exists) | Partiellement (retry dans le script) |
| Connect-IPPSSession | ~20s + popup navigateur | Non |
| Sensitivity labels propagation | 24-48h | Oui (dans le script, pas dans le README table) |
| Configure-DLP.ps1 IPPS check | ~3-5 min avant `[MANUAL]` | Non |
| DLP policy skip check (IPPS) | ~10-15s par policy | Non |

---

## 6. SCRIPTS NECESSITANT UNE EXECUTION MANUELLE

| Script | Raison |
|--------|--------|
| `Connect-IPPSSession` | Doit etre execute manuellement si le popup navigateur echoue |
| Conditional Access exclusion | Etape 100% manuelle dans le portail Entra |
| IRM > Settings > Policy indicators | Etape manuelle post-deploiement |
| IRM > Priority User Groups | Etape manuelle post-deploiement |
| DSPM for AI > Get started | Etape manuelle post-deploiement |

---

## 7. RESUME EXECUTIF

### Ce qui fonctionne bien
- Environment scan (detection de resources existantes) : excellent
- Idempotence Azure (RG, OpenAI, Automation, LA) : correct
- Idempotence DLP policies : correct (skip si existe)
- Config interactive avec sauvegarde : pratique
- Messages d'erreur globalement clairs

### Ce qui bloque un end-user
1. **BUG-001** : Password inutile sur re-run → runbook ROPC echouera
2. **BUG-002** : Label Policy non publiee → labels non distribues
3. **BUG-012** : DSPM IPPS non detectee → 3 policies jamais deployees, meme avec pre-connexion
4. **BUG-011** : IRM ThresholdLevel deprecie → 2 policies IRM jamais creees
5. **ERR-001** : "13 validations" inexact → confusion
6. **DOC-008** : Nombre de prompts interactifs sous-estime → experience utilisateur degradee

### Priorite de correction
1. **P0** : BUG-001 (password), BUG-012 (IPPS detection), BUG-011 (ThresholdLevel)
2. **P1** : BUG-002 (label policy), BUG-010 (non-ASCII), BUG-013 (workbook duplique)
3. **P2** : DOC-001 a DOC-010 (documentation)
4. **P3** : BUG-004 a BUG-009 (ameliorations)
