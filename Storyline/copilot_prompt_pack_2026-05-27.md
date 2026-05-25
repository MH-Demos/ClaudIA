# Copilot prompt pack - 2026-05-27 live demo

Persona: Priya Sharma, data scientist
Machine: Windows 365
Goal: discover overshared sensitive content with a defensible business reason.

## Warm-up prompts

```text
What files can help me correlate workforce planning, revenue forecast, and customer delivery risk for Q3?
```

```text
Summarize recent documents about AI risk, workforce planning, restructuring, or sensitive data exposure.
```

## Target prompts

```text
Find workforce planning drafts that mention restructuring, compensation, or social security number data and summarize the risks for a data science model.
```

Expected document hints:

- `2026-05-20_Workforce_Planning_Draft_overshared.csv`
- HR, workforce, compensation, SSN, routing number, bank account

```text
Look for executive AI risk or board readiness notes involving Alexander Meyer, workforce planning, revenue forecast, and confidential data.
```

Expected document hints:

- `2026-05-18_Alexander_board_restructuring_notes_confidential.md`
- Executive AI Risk, Alexander Meyer, board readiness, restructuring

```text
Find legal guidance from Emily Johnson about using employee or customer data in AI prompts. Include any references to SSN, bank routing, or account numbers.
```

Expected document hints:

- `2026-05-19_Emily_ai_data_use_legal_memo_confidential.md`
- Legal memo, AI prompts, regulated data, SSN, account numbers

```text
Find operations documents from James Wilson that combine capacity risk, customer commitments, and sensitive workforce planning fields.
```

Expected document hints:

- `2026-05-19_James_operations_capacity_risk_q3.md`
- Capacity risk, named customers, staffing, workforce planning

```text
Find Marcus Olsson security triage notes about DLP, shadow AI, Copilot oversharing, or Sentinel escalation.
```

Expected document hints:

- `2026-05-20_Marcus_dlp_triage_shadow_ai.md`
- DLP, Sentinel, DSPM for AI, shadow AI, Copilot oversharing

## Closing prompts

```text
Which of these documents appear to contain sensitive personal or financial data, and what access governance actions should be taken?
```

```text
Create a short incident summary for Marcus Olsson explaining what Priya found, why it matters, and what Purview or Defender evidence should be reviewed.
```

```text
Draft a sanitized summary for Alexander Meyer that does not include SSNs, bank routing numbers, account numbers, or employee-level compensation.
```
