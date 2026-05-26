# MDCA Cloud Discovery ADX Log Collector Pilot

## Objetivo

Validar si la telemetria sintetica que ya se ingiere en ADX puede transformarse
en logs de trafico compatibles con Microsoft Defender for Cloud Apps (MDCA)
Cloud Discovery, para que aparezcan en:

```text
Cloud apps > Cloud discovery > Discovered apps
```

Este piloto no reemplaza MDE ni demuestra trafico real de endpoint. Demuestra
si MDCA puede clasificar eventos derivados de ADX cuando se presentan como logs
de firewall/proxy o como un formato custom.

## Base Documental

Microsoft documenta que Cloud Discovery analiza logs de trafico web contra el
catalogo de aplicaciones cloud de MDCA. Las fuentes soportadas incluyen:

- Microsoft Defender for Endpoint integration.
- Log Collector para automatic log upload.
- Firewalls/proxies/SWG soportados.
- Cloud Discovery API para subir archivos de log.

Referencias oficiales:

- Cloud app discovery overview:
  https://learn.microsoft.com/en-us/defender-cloud-apps/set-up-cloud-discovery
- Configure automatic log upload using Docker on Windows:
  https://learn.microsoft.com/en-us/defender-cloud-apps/discovery-docker-windows
- Use a custom log parser:
  https://learn.microsoft.com/en-us/defender-cloud-apps/custom-log-parser
- Cloud discovery API:
  https://learn.microsoft.com/en-us/defender-cloud-apps/api-discovery

## Hipotesis

Si exportamos eventos de `CLAUDIA_Activity` desde ADX hacia un CSV o syslog
con campos de trafico web suficientes, MDCA deberia poder:

- Parsear el archivo o stream mediante un custom parser.
- Asociar dominios conocidos con apps del catalogo.
- Mostrar usuarios, IPs, transacciones y volumen aproximado.
- Mostrar apps custom si se registran dominios internos o no catalogados.

## Lo Que No Valida

Este piloto no valida que:

- El trafico haya salido realmente desde un endpoint administrado.
- MDE haya observado la conexion.
- Endpoint DLP o Network Protection hayan aplicado controles.
- La IP origen sea la IP real de una VM o usuario final.

Para eso se mantiene el camino recomendado de Windows 365 / AVD / VM con MDE
onboarded.

## Arquitectura Del Piloto

```text
BrowserAgents / Runbooks
        |
        v
ADX: CLAUDIA_Activity
        |
        v
KQL export: MDCA discovery CSV
        |
        +--> Opcion A: Snapshot upload con Custom log format
        |
        +--> Opcion B: Cloud Discovery API
        |
        +--> Opcion C: Log Collector via FTP/Syslog
```

## Campos Minimos Recomendados

MDCA descarta campos extra, pero necesita campos de trafico que pueda mapear a
su modelo. Para un parser custom, usar un CSV con encabezados estables:

```csv
event_time,username,source_ip,target_url,target_host,target_ip,http_method,action,total_bytes,uploaded_bytes,downloaded_bytes,user_agent
```

Campos propuestos:

| Campo | Origen ADX / default | Comentario |
| --- | --- | --- |
| `event_time` | `TimeGenerated` | Debe coincidir con el formato elegido en el parser. |
| `username` | `Event.ActorUPN` o `Event.UserPrincipalName` | Idealmente UPN real del tenant. |
| `source_ip` | `Event.SourceIp` o valor sintetico | Necesario para usuarios/IPs en Cloud Discovery. |
| `target_url` | Derivado de `TargetDomain`, `SiteUrl`, `AppName`, workload | Mejor si incluye esquema y ruta. |
| `target_host` | Host parseado de `target_url` | Ayuda a clasificacion por dominio. |
| `target_ip` | Opcional/sintetico | Util si no hay URL. |
| `http_method` | `GET`, `POST`, `PUT` segun operation | Uploads suelen mapear mejor a POST/PUT. |
| `action` | `allowed` | Mantener simple para discovery. |
| `total_bytes` | Estimado por operation | Debe ser numerico. |
| `uploaded_bytes` | Estimado por upload/send/paste | Importante para recursos y volumen. |
| `downloaded_bytes` | Estimado por download/open | Importante para volumen. |
| `user_agent` | Edge/Chrome desktop | Opcional, util para realismo. |

## KQL De Export Inicial

Este query proyecta la tabla actual `CLAUDIA_Activity`, que guarda el evento
normalizado dentro de la columna dinamica `Event`.

```kusto
let defaultSourceIp = "10.50.10.25";
let defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36 Edg/125.0";
CLAUDIA_Activity
| where TimeGenerated > ago(24h)
| extend e = todynamic(Event)
| extend
    username = coalesce(tostring(e.ActorUPN), tostring(e.UserPrincipalName), tostring(e.AgentUPN)),
    operation = tostring(e.Operation),
    workload = tostring(e.Workload),
    rawTargetDomain = tostring(e.TargetDomain),
    siteUrl = tostring(e.SiteUrl),
    appName = tostring(e.AppName)
| extend target_host = case(
    isnotempty(rawTargetDomain), rawTargetDomain,
    siteUrl has "sharepoint.com", extract(@"https?://([^/]+)", 1, siteUrl),
    workload =~ "SharePoint", "contoso.sharepoint.com",
    workload =~ "Exchange" or operation has "Email", "outlook.office.com",
    workload =~ "Teams", "teams.microsoft.com",
    workload has "Copilot", "m365.cloud.microsoft",
    isnotempty(appName), strcat(replace_string(tolower(appName), " ", ""), ".example.com"),
    "www.office.com"
)
| extend
    target_url = strcat("https://", target_host, "/"),
    http_method = case(
        operation has "Upload" or operation has "Sent" or operation has "Paste", "POST",
        operation has "Download", "GET",
        operation has "FileModified" or operation has "SensitivityLabel", "PUT",
        "GET"
    ),
    uploaded_bytes = case(
        operation has "Upload", 5242880,
        operation has "Sent" or operation has "Paste", 262144,
        0
    ),
    downloaded_bytes = case(
        operation has "Download" or operation has "Open", 3145728,
        65536
    )
| extend total_bytes = uploaded_bytes + downloaded_bytes
| project
    event_time = format_datetime(TimeGenerated, "yyyy-MM-dd HH:mm:ss"),
    username,
    source_ip = tostring(coalesce(e.SourceIp, defaultSourceIp)),
    target_url,
    target_host,
    target_ip = "",
    http_method,
    action = "allowed",
    total_bytes,
    uploaded_bytes,
    downloaded_bytes,
    user_agent = defaultUserAgent
```

## Opcion A: Snapshot Manual Con Custom Parser

Esta es la prueba mas rapida y con menor infraestructura.

1. Exportar el resultado KQL a CSV.
2. En Microsoft Defender Portal:

   ```text
   Cloud Apps > Cloud Discovery > Actions > Create Cloud Discovery snapshot report
   ```

3. Seleccionar `Custom log format`.
4. Mapear los encabezados CSV a los campos del dialogo.
5. Subir el CSV.
6. Esperar procesamiento y validar el Snapshot report.

Criterio de exito:

- MDCA procesa el archivo sin errores.
- Apps conocidas aparecen clasificadas por dominio.
- El reporte muestra usuarios, source IPs, transacciones y volumen.

## Opcion B: Cloud Discovery API

Esta opcion automatiza la subida de archivos generados desde ADX.

Flujo oficial:

1. `GET /api/v1/discovery/upload_url/`
2. `PUT` del archivo al URL retornado.
3. `POST /api/v1/discovery/done_upload/`

Notas:

- Para el primer intento automatizado, conviene generar un archivo compatible
  con `GENERIC_CEF` o `GENERIC_W3C`, o mantener el parser custom asociado al
  data source.
- El API necesita un token de MDCA.
- `inputStreamName` debe corresponder al nombre del data source o snapshot.

Criterio de exito:

- El archivo se sube y finaliza correctamente.
- El reporte continuo o snapshot se actualiza sin intervencion manual.

## Opcion C: Log Collector

Esta opcion simula mejor el camino de produccion de Cloud Discovery.

### ClaudIA Step 10

The public installer exposes this path as optional Step 10:

```powershell
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 10 -SkipPrerequisites
```

Step 10 asks for:

- MDCA portal URL, for example `https://<tenant>.portal.cloudappsecurity.com`.
- MDCA API token from Defender for Cloud Apps.
- Input stream name, for example `ClaudIA ADX Cloud Discovery`.

The portal URL and token are stored in Azure Key Vault as `mdca-portal-url` and
`mdca-api-token`. The non-secret connector settings are written to
`config/agents.json` under `mdca`.

After Step 10, upload a current ADX snapshot with:

```powershell
.\tools\Invoke-MdcaCloudDiscoveryIngestion.ps1
```

1. Crear un data source en:

   ```text
   Settings > Cloud Apps > Cloud Discovery > Automatic log upload > Data sources
   ```

2. Elegir `Custom log format` si el CSV/syslog no coincide con un appliance
   soportado.
3. Crear un Log Collector y asociarlo al data source.
4. Desplegar el collector Docker siguiendo el comando generado por el portal.
5. Enviar logs exportados desde ADX al receiver configurado:

   - FTP/FTPS: escribir archivos CSV periodicos.
   - Syslog UDP/TCP/TLS: emitir una linea por evento.

Criterio de exito:

- El collector queda en estado `Connected`.
- El Governance log muestra uploads periodicos.
- El continuous report recibe datos.

## Riesgos Y Controles

| Riesgo | Mitigacion |
| --- | --- |
| MDCA no reconoce dominios no catalogados | Crear custom apps con dominios especificos. |
| CSV no parsea por headers o fechas | Mantener nombres case-sensitive y formato fijo. |
| Volumen artificial distorsiona reportes | Usar snapshot report primero; separar data source de laboratorio. |
| Se interpreta como trafico real | Etiquetar data source como synthetic/lab y documentar limitaciones. |
| Falta IP origen real | Usar rangos IP reservados para laboratorio y crear IP tags. |

## Recomendacion

Ejecutar en este orden:

1. Snapshot manual con CSV custom desde ADX.
2. API upload para automatizar el mismo CSV.
3. Log Collector continuo solo si el snapshot demuestra que el parser y la
   clasificacion funcionan.
4. Comparar contra un piloto MDE real desde Windows 365 / AVD para diferenciar
   "clasificacion de logs" versus "telemetria real de endpoint".

## Implementacion Inicial En Este Repo

Scripts agregados:

| Script | Proposito |
| --- | --- |
| `tools\Test-MdcaCloudDiscoveryApi.ps1` | Valida token, URL y endpoints read-only/upload-init de MDCA. |
| `tools\Export-MdcaDiscoveryLogFromAdx.ps1` | Exporta eventos de `CLAUDIA_Activity` como log CEF sintetico. |
| `tools\Upload-MdcaCloudDiscoveryLog.ps1` | Ejecuta el flujo API de MDCA: initiate, PUT y finalize. |

Archivo temporal de credenciales esperado:

```text
%TEMP%\mdca-cloud-discovery.local.json
```

Ese archivo debe mantenerse fuera del repositorio y tratarse como secreto.

Comandos usados para el primer piloto:

```powershell
.\tools\Test-MdcaCloudDiscoveryApi.ps1
.\tools\Test-MdcaCloudDiscoveryApi.ps1 -ProbeUploadUrl
.\tools\Export-MdcaDiscoveryLogFromAdx.ps1 -SinceMinutes 1440 -Top 100
.\tools\Upload-MdcaCloudDiscoveryLog.ps1 `
  -Path .\out\mdca-adx-pilot.cef `
  -InputStreamName 'ADX Synthetic MDCA Pilot 2026-05-25' `
  -UploadAsSnapshot
```

Resultado inicial:

- El token respondio correctamente contra `/api/discovery/streams/`.
- MDCA retorno 4 streams, incluido `Defender-managed endpoints`.
- El endpoint `/api/v1/discovery/upload_url/` respondio correctamente.
- Se genero `out\mdca-adx-pilot.cef` con 100 eventos desde ADX.
- La carga snapshot fue finalizada correctamente.
- El procesamiento de MDCA queda asincronico y debe validarse en el portal.
