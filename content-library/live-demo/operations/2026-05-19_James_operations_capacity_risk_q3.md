# Q3 operations capacity risk

Owner: James Wilson
Classification: Confidential - Operations
Synthetic lab marker: MHDEMO-2026-05-PURVIEW

## Context

Operations is reviewing delivery capacity for strategic customers. The model requested by Priya can help correlate delivery risk, staffing, sales commitments, and support backlog. The current draft still contains employee-level fields and should be sanitized before use.

## Risk table

| Region | Customer | Delivery risk | Staffing signal | Sensitive field present |
| --- | --- | --- | --- | --- |
| North America | Contoso Health | High | two support roles frozen | SSN and salary band |
| LATAM | Fabrikam Retail | Medium | one manager reassigned | bank account for relocation stipend |
| Europe | Northwind Energy | High | contractor conversion pending | driver's license number |

## Synthetic data sample

The following values are fake:

```text
Employee: Grace Miller
social security number: 789-01-2345
routing number: 026009593
account number: 5544332211
salary band: USD 145000-160000
phone: (212) 555-0142
```

## Security note

If Priya finds this through Copilot, the result should be treated as an oversharing signal, not a Copilot bypass. Validate SharePoint permissions, label status, DLP events, and related Defender evidence.
