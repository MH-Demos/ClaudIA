const fs = require('fs');
const path = require('path');

const browserRoot = path.resolve(__dirname, '..');
const defaultCatalogPath = path.join(browserRoot, 'scenarios', 'banking-finance-wave1.json');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function loadBankingWave1Catalog(catalogPath = process.env.BROWSER_AGENT_BANKING_SCENARIO_CATALOG || defaultCatalogPath) {
  const catalog = readJson(catalogPath);
  const scenarios = Array.isArray(catalog.scenarios) ? catalog.scenarios : [];
  return {
    metadata: catalog.metadata || {},
    defaults: catalog.defaults || {},
    scenarios
  };
}

function splitList(value) {
  return String(value || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizePersona(value) {
  return String(value || '').toLowerCase().trim();
}

function selectedScenarioIds() {
  return new Set(splitList(process.env.BROWSER_AGENT_BANKING_SCENARIOS).map((item) => item.toUpperCase()));
}

function scenarioMatchesPersona(scenario, persona) {
  const normalized = normalizePersona(persona);
  if (!normalized) return true;
  const actors = Array.isArray(scenario.actors) ? scenario.actors : [];
  return actors.map(normalizePersona).includes(normalized)
    || normalizePersona(scenario.primaryPersona) === normalized;
}

function selectScenariosForPersona(ctx, catalog = loadBankingWave1Catalog()) {
  const wanted = selectedScenarioIds();
  let scenarios = catalog.scenarios;
  if (wanted.size > 0) {
    scenarios = scenarios.filter((scenario) => wanted.has(String(scenario.scenarioId || '').toUpperCase()));
  }

  const personaScenarios = scenarios.filter((scenario) => scenarioMatchesPersona(scenario, ctx.persona));
  if (personaScenarios.length > 0) return personaScenarios;

  const includeUnmatched = /^true$/i.test(process.env.BROWSER_AGENT_BANKING_INCLUDE_UNMATCHED || '');
  return includeUnmatched ? scenarios : [];
}

function riskScoreForOperation(operation) {
  const high = new Set([
    'AIAppInteraction',
    'ExternalEmailSent',
    'DLPBlocked',
    'DLPPolicyMatch',
    'InsiderRiskSequence',
    'CommunicationComplianceMatch',
    'SensitivityLabelChanged'
  ]);
  const medium = new Set([
    'FileDownloaded',
    'FileShared',
    'CopilotInteraction',
    'SensitivityLabelApplied',
    'TeamsMessageSent'
  ]);
  if (high.has(operation)) return 85;
  if (medium.has(operation)) return 55;
  return 25;
}

function severityForRisk(score) {
  if (score >= 80) return 'High';
  if (score >= 50) return 'Medium';
  return 'Low';
}

function buildScenarioEvents(ctx, scenario, defaults = {}) {
  const correlationId = [
    scenario.scenarioId,
    ctx.persona,
    ctx.stamp
  ].join(':');
  const fileName = Array.isArray(scenario.expectedFiles) && scenario.expectedFiles.length > 0
    ? scenario.expectedFiles[0]
    : '';
  return (Array.isArray(scenario.actions) ? scenario.actions : []).map((action, index) => {
    const operation = action.operation || 'ScenarioStep';
    const riskScore = riskScoreForOperation(operation);
    return {
      EventId: `${correlationId}:${String(index + 1).padStart(2, '0')}`,
      ScenarioId: scenario.scenarioId,
      CorrelationId: correlationId,
      ScenarioTitle: scenario.title,
      Cadence: scenario.cadence || '',
      StepNumber: index + 1,
      PersonaName: ctx.displayName,
      UserPrincipalName: ctx.upn,
      Workload: action.workload || '',
      Operation: operation,
      ImplementationMode: action.implementationMode || defaults.implementationMode || 'SyntheticTelemetryCompanion',
      IsSynthetic: defaults.isSynthetic !== false,
      BusinessContext: scenario.businessContext || '',
      FileName: fileName,
      SensitivityLabel: scenario.sensitivityLabel || '',
      Recipient: process.env.BROWSER_AGENT_EMAIL_RECIPIENT || defaults.externalRecipient || '',
      TargetDomain: String(process.env.BROWSER_AGENT_EMAIL_RECIPIENT || defaults.externalRecipient || '').split('@').pop() || '',
      RiskScore: riskScore,
      Severity: severityForRisk(riskScore),
      ExpectedFiles: scenario.expectedFiles || [],
      Workloads: scenario.workloads || []
    };
  });
}

function validateCatalog(catalog = loadBankingWave1Catalog()) {
  const issues = [];
  const scenarios = catalog.scenarios;
  const expectedCount = Number(catalog.metadata?.scenarioCount || 8);
  if (scenarios.length !== expectedCount) {
    issues.push(`Expected ${expectedCount} scenarios but found ${scenarios.length}.`);
  }
  const seen = new Set();
  for (const scenario of scenarios) {
    if (!/^BF-SCEN-\d{4}$/.test(String(scenario.scenarioId || ''))) {
      issues.push(`Invalid scenarioId '${scenario.scenarioId}'.`);
    }
    if (seen.has(scenario.scenarioId)) {
      issues.push(`Duplicate scenarioId '${scenario.scenarioId}'.`);
    }
    seen.add(scenario.scenarioId);
    if (!scenario.title) issues.push(`${scenario.scenarioId}: missing title.`);
    if (!scenario.primaryPersona) issues.push(`${scenario.scenarioId}: missing primaryPersona.`);
    if (!Array.isArray(scenario.actors) || scenario.actors.length === 0) {
      issues.push(`${scenario.scenarioId}: missing actors.`);
    }
    if (!Array.isArray(scenario.actions) || scenario.actions.length === 0) {
      issues.push(`${scenario.scenarioId}: missing actions.`);
    }
    for (const action of scenario.actions || []) {
      if (!action.operation) issues.push(`${scenario.scenarioId}: action missing operation.`);
      if (!action.workload) issues.push(`${scenario.scenarioId}: action '${action.operation}' missing workload.`);
      if (!action.implementationMode) issues.push(`${scenario.scenarioId}: action '${action.operation}' missing implementationMode.`);
      if (/Endpoint|USB|NetworkShare|Printed/.test(String(action.operation || ''))) {
        issues.push(`${scenario.scenarioId}: endpoint-only action '${action.operation}' should not be in wave 1.`);
      }
    }
  }
  return issues;
}

module.exports = {
  loadBankingWave1Catalog,
  selectScenariosForPersona,
  buildScenarioEvents,
  validateCatalog
};
