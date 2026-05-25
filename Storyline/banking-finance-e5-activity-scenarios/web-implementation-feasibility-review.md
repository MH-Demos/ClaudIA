# Web Implementation Feasibility Review

## Proposito

Este documento valida los 30 escenarios de `complex-scenarios.json` contra el Storyline y contra las capacidades que ya existen en el repositorio. El foco es separar que puede implementarse via web en corto plazo, que requiere una expansion mediana de los BrowserAgents o de Graph, y que debe quedar para largo plazo por depender de Endpoint DLP, Defender for Endpoint, Windows 365/VMs, Conditional Access real, o integraciones de cumplimiento mas profundas.

La clasificacion asume un tenant demo sintetico con licenciamiento Microsoft 365 E5, los usuarios definidos en `config/agents.json`, y la carpeta `BrowserAgents` como base para ejecucion web con Playwright.

## Capacidades Existentes Relevantes

Actualmente el repo ya tiene piezas utiles para una implementacion web inicial:

| Capacidad | Evidencia en repo | Implicancia |
|---|---|---|
| Usuarios del Storyline, incluyendo Devon | `config/agents.json` y sesiones en `BrowserAgents/.auth` | Se puede ejecutar actividad por persona sin crear desde cero toda la identidad. |
| SharePoint, Teams y Exchange via Graph | `modules/Invoke-AgentRunbook.ps1`, `modules/Provision-M365Collaboration.ps1` | Permite crear archivos, posts, correos y telemetria sin depender solo del navegador. |
| Etiquetas y DLP core | `modules/Provision-SensitivityLabels.ps1`, `modules/Configure-CoreDLP.ps1`, `modules/Configure-DLP.ps1` | Se pueden modelar escenarios de labeling y DLP, aunque las senales reales pueden demorar. |
| BrowserAgents para Office/OWA/Copilot/Internal AI | `BrowserAgents/tests/*.spec.js` | Ya hay base para OWA, Copilot Web, Office Web e interaccion de AI controlada. |
| ADX y Activity Story Map | `config/agents.json`, `tools/Get-BrowserAgentTelemetry.ps1`, `activity-story-map` | Permite mostrar narrativa aunque parte de la senal sea sintetica. |
| Planes de escenario browser-agent | `browser-agent-task-plans.json` | Ya hay 10 escenarios priorizados en formato ejecutable conceptual. |

## Criterios De Clasificacion

| Horizonte | Definicion practica |
|---|---|
| Corto plazo | Implementable con SharePoint/OneDrive/Teams/Outlook/Office Web/Copilot Web/Internal AI, Graph existente, y telemetria ADX sintetica o semirreal. No requiere endpoint administrado. |
| Mediano plazo | Implementable via web, pero requiere nuevos runners o pasos especificos para Lists, Forms, Planner, Power BI, Whiteboard, Loop, Stream, Teams private channels, guest access, o dashboards. |
| Largo plazo | Requiere Endpoint DLP real, Defender for Endpoint, Intune, Windows 365/VM, USB/print/network share reales, risky sign-in/Conditional Access reales, o integracion profunda con Compliance/Defender/Sentinel. |

## Hallazgos De Alineacion Con Storyline

- Devon Reyes ya existe en `config/agents.json` y tiene sesion browser guardada. Aunque `profiles.md` aun no lo documenta, la implementacion lo puede usar.
- El Storyline original prioriza QBR, HR oversharing, Copilot descubriendo contenido excesivo y customer escalation. Los escenarios bancarios expanden esa misma logica hacia AML, KYC, loan committee, board, audit y operaciones.
- Hay una diferencia a corregir: algunos departamentos de `config/agents.json` no coinciden semanticamente con `profiles.md` porque parecen haber heredado dominios de contenido anteriores. Ejemplo: Ana aparece en departamento HR aunque el perfil la define como Head of IT/Security. Esto no bloquea los escenarios, pero conviene normalizarlo antes de dashboards ejecutivos.
- Para "todo lo que pueda ser implementado via web", la mejor frontera inicial es: SharePoint/OneDrive, Outlook Web, Teams Web, Office Web, Copilot Web e Internal AI Workbench. Endpoint queda como telemetria sintetica hasta tener VM/Windows 365.

## Matriz De Viabilidad De Los 30 Escenarios

| ID | Escenario | Horizonte recomendado | Implementacion web viable | Dependencias o bloqueos |
|---|---|---|---|---|
| BF-SCEN-0001 | Weekly Loan Committee Package Oversharing | Corto | Crear archivos Office en SPO, post Teams, correo externo, enlace amplio, etiqueta y evento DLP sintetico/real. | Requiere folder/site de Loan Committee y recipients externos controlados. |
| BF-SCEN-0002 | Monthly AML Review Workbook Download and External AI Upload | Corto | SPO/OneDrive/Excel Web + Internal AI Workbench o Foundry simulado + ADX. | Defender for Cloud Apps real puede quedar sintetico al inicio. |
| BF-SCEN-0003 | Customer Complaint Case Shared with Internal Notes | Mediano | Lists/SharePoint/Word Web/Teams/Outlook son web. | Falta runner robusto para Microsoft Lists y manejo fino de comentarios/adjuntos. |
| BF-SCEN-0004 | Power BI Customer-Level Credit Export | Mediano | Power BI Web + export a Excel/CSV + Outlook/SharePoint. | Requiere workspace/report/dataset Power BI y permiso de export configurado. |
| BF-SCEN-0005 | Treasury Reconciliation Workbook Printed and Copied | Largo | Parcial web: abrir/descargar desde SharePoint. | Print, network share y Endpoint DLP real dependen de endpoint administrado. |
| BF-SCEN-0006 | Regulatory Response Draft Shared Before Legal Approval | Corto | Word Web/SPO/Teams/Outlook/labels funcionan via web o Graph. | Records Management real puede simularse inicialmente. |
| BF-SCEN-0007 | HR Compensation Data Surfaced Through Copilot | Mediano | SPO/Excel Web/Copilot Web y acceso de Devon son web. | DSPM for AI y permisos heredados requieren validacion de tenant; Copilot no esta asignado a Devon. |
| BF-SCEN-0008 | Customer Onboarding KYC Packet Sent to Vendor | Corto | SPO/Outlook/Teams/DLP/labels. | Usar dominios externos controlados o `.test`; DLP real depende de politicas activas. |
| BF-SCEN-0009 | Suspicious Activity Review Copied to USB | Largo | Parcial web: acceso y descarga. | USB copy y Endpoint DLP requieren VM/Windows 365/Intune. |
| BF-SCEN-0010 | Vendor Due Diligence Package with Excessive Access | Mediano | Teams/SPO/Planner/Outlook via web. | Guest access y remediation necesitan runner/admin flow adicional. |
| BF-SCEN-0011 | Branch Operations Report Shared to Broad Distribution List | Mediano | Power BI Web, SharePoint, Outlook, Teams. | Requiere Power BI operativo y export gobernado. |
| BF-SCEN-0012 | Loan Exception Tracker Exposed Through Microsoft List Export | Mediano | Lists export + SPO + Outlook son web. | Falta automatizacion especifica para Lists/export. |
| BF-SCEN-0013 | Finance Close Evidence Collection and Label Downgrade | Corto | SPO/Excel/Outlook/labels/DLP; el runbook ya modela cambios de etiqueta. | Confirmar nombres de labels y permisos para aplicar/downgradear. |
| BF-SCEN-0014 | Collections Case Notes in Teams Chat | Mediano | Teams Web/Chat + SPO/Outlook. | Communication Compliance real requiere politica; en MVP usar ADX sintetico. |
| BF-SCEN-0015 | Executive Board Deck Built from Sensitive Source Files | Mediano | PowerPoint Web/SPO/Copilot Web. | Power BI source y Copilot grounding real requieren contenido indexado y licencias adecuadas. |
| BF-SCEN-0016 | Fraud Investigation Whiteboard Exported Externally | Mediano | Whiteboard Web/Teams/SPO/Outlook. | Falta runner Whiteboard y export estable; DLP puede ser sintetico. |
| BF-SCEN-0017 | Security Awareness Example Accidentally Uses Realistic Sensitive Patterns | Mediano | Viva Engage/PowerPoint/SharePoint/Teams son web. | Falta runner Viva Engage y Communication Compliance. |
| BF-SCEN-0018 | Meeting Recording Transcript Contains Customer Data | Largo | Parcial mediano si se simula transcript como archivo en Stream/SPO. | Recording/transcript real exige reuniones, Stream y gobernanza de grabaciones. |
| BF-SCEN-0019 | External Consultant Added to Risk Committee Team | Mediano | Teams/SPO/Entra guest access via web/admin. | Requiere cuentas guest controladas y automatizacion de membresia/remocion. |
| BF-SCEN-0020 | Forms-Based Customer Complaint Intake Captures Sensitive Data | Mediano | Forms Web + Excel export + SPO + DLP. | Falta runner Forms/export y control de sharing externo. |
| BF-SCEN-0021 | Privileged Legal Memo Copied into Loop Component | Mediano | Loop Web/Teams/SPO/Word Web. | Falta runner Loop y senales Purview pueden ser limitadas. |
| BF-SCEN-0022 | Unusual Sign-In Followed by Sensitive File Access | Largo | Parcial web: acceso y descarga de archivo. | Risky sign-in, CA y Defender XDR reales requieren configuracion de identidad/seguridad. |
| BF-SCEN-0023 | Customer Risk Model Feature Matrix Shared with Data Vendor | Corto | SPO/OneDrive/Excel/Outlook/Copilot Web; ya existe task plan. | DLP block real depende de politicas; correo externo debe ser controlado. |
| BF-SCEN-0024 | Executive Assistant Sends Board Appendix to Wrong Audience | Corto | Outlook Web/SPO/PowerPoint/labels/DLP. | La figura "assistant" puede mapearse a Sofia o al propio Alexander. |
| BF-SCEN-0025 | Audit Evidence Package Downloaded After Role Change Notice | Largo | Parcial web: HR email, descarga, copia OneDrive, investigacion en Teams. | Print/network share/Endpoint DLP e Insider Risk real quedan para endpoint/IRM. |
| BF-SCEN-0026 | Customer Support Email Includes Transaction Monitoring Details | Corto | Outlook Web/Teams/SPO + DLP sintetico/real. | Communication Compliance real puede quedar para mediano plazo. |
| BF-SCEN-0027 | M&A Banking Strategy Workspace Overexposed | Mediano | SPO/Teams private channel/Office Web/Copilot. | Private channels, permisos de workspace y Copilot exposure requieren hardening de runner. |
| BF-SCEN-0028 | Policy Exception Request with Sensitive Attachments | Mediano | Forms/Planner/Teams/SPO. | Falta runner Forms/Planner y flujo de access review. |
| BF-SCEN-0029 | Sanitized Dataset Replaced by Raw Dataset Before Demo | Mediano | SPO/Excel/Teams/Outlook; Power BI opcional. | Para demo fuerte requiere Power BI workspace/report. |
| BF-SCEN-0030 | End-to-End Devon Risk Chain Across Banking Operations | Largo | Subconjunto web implementable en corto: SPO, Outlook, Copilot/AI, Teams, ADX. | La version completa incluye endpoint, risky sign-in, Insider Risk y Defender. |

## Priorizacion Recomendada Via Web

### Ola 1 - Corto Plazo

Implementar primero los escenarios que producen una historia fuerte sin endpoint:

| Orden | Escenario | Por que va primero |
|---:|---|---|
| 1 | BF-SCEN-0002 | Es el caso mas claro de Shadow AI/AML y ya calza con Internal AI Workbench. |
| 2 | BF-SCEN-0013 | Valida sensibilidad, label downgrade, correo y DLP. Es muy Purview. |
| 3 | BF-SCEN-0001 | Cubre SharePoint, Teams, Outlook y oversharing bancario visible. |
| 4 | BF-SCEN-0023 | Raw vs anonymized, vendor externo, DLP y Copilot. Muy demostrable. |
| 5 | BF-SCEN-0024 | Error de audiencia ejecutiva, board material y remediacion. |
| 6 | BF-SCEN-0008 | KYC packet a vendor, simple y potente para DLP/etiquetas. |
| 7 | BF-SCEN-0006 | Legal/regulatory draft antes de aprobacion. |
| 8 | BF-SCEN-0026 | Customer support + transaction monitoring details, ideal para OWA. |

### Ola 2 - Mediano Plazo

Agregar workloads web que aun no tienen runners maduros:

| Workload | Escenarios candidatos |
|---|---|
| Microsoft Lists | BF-SCEN-0003, BF-SCEN-0012 |
| Power BI | BF-SCEN-0004, BF-SCEN-0011, BF-SCEN-0015, BF-SCEN-0029 |
| Forms y Planner | BF-SCEN-0020, BF-SCEN-0028, BF-SCEN-0010 |
| Teams guest/private channels | BF-SCEN-0010, BF-SCEN-0019, BF-SCEN-0027 |
| Loop/Whiteboard/Viva/Stream | BF-SCEN-0016, BF-SCEN-0017, BF-SCEN-0018, BF-SCEN-0021 |

### Ola 3 - Largo Plazo

Mantener como narrativa sintetica hasta que exista endpoint administrado:

| Tipo de dependencia | Escenarios |
|---|---|
| Endpoint DLP, print, USB, network share | BF-SCEN-0005, BF-SCEN-0009, BF-SCEN-0025, BF-SCEN-0030 |
| Conditional Access/risky sign-in real | BF-SCEN-0022, BF-SCEN-0030 |
| Defender for Endpoint/XDR real | BF-SCEN-0005, BF-SCEN-0009, BF-SCEN-0022, BF-SCEN-0025, BF-SCEN-0030 |
| Insider Risk Management real | BF-SCEN-0002, BF-SCEN-0005, BF-SCEN-0007, BF-SCEN-0009, BF-SCEN-0025, BF-SCEN-0030 |

## Recomendacion De Implementacion Tecnica

Para avanzar sin esperar endpoint:

1. Crear un `scenarioCatalog` reducido para Ola 1 con los 8 escenarios de corto plazo.
2. Extender `BrowserAgents/lib/contentPack.js` para poder leer `banking-finance-e5-activity-scenarios/complex-scenarios.json` o un derivado filtrado.
3. Crear runners Playwright por patron, no por escenario individual:
   - `sharepoint-office-file-flow`
   - `owa-external-email-flow`
   - `teams-post-flow`
   - `copilot-or-internal-ai-flow`
   - `purview-synthetic-review-flow`
4. Emitir siempre `ScenarioId`, `CorrelationId`, `PersonaName`, `Workload`, `Operation`, `SensitivityLabel`, `RiskScore` y `IsSynthetic` a ADX.
5. Para cada evento endpoint pendiente, emitir `ImplementationMode = SyntheticEndpointPlaceholder` hasta tener VM/Windows 365.

## Decision Para El Storyline

Los 30 escenarios son validos como universo narrativo, pero no todos deben convertirse en automatizacion live inmediatamente.

La propuesta mas saludable es:

- Corto plazo: 8 escenarios web completos o casi completos.
- Mediano plazo: 14 escenarios web ampliados con nuevos runners.
- Largo plazo: 8 escenarios con dependencia fuerte de endpoint, identidad avanzada o Defender/IRM real.

Esto mantiene el Storyline coherente, permite demostrar valor rapido en web, y no bloquea la vision de cyber-range completa.
