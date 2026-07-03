# =============================================================================
# FILE TYPE TEMPLATES (document types per department)
# Locale-aware: HR/Finance/Legal/Sales loaded from AgentLocale variable.
# Engineering templates are universal (data engineering patterns, same everywhere).
# =============================================================================

# Load locale-specific file types for business departments
$fileTypes = @{}
if ($locale -and $locale.fileTypes) {
    foreach ($dept in @('HR','Finance','Legal','Sales')) {
        if ($locale.fileTypes.$dept) {
            $fileTypes[$dept] = @($locale.fileTypes.$dept | ForEach-Object {
                @{ Type = $_.Type; Ext = $_.Ext; Prompt = $_.Prompt }
            })
        }
    }
    Write-Output "File types loaded from $country locale: $($fileTypes.Keys -join ', ')"
}

# Fallback: LEGACY FRENCH defaults (pre-locale deployments). Only used when
# the AgentLocale variable is absent or missing a department; the locale load
# above already raised a visible error when the whole locale is missing.
$legacyFileTypeDepts = @('HR','Finance','Legal','Sales') | Where-Object { -not $fileTypes[$_] }
if ($legacyFileTypeDepts.Count -gt 0) {
    Write-Warning "File types for $($legacyFileTypeDepts -join ', ') use the legacy FRENCH fallback. Re-run Step 5 (Deploy-Runbook.ps1) to publish a complete locale."
}
if (-not $fileTypes['HR']) {
    $fileTypes['HR'] = @(
        @{ Type='Paie_Mensuelle';       Ext='.csv'; Prompt='Generate a monthly payroll CSV with semicolons: Employe;NIR;IBAN;Salaire_Brut;Date. Include 6-10 rows.' }
        @{ Type='Fiche_Employe';        Ext='.txt'; Prompt='Generate a confidential employee file with full name, NIR, IBAN, annual salary, home address, start date.' }
        @{ Type='Onboarding_Checklist'; Ext='.txt'; Prompt='Generate an onboarding checklist with NIR, IBAN for salary, manager name, equipment list.' }
        @{ Type='Rapport_Absences';     Ext='.csv'; Prompt='Generate an absence report CSV: Employe;Type;Debut;Fin;NIR. Include 5-8 rows.' }
        @{ Type='DPAE_Declaration';     Ext='.txt'; Prompt='Generate a DPAE with employee NIR, birth date, IBAN, contract type (CDI/CDD).' }
        @{ Type='Entretien_Annuel';     Ext='.txt'; Prompt='Generate an annual review with employee name, NIR, objectives, salary, IBAN for bonus.' }
        @{ Type='Registre_Personnel';   Ext='.csv'; Prompt='Generate a personnel register: Nom;Prenom;NIR;Date_Entree;Poste;IBAN;Salaire. 8-12 rows.' }
        @{ Type='Scan_Bulletin_Paie';   Ext='.png'; Prompt='SCAN' }
        @{ Type='Scan_Badge_Employe';   Ext='.png'; Prompt='SCAN' }
    )
}
if (-not $fileTypes['Finance']) {
    $fileTypes['Finance'] = @(
        @{ Type='Virements_Fournisseurs'; Ext='.csv'; Prompt='Generate a supplier payment CSV: Fournisseur;IBAN;Montant;Devise;Reference. 6-8 suppliers.' }
        @{ Type='Rapport_Financier';     Ext='.txt'; Prompt='Generate a quarterly financial report with revenue, costs, treasury IBAN, EU VAT number.' }
        @{ Type='DSN_Mensuelle';         Ext='.csv'; Prompt='Generate a DSN CSV: Employe;NIR;Net_Imposable;Prelevement;IBAN. 5-8 rows.' }
        @{ Type='Notes_Frais';           Ext='.txt'; Prompt='Generate an expense report with employee name, reimbursement IBAN, itemized expenses.' }
        @{ Type='Budget_Previsionnel';   Ext='.txt'; Prompt='Generate a budget forecast with salary costs, treasury IBAN, department breakdowns.' }
        @{ Type='Facture';               Ext='.txt'; Prompt='Generate an invoice with supplier details, IBAN, VAT number, line items, total HT/TTC.' }
        @{ Type='Scan_Facture';          Ext='.png'; Prompt='SCAN' }
    )
}
if (-not $fileTypes['Legal']) {
    $fileTypes['Legal'] = @(
        @{ Type='Audit_CNIL';          Ext='.txt'; Prompt='Generate a CNIL audit report listing 4-6 persons with their NIR, findings, corrective actions.' }
        @{ Type='Contrat_CDI';         Ext='.txt'; Prompt='Generate an employment contract (CDI) with employee NIR, IBAN, salary, working hours.' }
        @{ Type='Registre_RGPD';       Ext='.txt'; Prompt='Generate a GDPR register entry for payroll: data types (NIR,IBAN), legal basis, retention.' }
        @{ Type='Contentieux';         Ext='.txt'; Prompt='Generate a litigation file with plaintiff NIR, claimed amount, case timeline, settlement IBAN.' }
        @{ Type='Avis_Juridique';      Ext='.txt'; Prompt='Generate a legal opinion about data protection, referencing specific employee NIR in breach.' }
        @{ Type='NDA';                 Ext='.txt'; Prompt='Generate an NDA with party names, addresses, confidential info description, penalty amounts.' }
    )
}
if (-not $fileTypes['Sales']) {
    $fileTypes['Sales'] = @(
        @{ Type='Pipeline_Commercial';  Ext='.csv'; Prompt='Generate a sales pipeline CSV: Client;Contact;Email;IBAN;Montant_Contrat. 5-8 prospects.' }
        @{ Type='Proposition_Commerciale'; Ext='.txt'; Prompt='Generate a commercial proposal with client details, payment IBAN, quote amount HT/TTC.' }
        @{ Type='Commissions';           Ext='.csv'; Prompt='Generate a commission report CSV: Commercial;Client;CA;Commission;IBAN_Commission. 4-6 rows.' }
        @{ Type='CR_Reunion_Client';     Ext='.txt'; Prompt='Generate client meeting notes with attendees, budget, next steps, IBAN for advance.' }
        @{ Type='Liste_Prospects';       Ext='.txt'; Prompt='Generate a prospect list with company names, contact, email, phone, estimated value.' }
        @{ Type='RFP_Response';          Ext='.txt'; Prompt='Generate an RFP response with credentials, pricing, bank details (IBAN), references.' }
    )
}

# Engineering file types are UNIVERSAL (data engineering and platform patterns)
$fileTypes['Engineering'] = @(
        @{ Type='TestData_PII';          Ext='.csv';  Prompt='Generate a test data CSV: EmployeeId;Name;SSN;Bank_Routing;Bank_Account;Email;Phone;Department;Birth_Date;Address. Include 8-15 rows with realistic fake US PII. Use the keyword social security number near SSN values.' }
        @{ Type='Customer_Dataset';      Ext='.csv';  Prompt='Generate a customer dataset CSV: CustomerId;Company;Contact_Name;Contact_Email;Phone;EIN;Contract_Value;Region;Account_Manager. Include 10-15 realistic business records.' }
        @{ Type='Data_Access_Audit';     Ext='.csv';  Prompt='Generate a data access audit log CSV: Timestamp;User;Action;Table;Columns_Accessed;Row_Count;Source_IP. Include suspicious patterns such as bulk exports, after-hours access, and HR salary table reads.' }
        @{ Type='Payroll_Dataset';       Ext='.csv';  Prompt='Generate a payroll dataset CSV: EmployeeId;Name;SSN;Bank_Routing;Bank_Account;Gross_Pay;Net_Pay;Payment_Date;Tax_ID;Address. Include 15-25 rows with realistic fake US PII.' }
        @{ Type='Vendor_Master_Data';    Ext='.csv';  Prompt='Generate a vendor master data CSV: Vendor;EIN;Bank_Routing;Bank_Account;Contact_Email;Phone;Address;Annual_Spend;Payment_Terms. Include 12-18 vendors.' }
        @{ Type='PII_Anomaly_Report';    Ext='.csv';  Prompt='Generate a PII anomaly detection CSV: Detection_Date;Source;PII_Type;Detected_Value;Column;Severity;Status. Include SSN, routing number, account number, credit card, and email examples.' }
        @{ Type='Schema_JSON';           Ext='.json'; Prompt='Generate a JSON schema for an employee data model with fields employeeId, fullName, ssn, bankRouting, bankAccount, email, phone, department, salary. Include example values with realistic fake PII.' }
        @{ Type='Pipeline_Config';       Ext='.json'; Prompt='Generate a JSON ETL pipeline configuration with extract, transform, mask PII, validate email format, and load stages. Include fake connection strings, retry policy, schedule, and column mappings.' }
        @{ Type='OpenAPI_Spec';          Ext='.json'; Prompt='Generate an OpenAPI 3.0 JSON spec for an HR payroll API. Include request/response schemas with SSN, bank routing/account, salary, and payment date fields.' }
        @{ Type='Masking_Config';        Ext='.json'; Prompt='Generate a JSON data masking configuration with rules for SSN, bank account, routing number, email, phone, and credit card. Include sample input/output pairs.' }
        @{ Type='Security_Incident';     Ext='.md';   Prompt='Generate a Markdown security incident report with timeline, impact, root cause, containment, remediation, and KQL queries. Include fake SSN and bank account examples found in logs.' }
        @{ Type='Architecture_Doc';      Ext='.md';   Prompt='Generate a Markdown architecture document for an HR analytics platform with sections for sources, transformations, storage, consumption, identity, logging, and a Mermaid diagram.' }
        @{ Type='Data_Quality_Report';   Ext='.md';   Prompt='Generate a Markdown data quality report with metrics, anomalies, trend analysis, corrective actions, and a table of sensitive data quality findings.' }
        @{ Type='Dashboard_DQ';          Ext='.html'; Prompt='Generate an HTML data quality dashboard with inline CSS, metric cards, anomaly table, and data lineage footer. Include examples of sensitive data findings.' }
        @{ Type='Employee_Profile_Card'; Ext='.html'; Prompt='Generate an HTML employee profile card with inline CSS. Include employee ID, department, job title, SSN, bank routing/account, email, phone, and address using realistic fake data.' }
        @{ Type='Lineage_Diagram';       Ext='.svg';  Prompt='Generate a valid SVG data lineage diagram showing HR source systems -> ETL pipeline -> Fabric Lakehouse -> Power BI report. Include field labels such as SSN, bankAccount, email, salary.' }
        @{ Type='Debug_Log';             Ext='.txt';  Prompt='Generate a debug log with ISO timestamps showing ETL processing of employee records. Include INFO/WARN/ERROR lines, masked and unmasked PII examples, and failed validation records.' }
        @{ Type='Migration_Log';         Ext='.txt';  Prompt='Generate a data migration log from a legacy HR system to a lakehouse. Include migrated record IDs, SSN validation, bank account validation, status OK/FAILED, and realistic fake values.' }
        @{ Type='ACH_Payment_XML';       Ext='.xml';  Prompt='Generate a valid XML payment batch with employee/vendor names, bank routing numbers, bank account numbers, amounts, references, and creation date.' }
    )
