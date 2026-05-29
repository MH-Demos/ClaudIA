# Storyline

This folder contains the human-centered narrative layer of ClaudIA.

ClaudIA is not only a collection of scripts. It is a demo and learning platform where synthetic personas create activity that can be investigated, governed, visualized, and explained.

The Storyline folder explains who the personas are, what they do, why their actions matter, and how their activity supports Microsoft 365 security and governance demos.

## What This Folder Is For

Use this folder to understand or maintain:

- Persona profiles.
- Demo narratives.
- Investigation paths.
- Workshop storylines.
- Security and compliance scenarios.
- Purview, Defender, Sentinel, ADX, and AI-governance talking points.
- Scenario packs for specific industries or demos.

## Start Here

| File or folder | Purpose |
| --- | --- |
| `profiles.md` | Official persona profile list and organization model. |
| `live_demo_runbook_defender_purview.md` | Demo flow for Defender and Purview-oriented presentations. |
| `banking-finance-e5-activity-scenarios` | Extended scenario pack for banking, finance, Purview, DLP, AI, and investigation stories. |

For a public-friendly persona explanation, also read:

- [../docs/personas.md](../docs/personas.md)

## Official Persona Model

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

## How To Use Storylines

A good ClaudIA storyline should answer:

1. Which persona is acting?
2. What business task are they trying to complete?
3. Which Microsoft 365 or AI service is involved?
4. What data is created, shared, modified, or exposed?
5. Which security signal is generated?
6. Which tool helps explain or investigate it?
7. What should the audience learn?

## Devon Reyes And Risk Narratives

Devon Reyes is the controlled risky-behavior persona.

Use Devon to create explainable scenarios around:

- Shadow AI.
- DLP violations.
- Suspicious sharing.
- Incorrect handling of sensitive information.
- Insider Risk investigation flows.
- AI governance and acceptable-use discussions.

Devon should not be described as a real attacker. Devon is a fictional internal user used for controlled simulation.

## Maintenance Rules

When adding or changing a storyline:

1. Keep all names, organizations, customers, cases, and data fictional.
2. Link the storyline to one or more personas.
3. Link the storyline to one or more Microsoft 365 or Azure services.
4. Describe the expected security or governance signal.
5. Update `profiles.md` if persona behavior changes.
6. Update `config/agents.json` if automation behavior changes.
7. Update Activity Story Map assets or documentation when the visual story changes.

## Public-Safety Rule

Do not include real customer data, real legal cases, real employee details, real screenshots with tenant identifiers, or production investigation details in storyline files.

Storyline material should be realistic enough to teach, but fictional enough to publish safely.
