# =============================================================================
# CROSS-DEPARTMENT EMAIL SCENARIOS
# =============================================================================
$emailScenarios = @(
    @{ From='ana.rodriguez';      To='marcus.olsson';    Context='IT Security sends a DLP investigation summary. Include file names, alert IDs, user UPNs, endpoint names, and recommended containment actions. Mention whether Defender XDR escalation is required.' }
    @{ From='carlos.delgado';     To='priya.sharma';     Context='Data Analytics shares a dashboard extract for model validation. Include sales metrics, HR trend fields, data quality notes, and a warning that some draft fields may contain sensitive workforce planning data.' }
    @{ From='david.chen';         To='emily.johnson';    Context='Customer Operations requests legal guidance for a customer escalation. Include case IDs, customer contact details, contract references, support timeline, and business impact.' }
    @{ From='james.wilson';       To='alexander.meyer';  Context='Operations sends a QBR readiness note. Include operational metrics, delivery risks, vendor constraints, and three executive decisions needed before the meeting.' }
    @{ From='marcus.olsson';      To='ana.rodriguez';    Context='Cybersecurity reports a potential oversharing incident. Include SharePoint/OneDrive locations, affected departments, DLP policy names, and recommended remediation.' }
    @{ From='alexander.meyer';    To='james.wilson';     Context='The CEO asks for an executive summary of operational performance. Request a concise version suitable for Copilot summarization and board review.' }
    @{ From='diego.martinez';     To='james.wilson';     Context='Sales sends QBR pipeline details. Include client names, opportunity stages, forecast amounts in USD, close risks, and follow-up owners.' }
    @{ From='emily.johnson';      To='david.chen';       Context='Legal replies to a customer escalation. Include a privileged legal assessment, contractual risk, recommended customer response, and a note not to share externally.' }
    @{ From='laura.gomez';        To='ana.rodriguez';    Context='HR sends a salary planning data protection question. Include employee names, salary bands, SSN values with the keyword social security number, and bank routing/account examples for direct deposit.' }
    @{ From='priya.sharma';       To='diego.martinez';   Context='Data Science reports a Copilot-assisted insight. Include sales trend findings, possible restructuring signals discovered in overshared drafts, and questions about appropriate access.' }
    @{ From='sofia.lopez';        To='laura.gomez';      Context='Project Management follows up on the HR oversharing remediation plan. Include milestones, owners, and a request to restrict broad sharing before stakeholder review.' }
    @{ From='miguel.santos';      To='ana.rodriguez';    Context='Platform Engineering reports a configuration issue. Include system names, API endpoints, fake connection strings, log paths, and a risk note about secrets in documentation.' }
)

# Pre-build per-agent email scenario lookup (O(1) dispatch in main loop)
$emailScenariosBySam = @{}
foreach ($es in $emailScenarios) {
    if (-not $emailScenariosBySam.ContainsKey($es.From)) {
        $emailScenariosBySam[$es.From] = [System.Collections.Generic.List[hashtable]]::new()
    }
    $emailScenariosBySam[$es.From].Add($es)
}

# Business-context flavors mixed into email prompts so daily runs do not
# converge on near-identical subjects/bodies (each agent has only 1-2 fixed
# scenario contexts; temperature alone is not enough entropy).
$emailDayFlavors = @(
    'Quarter-end reporting deadlines are approaching and everyone is under time pressure.'
    'The company is preparing for an internal compliance audit next week.'
    'A post-incident review is underway following a recent security event.'
    'Annual budget planning discussions are in full swing.'
    'Several new hires joined this week and processes are being re-explained.'
    'A system migration is scheduled for the weekend and teams are coordinating.'
    'Performance review season has started across departments.'
    'A major client escalation is consuming attention across teams.'
    'Mandatory compliance training must be completed by end of month.'
    'Leadership requested tighter data-handling discipline after a near-miss.'
)

