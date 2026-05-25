const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { getPersonaContext } = require('../lib/personaContext');
const { createTelemetryClient } = require('../lib/adxTelemetry');
const {
  loadBankingWave1Catalog,
  selectScenariosForPersona,
  buildScenarioEvents,
  validateCatalog
} = require('../lib/bankingScenarioPack');

const resultPath = process.env.BROWSER_AGENT_BANKING_RESULT
  || path.join('test-results', `banking-wave1-${process.env.BROWSER_AGENT_PERSONA || 'agent'}.json`);

test('banking wave 1 catalog is valid and web-scoped', async () => {
  const catalog = loadBankingWave1Catalog();
  const issues = validateCatalog(catalog);
  expect(issues, issues.join('\n')).toHaveLength(0);
  expect(catalog.scenarios.map((scenario) => scenario.scenarioId)).toEqual([
    'BF-SCEN-0002',
    'BF-SCEN-0013',
    'BF-SCEN-0001',
    'BF-SCEN-0023',
    'BF-SCEN-0024',
    'BF-SCEN-0008',
    'BF-SCEN-0006',
    'BF-SCEN-0026'
  ]);
});

test('banking wave 1 persona plan emits scenario telemetry', async ({ page }) => {
  test.setTimeout(180000);
  const catalog = loadBankingWave1Catalog();
  const ctx = getPersonaContext();
  const telemetry = createTelemetryClient();
  const scenarios = selectScenariosForPersona(ctx, catalog);
  const events = scenarios.flatMap((scenario) => buildScenarioEvents(ctx, scenario, catalog.defaults));

  if (/^true$/i.test(process.env.BROWSER_AGENT_BANKING_OPEN_OFFICE || '')) {
    await page.goto(process.env.BROWSER_AGENT_OFFICE_URL || 'https://www.office.com/', { waitUntil: 'domcontentloaded' });
  }

  for (const event of events) {
    await telemetry.push('banking_wave1', `${event.ScenarioId} ${event.Operation}`, {
      Service: event.Workload,
      Workload: event.Workload,
      Action: event.Operation,
      TargetName: event.FileName,
      TargetPath: event.FileName,
      ScenarioId: event.ScenarioId,
      CorrelationId: event.CorrelationId,
      ScenarioTitle: event.ScenarioTitle,
      Cadence: event.Cadence,
      StepNumber: event.StepNumber,
      ImplementationMode: event.ImplementationMode,
      IsSynthetic: event.IsSynthetic,
      BusinessContext: event.BusinessContext,
      FileName: event.FileName,
      SensitivityLabel: event.SensitivityLabel,
      Recipient: event.Recipient,
      TargetDomain: event.TargetDomain,
      RiskScore: event.RiskScore,
      Severity: event.Severity,
      ExpectedFiles: event.ExpectedFiles.join('; '),
      ScenarioWorkloads: event.Workloads.join('; ')
    }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));
  }

  const payload = {
    persona: ctx.persona,
    upn: ctx.upn,
    displayName: ctx.displayName,
    generatedAt: new Date().toISOString(),
    catalogVersion: catalog.metadata.version,
    selectedScenarioCount: scenarios.length,
    eventCount: events.length,
    scenarios: scenarios.map((scenario) => ({
      scenarioId: scenario.scenarioId,
      title: scenario.title,
      cadence: scenario.cadence,
      primaryPersona: scenario.primaryPersona,
      actionCount: Array.isArray(scenario.actions) ? scenario.actions.length : 0
    })),
    events
  };

  fs.mkdirSync(path.dirname(resultPath), { recursive: true });
  fs.writeFileSync(resultPath, JSON.stringify(payload, null, 2), 'utf8');

  if (scenarios.length === 0) {
    test.info().annotations.push({
      type: 'note',
      description: `${ctx.persona} is not mapped to banking wave 1; no scenario telemetry was emitted.`
    });
  }
  expect(events.length).toBeGreaterThanOrEqual(scenarios.length);
  expect(events.every((event) => event.IsSynthetic === true)).toBeTruthy();
});
