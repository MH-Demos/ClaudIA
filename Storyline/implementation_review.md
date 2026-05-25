# Storyline Implementation Review

## Current Alignment

The lab now uses the persona roles from `profiles.md` as the source of truth for the existing agents in `config/agents.json`.

| Storyboard Scenario | Current Support | Recommended Optimization |
| --- | --- | --- |
| Quarterly Business Review | SharePoint uploads, Teams posts, Copilot-like Graph Search, executive email thread | Add PowerPoint/Excel-like QBR artifacts, calendar event, and executive summary workflow |
| HR Oversharing Risk | HR document generation, OneDrive/SharePoint-ready content, DLP-sensitive data patterns | Add OneDrive personal drafts and broad sharing links to reproduce oversharing |
| Priya Discovers Too Much | Copilot-like search, Data Science persona, HR/Sales sensitive content | Add scenario-specific search queries and Log Analytics scenario IDs |
| Customer Escalation | Email and Legal/Security collaboration now represented in threads | Add customer case documents, support exports, and Defender XDR handoff notes |

## Gaps In Existing Workflows

- The previous email scenarios used legacy French personas that no longer exist in the tenant.
- Several prompts were still French-first and referenced CNIL/NIR/IBAN while the tenant is configured for the US locale.
- Departments are now aligned to real profiles, so the collaboration provisioning must create folders/channels dynamically from `agents.json`.
- New storyline personas, such as Sofia Lopez and Miguel Santos, should be added only if matching users exist in Entra ID.

## Proposed Document Repository

Create a private GitHub repository to hold reusable source documents and scenario assets.

Suggested structure:

```text
content-library/
  en/
    executive/
    hr/
    legal/
    sales/
    security/
    operations/
    data-science/
  es/
    hr/
    legal/
    sales/
  pt/
    engineering/
  synthetic-sensitive-data/
    us/
    eu/
    latam/
```

## Pros

- Reusable documents reduce runbook generation time and Azure OpenAI cost.
- Versioning makes it easier to review, tune, and reuse scenarios.
- Multilingual folders support global demo stories without hardcoding everything in PowerShell.
- A content library can include clean source files, risky drafts, overshared files, and sanitized versions.
- Key Vault can store a GitHub fine-grained PAT or deploy key reference for private access.

## Cons And Risks

- A private repo introduces another secret lifecycle to manage.
- Generated high-volume content can drift away from Purview SIT precision unless validated.
- Pulling many files at runtime may slow Azure Automation jobs.
- If real-looking sensitive data is stored statically, the repo itself becomes part of the lab risk model.
- GitHub audit events may need to be considered if the demo includes external data movement.

## Recommended Approach

Use the repo as an optional content seed, not as the primary runtime dependency.

1. Generate and review document packs offline.
2. Store only synthetic data and clearly mark it as lab content.
3. During Step 5, optionally import selected document packs into Automation variables or a Storage Account.
4. At runtime, agents should blend reusable documents with small AI-generated edits, comments, summaries, or follow-up messages.
5. Add scenario IDs to each generated activity so dashboards can show storyline progress.

## Next Engineering Steps

1. Add OneDrive draft creation and broad sharing links for HR Oversharing Risk.
2. Add calendar events and meeting artifacts for Quarterly Business Review.
3. Add scenario IDs to `Push-AgentActivity`.
4. Add optional content-library import support.
5. Add endpoint simulation as a separate module after M365 workflows stabilize.
