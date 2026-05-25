const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { getPersonaContext } = require('../lib/personaContext');
const { createTelemetryClient } = require('../lib/adxTelemetry');

const defaultServices = ['office', 'owa', 'copilot', 'teams'];
const services = (process.env.BROWSER_AGENT_PREFLIGHT_SERVICES || defaultServices.join(','))
  .split(',')
  .map((service) => service.trim().toLowerCase())
  .filter(Boolean);

const resultPath = process.env.BROWSER_AGENT_PREFLIGHT_RESULT
  || path.join('test-results', `preflight-${process.env.BROWSER_AGENT_PERSONA || 'agent'}.json`);

async function dismissBlockingDialogs(page) {
  const buttons = [
    /continue/i,
    /next/i,
    /accept/i,
    /^ok$/i,
    /got it/i,
    /not now/i,
    /skip/i,
    /dismiss/i,
    /continuar/i,
    /aceptar/i,
    /descartar/i
  ];
  for (let pass = 0; pass < 5; pass += 1) {
    let clicked = false;
    for (const name of buttons) {
      const button = page.getByRole('button', { name }).first();
      if (await button.isVisible().catch(() => false)) {
        await button.click({ timeout: 10000 }).catch(async () => button.click({ force: true, timeout: 10000 }));
        await page.waitForTimeout(1000);
        clicked = true;
        break;
      }
    }
    if (!clicked) break;
  }
}

async function assertNotLogin(page) {
  const bodyText = await page.locator('body').innerText({ timeout: 30000 }).catch(() => '');
  const href = page.url().toLowerCase();
  const loginPattern = /sign in|enter password|password|stay signed in|iniciar sesi[oó]n|contrase[nñ]a/i;
  expect(href.includes('login.microsoftonline.com') || loginPattern.test(bodyText)).toBeFalsy();
}

async function checkOffice(page) {
  const officeUrl = process.env.BROWSER_AGENT_OFFICE_URL || 'https://www.office.com/';
  await page.goto(`${officeUrl}?auth=2`, { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    const inM365 = href.includes('office.com') || href.includes('microsoft365.com') || href.includes('cloud.microsoft');
    return inM365 && /app launcher|word|excel|powerpoint|outlook|onedrive|my content|create|copilot|new chat|meetings/i.test(text);
  }, { timeout: 90000 });
  await assertNotLogin(page);
}

async function checkOwa(page) {
  const owaUrl = process.env.BROWSER_AGENT_OWA_URL || 'https://outlook.office.com/mail/inbox';
  await page.goto(owaUrl, { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  if (!page.url().toLowerCase().includes('/mail') || page.url().toLowerCase().includes('/bookings')) {
    await page.goto('https://outlook.office.com/mail/inbox', { waitUntil: 'domcontentloaded' });
    await dismissBlockingDialogs(page);
  }
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    return (href.includes('outlook.office.com') || href.includes('outlook.cloud.microsoft'))
      && href.includes('/mail')
      && !href.includes('/bookings')
      && /mail|inbox|sent items|new mail|new message|bandeja|correo nuevo/i.test(text);
  }, { timeout: 90000 });
  await dismissBlockingDialogs(page);
  await assertNotLogin(page);
}

async function checkCopilot(page) {
  const copilotUrls = [
    process.env.BROWSER_AGENT_COPILOT_URL,
    'https://m365.cloud.microsoft/chat',
    'https://www.office.com/chat'
  ].filter(Boolean);

  let lastError = null;
  for (const url of copilotUrls) {
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded' });
      await dismissBlockingDialogs(page);
      await page.locator('textarea[aria-label*="Message"], textarea[placeholder*="Message"], [contenteditable="true"][aria-label*="Message"], textarea, [contenteditable="true"]')
        .first()
        .waitFor({ state: 'visible', timeout: 60000 });
      await assertNotLogin(page);
      return;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error('Copilot prompt box was not available.');
}

async function checkTeams(page) {
  await page.goto('https://teams.microsoft.com/v2/', { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  await page.waitForFunction(() => {
    const text = document.body?.innerText || '';
    const href = location.href.toLowerCase();
    return href.includes('teams.microsoft.com') && /teams|chat|calendar|activity|calls|apps|equipo|calendario/i.test(text);
  }, { timeout: 120000 });
  await assertNotLogin(page);
}

const checks = {
  edge: checkOffice,
  browser: checkOffice,
  office: checkOffice,
  m365: checkOffice,
  owa: checkOwa,
  outlook: checkOwa,
  mail: checkOwa,
  copilot: checkCopilot,
  chat: checkCopilot,
  teams: checkTeams,
  banking: checkOffice,
  'banking-wave1': checkOffice,
  finance: checkOffice,
  'bf-wave1': checkOffice
};

test('BrowserAgent preflight validates web service access', async ({ page }) => {
  test.setTimeout(360000);
  const ctx = getPersonaContext();
  const telemetry = createTelemetryClient();
  const results = [];
  const startedAt = new Date().toISOString();

  for (const service of services) {
    const check = checks[service];
    if (!check) {
      results.push({ service, status: 'skipped', comment: 'Unknown service alias.' });
      continue;
    }

    const serviceStart = Date.now();
    try {
      await check(page);
      results.push({
        service,
        status: 'success',
        url: page.url(),
        durationMs: Date.now() - serviceStart
      });
      await telemetry.push('browser_preflight', `Preflight ${service} succeeded`, {
        Service: service,
        Workload: 'BrowserAgent',
        Action: 'PreflightSuccess',
        Outcome: 'success',
        TargetPath: page.url(),
        ScenarioId: ctx.scenarioId
      }).catch(() => null);
    } catch (error) {
      results.push({
        service,
        status: 'failed',
        url: page.url(),
        durationMs: Date.now() - serviceStart,
        comment: error.message
      });
      await telemetry.push('browser_preflight', `Preflight ${service} failed`, {
        Service: service,
        Workload: 'BrowserAgent',
        Action: 'PreflightFailed',
        Outcome: 'failed',
        TargetPath: page.url(),
        ErrorMessage: error.message,
        ScenarioId: ctx.scenarioId
      }).catch(() => null);
    }
  }

  const payload = {
    persona: ctx.persona,
    upn: ctx.upn,
    displayName: ctx.displayName,
    department: ctx.department,
    copilotLicense: ctx.copilotLicense,
    startedAt,
    completedAt: new Date().toISOString(),
    results,
    status: results.some((result) => result.status === 'failed') ? 'failed' : 'success'
  };

  fs.mkdirSync(path.dirname(resultPath), { recursive: true });
  fs.writeFileSync(resultPath, JSON.stringify(payload, null, 2), 'utf8');

  const failed = results.filter((result) => result.status === 'failed');
  expect(failed, failed.map((result) => `${result.service}: ${result.comment}`).join('\n')).toHaveLength(0);
});
