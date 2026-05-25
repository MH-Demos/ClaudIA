# Deploy-AdxTelemetry.ps1

## Purpose

Provisions Azure Data Explorer telemetry for agent activity: cluster, database, table, JSON mapping, streaming ingestion policy, and Database Ingestor assignment for the configured application.

## Execution

```powershell
.\tools\Deploy-AdxTelemetry.ps1
.\tools\Deploy-AdxTelemetry.ps1 -WhatIf
.\tools\Deploy-AdxTelemetry.ps1 -ClientSecret '<secret>'
```

## Parameters

- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `TenantId`: ADX/application tenant ID override.
- `ClientId`: app client ID override.
- `ClientSecret`: client secret value to store.
- `ClientSecretName`: Key Vault secret name. Default `agent-client-secret`.
- `M365Scope`: OAuth scope. Default `https://manage.office.com/.default`.
- `PreferredSku`: ADX SKU. Default `Dev(No SLA)_Standard_E2a_v4`.
- `WhatIf`: preview.

## Installer Integration

Called by `Install-ClaudIA.ps1` immediately after Step `4` Azure infrastructure.

## Current Configuration

- Cluster: `adx-claudia-lab`
- Database: `ADX-CLAUDIA`
- Table: `CLAUDIA_Activity`
- Mapping: `CLAUDIA_Activity_mapping`

