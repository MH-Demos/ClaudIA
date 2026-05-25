# Legal memo - employee data in AI-assisted analysis

Author: Emily Johnson
Matter: Controlled AI data use review
Classification: Confidential - Legal
Synthetic lab marker: MHDEMO-2026-05-PURVIEW

## Legal position

Employee-level data should not be pasted into non-approved AI services. Microsoft 365 Copilot may be used only where the underlying permissions, labels, and DLP policies allow appropriate access. Any model development workflow that uses employee compensation, bank information, or identity data requires minimization and approval.

## Examples used for Purview detection

These examples are fake lab records:

- Employee: Hannah Lewis
- social security number: 567-89-0123
- bank routing number: 121000248
- bank account number: 9021187345
- phone: (415) 555-0198
- email: hannah.lewis@corplab.com
- driver's license number: D12345678

Additional synthetic record:

- Employee: Omar Reed
- SSN: 678-90-1234
- passport number: C12345678
- account number: 10024588912

## Guidance

1. Create sanitized datasets before Priya uses the data in model feature engineering.
2. Apply the correct sensitivity label to workforce and legal documents.
3. Use DLP policy tips to block or warn on risky sharing.
4. Record the incident path in Defender XDR and Sentinel if sensitive data is exposed.
