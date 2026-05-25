# DLP triage - Copilot discovery and shadow AI risk

Owner: Marcus Olsson
Classification: Highly Confidential - Security
Synthetic lab marker: MHDEMO-2026-05-PURVIEW

## Situation

Priya is expected to search for analytics inputs across workforce, sales, legal, and operations content. If she finds executive or HR planning data, the root issue is likely oversharing. The security team should correlate Purview, Defender XDR, and Sentinel evidence.

## Synthetic indicators

Fake values for policy validation:

- social security number: 234-56-7890
- credit card number: 4532 0123 4567 8901
- bank routing number: 021000021
- bank account number: 1234567890
- EIN employer identification number: 98-7654321
- email: incident.demo@corplab.com

## Investigation pivots

1. Purview Activity Explorer: user `priya.sharma@contoso.example`, workloads SharePoint, OneDrive, Teams, Copilot.
2. Defender Advanced Hunting: file access around seeded document names.
3. Sentinel analytic rule: repeated access to sensitive seeded documents by Priya.
4. Entra ID: group membership and SharePoint permission inheritance.

## Recommended containment

- Remove broad sharing links from workforce planning drafts.
- Apply `Confidential - HR` or `Highly Confidential` sensitivity labels.
- Restrict Executive AI Risk and Operations Legal AI channels to required members.
- Create a sanitized dataset for Priya's model.
