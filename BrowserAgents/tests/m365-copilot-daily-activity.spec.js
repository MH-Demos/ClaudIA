const { test, expect } = require('@playwright/test');
const { getPersonaContext } = require('../lib/personaContext');
const { createTelemetryClient } = require('../lib/adxTelemetry');
const { buildAiScenario } = require('../lib/contentPack');

const officeUrl = process.env.BROWSER_AGENT_OFFICE_URL || 'https://www.office.com/';

async function waitForM365(page) {
  await page.goto(`${officeUrl}?auth=2`, { waitUntil: 'domcontentloaded' });
  await page.waitForURL(/office\.com|microsoft365\.com|cloud\.microsoft/i, { timeout: 90000 });
  await page.locator('textarea[aria-label*="Message"], textarea[placeholder*="Message"], textarea, [contenteditable="true"]').first()
    .waitFor({ state: 'visible', timeout: 90000 });
}

test('M365 Copilot web daily prompt with sensitive business context', async ({ page }) => {
  test.setTimeout(180000);
  const ctx = getPersonaContext();
  const telemetry = createTelemetryClient();

  await waitForM365(page);

  const aiScenario = buildAiScenario(ctx);
  const prompt = aiScenario?.prompt || [
    `Summarize the risk in this synthetic lab extract and suggest where it should be stored.`,
    ``,
    ctx.sensitiveBrief
  ].join('\n');

  const promptBox = page.locator('textarea[aria-label*="Message"], textarea[placeholder*="Message"], [contenteditable="true"][aria-label*="Message"], textarea, [contenteditable="true"]').first();
  await promptBox.waitFor({ state: 'visible', timeout: 60000 });
  await promptBox.fill(prompt);

  const send = page.locator('button[aria-label*="Send"], button[aria-label*="Enviar"], button:has-text("Send"), button:has-text("Enviar")').first();
  if (await send.isVisible().catch(() => false)) {
    await send.click();
  } else {
    await page.keyboard.press('Enter');
  }

  await expect(page.locator('body')).toContainText(/risk|sensitive|stored|data|confidential/i, { timeout: 90000 });
  const responseText = await page.locator('body').innerText({ timeout: 30000 }).catch(() => '');
  await telemetry.push('copilot', 'M365 Copilot web prompt submitted', {
    Service: 'Microsoft 365 Copilot Web',
    Workload: ctx.copilotLicense ? 'M365 Copilot' : 'Copilot Chat',
    Action: aiScenario?.interactionType || (ctx.copilotLicense ? 'CopilotInteraction' : 'AIAppInteraction'),
    ContainsSensitiveData: true,
    ScenarioContentId: aiScenario?.id || '',
    ExpectedRisk: aiScenario?.expectedRisk || '',
    SafeBusinessPurpose: aiScenario?.safeBusinessPurpose || '',
    SourceContext: aiScenario?.sourceContext || '',
    PromptContent: prompt,
    ResponseContent: responseText,
    ScenarioId: ctx.scenarioId
  }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));
});
