# Synthetic Microsoft 365 / Purview Content Pack

This folder contains structured fictional content used to generate Microsoft 365 and Microsoft Purview demo activity.

The content pack helps ClaudIA create realistic documents, emails, prompts, chat threads, labels, sharing events, and business scenarios without using production data.

## Purpose

A Microsoft 365 security demo needs realistic content. Empty files and generic messages rarely show how DLP, sensitivity labels, Insider Risk, AI governance, and investigations work in practice.

This content pack provides fictional material that can be used to exercise signals such as:

- File creation.
- File modification.
- Email creation.
- Teams or chat-style collaboration.
- Sensitivity labeling.
- External sharing.
- AI / Copilot-style prompts.
- Risky or incorrect data handling.
- Purview DLP and investigation scenarios.

## Important Safety Rule

All names, organizations, customers, identifiers, financial values, support cases, HR records, invoices, bank-like numbers, personal data patterns, incidents, contracts, and operational examples must remain fictional.

Do not mix this content pack with real production data.

Do not replace fictional values with:

- Real secrets.
- Real employee data.
- Real customer data.
- Real credentials.
- Real regulated records.
- Real legal cases.
- Real financial account data.

## Recommended File Layout

| File | Purpose |
| --- | --- |
| `content-pack.json` | Combined top-level JSON object. |
| `email-subjects.json` | Grouped subject library. |
| `email-templates.json` | Reusable email templates. |
| `chat-threads.json` | Teams or chat-style conversations. |
| `documents.json` | Office/document generation briefs. |
| `ai-prompts.json` | Copilot and AI prompt library. |
| `external-sharing-scenarios.json` | External sharing simulations. |
| `labeling-scenarios.json` | Sensitivity label event simulations. |

Primary schema pattern:

```json
{
  "emailSubjects": [],
  "emailTemplates": [],
  "chatThreads": [],
  "documents": [],
  "aiPrompts": [],
  "externalSharingScenarios": [],
  "labelingScenarios": []
}
```

## Relationship To Personas

Content should be linked to ClaudIA personas whenever possible.

Example:

- Diego Martinez creates sales pipeline or proposal content.
- Carlos Delgado creates finance and reporting content.
- Emily Johnson creates legal and policy content.
- Laura Gomez creates HR and analytics content.
- Devon Reyes creates controlled risky or incorrect activity for investigation scenarios.

For persona guidance, see:

- [../docs/personas.md](../docs/personas.md)
- [../Storyline/profiles.md](../Storyline/profiles.md)

## Relationship To Security Scenarios

Each content item should ideally support one or more learning goals:

- DLP policy validation.
- Sensitivity label testing.
- Oversharing detection.
- Insider Risk investigation.
- AI governance discussion.
- Copilot readiness demonstration.
- Defender or Sentinel investigation flow.
- ADX telemetry analysis.

## Authoring Guidance

When adding new content:

1. Keep it fictional.
2. Make it realistic enough to trigger meaningful demo discussion.
3. Link it to a persona, department, service, or scenario.
4. Avoid real personal data, real company data, and real identifiers.
5. Use placeholders for domains, accounts, customers, and numbers.
6. Keep language clear and suitable for public documentation.
7. Update any schema or scenario documentation when structure changes.

## Lab Use Only

Use this content only inside controlled demo tenants or lab environments.

Before publishing updates, run:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```
