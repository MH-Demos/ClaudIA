# ClaudIA - Persona Profiles

ClaudIA uses fictional personas to create realistic Microsoft 365 activity in a controlled lab tenant. Each persona has a role, reporting relationship, workload focus, and security narrative. The personas are synthetic and must not be confused with real employees.

The personas help explain how normal work, risky behavior, AI usage, collaboration, and data movement appear across Microsoft 365, Microsoft Purview, Microsoft Defender, Azure Data Explorer, and the ClaudIA Activity Story Map.

## Organization Model

```text
Alexander Meyer
├── Emily Johnson
├── James Wilson
│   ├── Diego Martinez
│   │   ├── Carlos Delgado
│   │   └── Sofia Lopez
│   └── Laura Gomez
│       ├── David Chen
│       └── Miguel Santos
└── Marcus Olsson
    └── Ana Rodriguez
        ├── Devon Reyes
        └── Priya Sharma
```

## Alexander Meyer

- **UPN:** alexander.meyer@contoso.example
- **Role:** CEO
- **Location:** Stockholm, Sweden
- **Department:** Executive Leadership
- **Workload focus:** Microsoft Teams / executive collaboration
- **Licenses:** Microsoft 365 E5 + Copilot
- **Reports to:** Board / not modeled in the lab
- **Direct reports:** Emily Johnson, James Wilson, Marcus Olsson
- **Persona purpose:** Provides executive context for AI risk, sensitive data governance, and cross-functional decision-making.
- **Security narrative:** Represents leadership exposure to strategic files, AI governance decisions, and executive communications.

## Emily Johnson

- **UPN:** emily.johnson@contoso.example
- **Role:** Corporate Lawyer
- **Location:** New York, USA
- **Department:** Legal
- **Workload focus:** Chat / legal collaboration
- **Licenses:** Microsoft 365 E5 + Copilot
- **Reports to:** Alexander Meyer
- **Direct reports:** None
- **Persona purpose:** Creates legal, policy, contract, and privacy-related activity.
- **Security narrative:** Helps generate legal-document handling, privileged communication, retention, and confidentiality scenarios.

## James Wilson

- **UPN:** james.wilson@contoso.example
- **Role:** Director of Operations
- **Location:** Toronto, Canada
- **Department:** Engineering / Operations
- **Workload focus:** SharePoint Online
- **Licenses:** Microsoft 365 E5
- **Reports to:** Alexander Meyer
- **Direct reports:** Diego Martinez, Laura Gomez
- **Persona purpose:** Connects business operations, engineering workflows, and cross-team collaboration.
- **Security narrative:** Supports scenarios involving operational documents, internal projects, engineering artifacts, and data-sharing patterns.

## Diego Martinez

- **UPN:** diego.martinez@contoso.example
- **Role:** Sales Manager
- **Location:** Santiago, Chile
- **Department:** Finance / Commercial
- **Workload focus:** Microsoft Lists
- **Licenses:** Microsoft 365 E5 + Copilot
- **Reports to:** James Wilson
- **Direct reports:** Carlos Delgado, Sofia Lopez
- **Persona purpose:** Generates commercial, pipeline, customer, and financial planning activity.
- **Security narrative:** Supports oversharing, customer data, proposal, pricing, and sales-forecasting scenarios.

## Carlos Delgado

- **UPN:** carlos.delgado@contoso.example
- **Role:** Data Analyst
- **Location:** Mexico City, Mexico
- **Department:** Finance
- **Workload focus:** SharePoint Online
- **Licenses:** Microsoft 365 E5
- **Reports to:** Diego Martinez
- **Direct reports:** None
- **Persona purpose:** Produces analytics and finance-related files used in reporting and investigation demos.
- **Security narrative:** Helps generate payment, budget, expense, and report content for DLP and sensitivity-labeling scenarios.

## Sofia Lopez

- **UPN:** sofia.lopez@contoso.example
- **Role:** Project Manager
- **Location:** Buenos Aires, Argentina
- **Department:** PMO
- **Workload focus:** Teams / External AI scenarios
- **Licenses:** Microsoft 365 E5
- **Reports to:** Diego Martinez
- **Direct reports:** None
- **Persona purpose:** Coordinates project updates, meetings, timelines, and cross-functional collaboration.
- **Security narrative:** Supports project-document sharing, AI-assisted summarization, and collaboration governance scenarios.

## Laura Gomez

- **UPN:** laura.gomez@contoso.example
- **Role:** HR Manager
- **Location:** Bogotá, Colombia
- **Department:** Engineering / HR scenario owner
- **Workload focus:** Microsoft Fabric
- **Licenses:** Microsoft 365 E5 + Copilot
- **Reports to:** James Wilson
- **Direct reports:** David Chen, Miguel Santos
- **Persona purpose:** Bridges people-data scenarios, analytics, and internal reporting.
- **Security narrative:** Supports employee-data exposure, HR reporting, Fabric analytics, and data minimization discussions.

## David Chen

- **UPN:** david.chen@contoso.example
- **Role:** Customer Operations Specialist
- **Location:** Lima, Peru
- **Department:** Legal / Customer Operations
- **Workload focus:** SharePoint Online
- **Licenses:** Microsoft 365 E5
- **Reports to:** Laura Gomez
- **Direct reports:** None
- **Persona purpose:** Generates support, case review, customer escalation, and document-handling activity.
- **Security narrative:** Supports privacy audits, customer records, operational case files, and information-sharing scenarios.

## Miguel Santos

- **UPN:** miguel.santos@contoso.example
- **Role:** Platform Engineer
- **Location:** São Paulo, Brazil
- **Department:** IT / Infrastructure
- **Workload focus:** SharePoint Online / External AI scenarios
- **Licenses:** Microsoft 365 E5
- **Reports to:** Laura Gomez
- **Direct reports:** None
- **Persona purpose:** Represents technical operations, platform support, logs, scripts, and infrastructure documentation.
- **Security narrative:** Supports sensitive operational data, debug logs, infrastructure notes, and AI-assisted troubleshooting scenarios.

## Marcus Olsson

- **UPN:** marcus.olsson@contoso.example
- **Role:** Cybersecurity Manager
- **Location:** Stockholm, Sweden
- **Department:** Sales / Security scenario owner
- **Workload focus:** SharePoint Online
- **Licenses:** Microsoft 365 E5
- **Reports to:** Alexander Meyer
- **Direct reports:** Ana Rodriguez
- **Persona purpose:** Provides the security leadership side of the storyline.
- **Security narrative:** Supports investigation, governance, security review, and cross-functional risk management scenarios.

## Ana Rodriguez

- **UPN:** ana.rodriguez@contoso.example
- **Role:** Head of IT / Security
- **Location:** Madrid, Spain
- **Department:** HR / IT Security scenario owner
- **Workload focus:** SharePoint Online
- **Licenses:** Microsoft 365 E5
- **Reports to:** Marcus Olsson
- **Direct reports:** Devon Reyes, Priya Sharma
- **Persona purpose:** Acts as an operational security and IT lead in the demo environment.
- **Security narrative:** Helps connect user behavior, security policy, governance controls, and investigation workflows.

## Devon Reyes

- **UPN:** devon.reyes@contoso.example
- **Role:** Business Operations Analyst
- **Location:** Not fixed / lab-defined
- **Department:** Operations Support
- **Workload focus:** External AI / controlled risky activity simulation
- **Licenses:** Microsoft 365 E5
- **Reports to:** Ana Rodriguez
- **Direct reports:** None
- **Persona purpose:** Generates activity that may be considered risky, suspicious, incorrect, or policy-violating from a security perspective.
- **Security narrative:** Devon is not an external attacker. Devon is a fictional internal persona used to create controlled investigation material for DLP, Insider Risk, Shadow AI, oversharing, exfiltration, and AI-governance demos.

## Priya Sharma

- **UPN:** priya.sharma@contoso.example
- **Role:** Data Scientist
- **Location:** Bangalore, India
- **Department:** Sales / Analytics scenario owner
- **Workload focus:** Meetings / browser-agent pilot
- **Licenses:** Microsoft 365 E5 + Copilot
- **Reports to:** Ana Rodriguez
- **Direct reports:** None
- **Persona purpose:** Generates analytics, meeting, AI-assisted productivity, and browser-driven activity.
- **Security narrative:** Supports Copilot readiness, sensitive-data discovery, browser automation, and productivity-versus-governance scenarios.

## Maintenance Guidance

When adding or changing personas:

1. Update this file.
2. Update [../docs/personas.md](../docs/personas.md).
3. Update [../config/agents.json](../config/agents.json).
4. Update persona images under `Images/Characters`.
5. Republish Activity Story Map assets if the visual portal is enabled.
6. Keep all people fictional and all sample domains generic.
