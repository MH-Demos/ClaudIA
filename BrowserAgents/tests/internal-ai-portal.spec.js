const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const { getPersonaContext } = require('../lib/personaContext');
const { createTelemetryClient } = require('../lib/adxTelemetry');
const { buildAiScenario, chooseDocument, renderDocumentBrief } = require('../lib/contentPack');

function readConfig() {
  const configPath = process.env.BROWSER_AGENT_CONFIG_PATH || path.resolve(__dirname, '..', '..', 'config', 'agents.json');
  return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}

function modelFromConfig(config, requestedModel) {
  const services = Array.isArray(config.externalAiServices) ? config.externalAiServices : [];
  const runtime = config.externalAiRuntime || {};
  const requested = String(requestedModel || runtime.deploymentName || runtime.serviceName || 'deepseek').toLowerCase();
  const service = services.find((item) => {
    return String(item.modelFamily || '').toLowerCase() === requested
      || String(item.name || '').toLowerCase().includes(requested)
      || String(item.provider || '').toLowerCase().includes(requested);
  }) || services.find((item) => String(item.modelFamily || '').toLowerCase() === 'deepseek') || {
    name: 'Internal AI Workbench - DeepSeek',
    provider: 'DeepSeek',
    modelFamily: 'deepseek',
    riskProfile: 'External AI analysis of sensitive incident evidence'
  };
  return {
    serviceName: service.name || `Internal AI Workbench - ${requested}`,
    provider: service.provider || requested,
    modelFamily: service.modelFamily || requested,
    riskProfile: service.riskProfile || '',
    modelId: service.modelFamily || requested
  };
}

function resolvePortalUrl(config, modelId) {
  const explicit = process.env.BROWSER_AGENT_INTERNAL_AI_URL;
  if (explicit) return explicit;
  const staticUrl = config?.activityStoryMap?.staticWebsiteUrl || config?.activityStoryMap?.launchUrl || '';
  if (!staticUrl) throw new Error('BROWSER_AGENT_INTERNAL_AI_URL or activityStoryMap.staticWebsiteUrl is required.');
  return `${String(staticUrl).replace(/\/+$/, '')}/internal-ai/index.html?model=${encodeURIComponent(modelId)}`;
}

function materializeDocument(ctx, document) {
  const outputDir = path.resolve(__dirname, '..', 'test-results', 'internal-ai-uploads');
  fs.mkdirSync(outputDir, { recursive: true });
  const safeName = String(document?.fileName || `Synthetic_AI_Upload_${ctx.persona}.txt`).replace(/[\\/:*?"<>|]/g, '_');
  const filePath = path.join(outputDir, safeName);
  fs.writeFileSync(filePath, renderDocumentBrief(document), 'utf8');
  return filePath;
}

test('Internal AI portal prompt through Edge browser', async ({ page }) => {
  test.setTimeout(180000);
  const config = readConfig();
  const ctx = getPersonaContext();
  const telemetry = createTelemetryClient();
  const model = modelFromConfig(config, process.env.BROWSER_AGENT_INTERNAL_AI_MODEL);
  const portalUrl = resolvePortalUrl(config, model.modelFamily);
  const aiScenario = buildAiScenario(ctx);
  const document = chooseDocument(ctx);
  const uploadPath = materializeDocument(ctx, document);
  const prompt = [
    aiScenario?.prompt || `${ctx.sensitiveBrief}\n\nSummarize the risk using ${model.serviceName}.`,
    '',
    `Use the uploaded document '${document?.fileName || path.basename(uploadPath)}' to create an executive summary and a short presentation outline.`
  ].join('\n');

  await page.goto(portalUrl, { waitUntil: 'domcontentloaded' });
  await expect(page.getByRole('heading', { name: 'Internal AI Workbench' })).toBeVisible({ timeout: 60000 });

  const modelButton = page.locator(`[data-model="${model.modelFamily}"]`).first();
  if (await modelButton.isVisible().catch(() => false)) {
    await modelButton.click();
  }

  const promptBox = page.locator('#prompt');
  await promptBox.fill(prompt);
  await page.locator('#documentUpload').setInputFiles(uploadPath);
  await expect(page.locator('#fileStatus')).toContainText(path.basename(uploadPath), { timeout: 30000 });
  await page.getByRole('button', { name: /^send$/i }).click();
  await expect(page.locator('body')).toContainText(/Response complete|Recommended handling/i, { timeout: 60000 });
  const responseText = await page.locator('.message.assistant').last().innerText({ timeout: 30000 });

  await telemetry.push('external_ai', `${model.serviceName} prompt submitted through Internal AI Workbench`, {
    Service: model.serviceName,
    Workload: 'Internal AI Workbench',
    Action: 'AIAppInteraction',
    Provider: model.provider,
    ModelFamily: model.modelFamily,
    ModelName: model.serviceName,
    RuntimeMode: 'BrowserPortalSimulation',
    PortalUrl: portalUrl,
    UploadedFileName: document?.fileName || path.basename(uploadPath),
    UploadedFileType: document?.fileType || '',
    UploadedDocumentId: document?.id || '',
    UploadedDocumentTitle: document?.title || '',
    UploadedDocumentSensitivity: document?.sensitivityLevel || '',
    UploadedDocumentLabel: document?.suggestedSensitivityLabel || '',
    UploadedDocumentBytes: fs.statSync(uploadPath).size,
    ContainsSensitiveData: true,
    PromptContent: prompt,
    ResponseContent: responseText,
    ScenarioContentId: aiScenario?.id || '',
    ExpectedRisk: aiScenario?.expectedRisk || model.riskProfile,
    SafeBusinessPurpose: aiScenario?.safeBusinessPurpose || '',
    SourceContext: aiScenario?.sourceContext || '',
    ScenarioId: ctx.scenarioId
  }).catch((error) => test.info().annotations.push({ type: 'adx-warning', description: error.message }));
});
