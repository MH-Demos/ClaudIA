# Configure-CoreDLP.ps1

## Purpose

Deploys category-based core Microsoft Purview DLP policies across Exchange, SharePoint, OneDrive, Teams, Endpoint DLP, and Copilot.

## Execution

```powershell
.\modules\Configure-CoreDLP.ps1 -Config $config -Domain contoso.example
.\modules\Configure-CoreDLP.ps1 -Config $config -Domain contoso.example -EnforceMode
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 6 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `Domain`: tenant domain used for policy suffix.
- `EnforceMode`: changes policy mode from audit/test notifications to enabled mode where supported.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `6a`.

## DLP Categorization

The script groups DLP rules by data category, not just by individual sensitive information type. Current categories:

- `Payment Card Data`: high severity, confidence `85`, credit card/debit card/routing SITs.
- `Identity and Personal Data`: medium severity, confidence `75`, SSN, driver's license, passport, addresses, full names.
- `Sensitive Personal and Health Data`: high severity, confidence `75`, medical terms, DEA, Medicare MBI, ICD-10, lab test terms.
- `Financial and Tax Information`: high severity, confidence `75`, bank account, ABA routing, IBAN, SWIFT, ITIN.
- `Credentials and Access Secrets`: high severity, confidence `85`, API keys, Entra client secrets, GitHub PATs, login credentials.
- `Legal and Corporate Sensitive Information`: medium severity, confidence `75`, legal/corporate proxy identifiers.
- `Intellectual Property and Technical Information`: high severity, confidence `75`, IP addresses, Azure SQL connection strings, X.509 keys, client secrets, GitHub PATs.

For Exchange, SharePoint, OneDrive, and Teams the script creates internal and outbound rules per category. For Endpoint DLP and Copilot it creates one rule per category. Copilot also gets sensitivity-label based rules for `Confidential/Conf-HR` and `Confidential/Conf-Finance`.

## Policies Created

- `EXO Policy - <TENANT>`
- `SPO Policy - <TENANT>`
- `ODB Policy - <TENANT>`
- `Teams Policy - <TENANT>`
- `Endpoint Policy - <TENANT>`
- `Copilot Policy - <TENANT>`

