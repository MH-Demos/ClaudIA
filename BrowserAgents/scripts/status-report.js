const { chromium } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const { execFileSync, execSync } = require('child_process');
const { getPersonaContext } = require('../lib/personaContext');

const configPath = process.env.BROWSER_AGENT_CONFIG_PATH || path.resolve(__dirname, '../../config/agents.json');
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

const subscriptionId = process.env.AZURE_SUBSCRIPTION_ID || config.browserAgents?.subscriptionId || config.tenant?.subscriptionId;
const resourceGroup = process.env.AZURE_RESOURCE_GROUP || config.browserAgents?.resourceGroup || config.infrastructure?.resourceGroup;
const targetJob = process.env.BROWSER_AGENT_STATUS_TARGET_JOB || '';
const reportRecipient = process.env.BROWSER_AGENT_STATUS_REPORT_RECIPIENT || 'admin@contoso.example';
const reportSubject = process.env.BROWSER_AGENT_STATUS_SUBJECT || 'EXCUTION STATUS REPORT';
const lookbackMinutes = Number(process.env.BROWSER_AGENT_STATUS_LOOKBACK_MINUTES || 120);
const rerunWaitMinutes = Number(process.env.BROWSER_AGENT_STATUS_RERUN_WAIT_MINUTES || 65);
const forceRerun = !/^false$/i.test(process.env.BROWSER_AGENT_STATUS_FORCE_RERUN || 'true');
const senderSam = process.env.BROWSER_AGENT_STATUS_SENDER || 'devon.reyes';
const mdcaAutomationAccount = process.env.MDCA_AUTOMATION_ACCOUNT || config.infrastructure?.automationAccountName || '';
const mdcaRunbookName = process.env.MDCA_RUNBOOK_NAME || 'Invoke-MdcaAdxDiscoverySync';
const skipEmail = /^true$/i.test(process.env.BROWSER_AGENT_STATUS_SKIP_EMAIL || '');
const maxActivityRows = Number(process.env.BROWSER_AGENT_STATUS_ACTIVITY_ROWS || 20);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function jsonHeaders(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: 'application/json',
    'Content-Type': 'application/json'
  };
}

function getSecretFromAz(vaultName, secretName) {
  if (!vaultName || !secretName) return '';
  const azCandidates = [
    process.env.AZURE_CLI_PATH,
    'az',
    'az.cmd',
    'C:\\Program Files (x86)\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd',
    'C:\\Program Files\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az',
    'C:\\Program Files\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd'
  ].filter(Boolean);
  for (const azPath of azCandidates) {
    try {
      return execFileSync(
        azPath,
        ['keyvault', 'secret', 'show', '--vault-name', vaultName, '--name', secretName, '--query', 'value', '-o', 'tsv'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
      ).trim();
    } catch {
      // Try the next Azure CLI path.
    }
  }
  try {
    const command = `"C:\\Program Files\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd" keyvault secret show --vault-name "${vaultName}" --name "${secretName}" --query value -o tsv`;
    return execSync(command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], shell: true }).trim();
  } catch {
    return '';
  }
}

async function getClientCredentialToken(tenantId, clientId, clientSecret, scope) {
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    scope,
    grant_type: 'client_credentials'
  });
  const response = await fetch(`https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });
  if (!response.ok) {
    throw new Error(`Client credential token failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()).access_token;
}

async function getArmToken() {
  if (process.env.IDENTITY_ENDPOINT && process.env.IDENTITY_HEADER) {
    const clientId = process.env.AZURE_CLIENT_ID;
    const url = new URL(process.env.IDENTITY_ENDPOINT);
    url.searchParams.set('api-version', '2019-08-01');
    url.searchParams.set('resource', 'https://management.azure.com/');
    if (clientId) url.searchParams.set('client_id', clientId);
    const response = await fetch(url, { headers: { 'X-IDENTITY-HEADER': process.env.IDENTITY_HEADER } });
    if (!response.ok) {
      throw new Error(`Managed identity token failed: ${response.status} ${await response.text()}`);
    }
    return (await response.json()).access_token;
  }

  if (process.env.MSI_ENDPOINT && process.env.MSI_SECRET) {
    const url = new URL(process.env.MSI_ENDPOINT);
    url.searchParams.set('api-version', '2017-09-01');
    url.searchParams.set('resource', 'https://management.azure.com/');
    const response = await fetch(url, { headers: { Secret: process.env.MSI_SECRET } });
    if (!response.ok) {
      throw new Error(`MSI token failed: ${response.status} ${await response.text()}`);
    }
    return (await response.json()).access_token;
  }

  const { spawnSync } = require('child_process');
  const result = process.platform === 'win32'
    ? spawnSync('powershell.exe', ['-NoProfile', '-Command', 'az account get-access-token --resource https://management.azure.com/ -o json'], { encoding: 'utf8' })
    : spawnSync('az', ['account', 'get-access-token', '--resource', 'https://management.azure.com/', '-o', 'json'], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`Azure CLI token failed: ${result.error?.message || result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout).accessToken;
}

async function armGet(token, uri) {
  const response = await fetch(uri, { headers: jsonHeaders(token) });
  if (!response.ok) {
    throw new Error(`ARM GET failed: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

async function armPost(token, uri, body = {}) {
  const response = await fetch(uri, {
    method: 'POST',
    headers: jsonHeaders(token),
    body: JSON.stringify(body)
  });
  if (!response.ok) {
    throw new Error(`ARM POST failed: ${response.status} ${await response.text()}`);
  }
  return response.text().then((text) => (text ? JSON.parse(text) : {}));
}

function jobBaseUri(jobName) {
  return `https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.App/jobs/${jobName}`;
}

async function listExecutions(token, jobName) {
  const uri = `${jobBaseUri(jobName)}/executions?api-version=2024-03-01`;
  const payload = await armGet(token, uri);
  return [...(payload.value || [])].sort((a, b) => {
    const aTime = new Date(a.properties?.startTime || 0).getTime();
    const bTime = new Date(b.properties?.startTime || 0).getTime();
    return bTime - aTime;
  });
}

async function startJob(token, jobName) {
  const uri = `${jobBaseUri(jobName)}/start?api-version=2024-03-01`;
  return armPost(token, uri);
}

async function waitForExecution(token, jobName, executionName) {
  const deadline = Date.now() + rerunWaitMinutes * 60 * 1000;
  while (Date.now() < deadline) {
    const executions = await listExecutions(token, jobName);
    const execution = executions.find((item) => item.name === executionName) || executions[0];
    const status = execution?.properties?.status || 'Unknown';
    if (['Succeeded', 'Failed', 'Canceled'].includes(status)) return execution;
    await sleep(30000);
  }
  return null;
}

async function getMdcaRunbookStatus(token) {
  if (!mdcaAutomationAccount) return { status: 'NotConfigured' };
  const uri = `https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Automation/automationAccounts/${mdcaAutomationAccount}/jobs?api-version=2019-06-01`;
  try {
    const payload = await armGet(token, uri);
    const jobs = (payload.value || [])
      .filter((item) => item.properties?.runbook?.name === mdcaRunbookName)
      .sort((a, b) => new Date(b.properties?.startTime || b.properties?.creationTime || 0) - new Date(a.properties?.startTime || a.properties?.creationTime || 0));
    const latest = jobs[0];
    if (!latest) return { status: 'NoRecentJob', runbook: mdcaRunbookName };
    return {
      status: latest.properties?.status || 'Unknown',
      runbook: mdcaRunbookName,
      startTime: latest.properties?.startTime,
      endTime: latest.properties?.endTime,
      jobId: latest.name
    };
  } catch (error) {
    return { status: 'CheckFailed', runbook: mdcaRunbookName, error: error.message };
  }
}

function getAdxConfig() {
  const adx = config.adx || {};
  return {
    enabled: adx.enabled === true,
    tenantId: adx.tenantId || config.tenant?.tenantId,
    clientId: adx.clientId,
    clientSecret: process.env.BROWSER_AGENT_ADX_CLIENT_SECRET || getSecretFromAz(adx.keyVaultName || config.infrastructure?.keyVaultName, adx.clientSecretName || 'agent-client-secret'),
    queryBaseUri: String(adx.queryBaseUri || adx.ingestBaseUri || '').replace(/\/+$/, ''),
    databaseName: adx.databaseName,
    tableName: adx.tableName
  };
}

function normalizeKustoRows(payload) {
  const tables = Array.isArray(payload)
    ? payload.filter((frame) => frame.FrameType === 'DataTable')
    : (payload.Tables || []);
  const primary = tables.find((table) => table.TableKind === 'PrimaryResult') || tables[0];
  if (!primary) return [];
  const columns = primary.Columns || [];
  return (primary.Rows || []).map((row) => {
    const item = {};
    row.forEach((value, index) => {
      item[columns[index]?.ColumnName || `Column${index}`] = value;
    });
    return item;
  });
}

async function queryAdxActivitySummary(startTime, endTime) {
  const adx = getAdxConfig();
  if (!adx.enabled) return { status: 'Disabled', rows: [] };
  if (!adx.tenantId || !adx.clientId || !adx.clientSecret || !adx.queryBaseUri || !adx.databaseName || !adx.tableName) {
    return { status: 'NotConfigured', rows: [] };
  }

  try {
    const escapedTable = String(adx.tableName).replace(/'/g, "\\'");
    const token = await getClientCredentialToken(adx.tenantId, adx.clientId, adx.clientSecret, 'https://kusto.kusto.windows.net/.default');
    const query = `
let windowStart = datetime(${startTime.toISOString()});
let windowEnd = datetime(${endTime.toISOString()});
table('${escapedTable}')
| where TimeGenerated between (windowStart .. windowEnd)
| extend AgentUPN = tostring(Event.AgentUPN),
         AgentName = tostring(Event.AgentName),
         Service = tostring(Event.Service),
         Workload = tostring(Event.Workload),
         ActivityType = tostring(Event.ActivityType),
         Action = tostring(Event.Action),
         Outcome = tostring(Event.Outcome),
         Recipient = tostring(Event.Recipient),
         ExternalRecipient = tostring(Event.ExternalRecipient)
| summarize Activities = count(),
            Services = make_set(coalesce(Service, Workload), 6),
            ActivityTypes = make_set(ActivityType, 6),
            Actions = make_set(Action, 8),
            Outcomes = make_set(Outcome, 8),
            ExternalEvents = countif(ExternalRecipient =~ "true"),
            LastActivity = max(TimeGenerated)
  by AgentName, AgentUPN
| order by AgentName asc
| take ${Math.max(1, maxActivityRows)}
`;
    const response = await fetch(`${adx.queryBaseUri}/v2/rest/query`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify({
        db: adx.databaseName,
        csl: query
      })
    });
    if (!response.ok) {
      throw new Error(`ADX query failed: ${response.status} ${await response.text()}`);
    }
    return { status: 'Completed', rows: normalizeKustoRows(await response.json()) };
  } catch (error) {
    return { status: 'CheckFailed', rows: [], error: error.message };
  }
}

function formatColombia(value) {
  if (!value) return 'n/a';
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Bogota',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false
  }).format(new Date(value));
}

async function dismissBlockingDialogs(page) {
  const buttons = [
    /continue/i,
    /next/i,
    /accept/i,
    /ok/i,
    /got it/i,
    /not now/i,
    /skip/i,
    /dismiss/i,
    /continuar/i,
    /aceptar/i,
    /descartar/i
  ];
  for (let pass = 0; pass < 4; pass += 1) {
    let clicked = false;
    for (const name of buttons) {
      const button = page.getByRole('button', { name }).first();
      if (await button.isVisible().catch(() => false)) {
        await button.click().catch(() => null);
        await page.waitForTimeout(1000);
        clicked = true;
        break;
      }
    }
    if (!clicked) break;
  }
}

async function resolveRecipient(page, recipientAddress) {
  const confirmations = [
    /use this address/i,
    /add recipient/i,
    /add/i,
    /usar esta direcci[oó]n/i,
    /agregar destinatario/i,
    /agregar/i
  ];

  for (const name of confirmations) {
    const button = page.getByRole('button', { name }).last();
    if (await button.isVisible().catch(() => false)) {
      await button.click({ timeout: 10000 }).catch(async () => button.click({ force: true, timeout: 10000 }).catch(() => null));
      await page.waitForTimeout(1000);
      break;
    }
  }
  await page.keyboard.press('Tab').catch(() => null);
  await page.waitForTimeout(1000);
}

async function clickSendButton(page) {
  const candidates = [
    page.getByRole('button', { name: /^send$/i }).last(),
    page.getByRole('button', { name: /^enviar$/i }).last(),
    page.locator('button[aria-label*="Send" i]:visible, button[title*="Send" i]:visible').last(),
    page.locator('button[aria-label*="Enviar" i]:visible, button[title*="Enviar" i]:visible').last()
  ];
  for (const button of candidates) {
    if (await button.isVisible().catch(() => false)) {
      await button.click({ timeout: 15000 }).catch(async () => button.click({ force: true, timeout: 15000 }));
      return true;
    }
  }
  return false;
}

async function handleSendPrompts(page) {
  const buttons = [
    /send anyway/i,
    /^send$/i,
    /send now/i,
    /continue/i,
    /^yes$/i,
    /^ok$/i,
    /enviar de todos modos/i,
    /^enviar$/i,
    /continuar/i,
    /^si$/i,
    /^s[ií]$/i
  ];
  for (let pass = 0; pass < 8; pass += 1) {
    await page.waitForTimeout(1500);
    let clicked = false;
    for (const name of buttons) {
      const button = page.getByRole('button', { name }).last();
      if (await button.isVisible().catch(() => false)) {
        await button.click({ timeout: 10000 }).catch(async () => button.click({ force: true, timeout: 10000 }).catch(() => null));
        clicked = true;
        break;
      }
    }
    if (!clicked) {
      const text = await page.locator('body').innerText().catch(() => '');
      if (!/getting this ready|policy tip|schedule send|send this email|external sharing|sensitive data/i.test(text)) break;
    }
  }
}

async function attemptSendFromCurrentCompose(page) {
  for (let pass = 0; pass < 3; pass += 1) {
    await dismissBlockingDialogs(page);
    const clicked = await clickSendButton(page);
    if (!clicked) await page.keyboard.press('Control+Enter').catch(() => null);
    await handleSendPrompts(page);
    await page.waitForTimeout(4000);
  }
}

async function folderContains(page, folder, subject, recipient) {
  await page.goto(`https://outlook.office.com/mail/${folder}`, { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  await page.waitForTimeout(folder === 'sentitems' ? 8000 : 5000);
  const text = await page.locator('body').innerText({ timeout: 30000 }).catch(() => '');
  return text.includes(subject) || text.toLowerCase().includes(String(recipient || '').toLowerCase());
}

async function reopenDraftAndSend(page, subject, recipient) {
  await page.goto('https://outlook.office.com/mail/drafts', { waitUntil: 'domcontentloaded' });
  await dismissBlockingDialogs(page);
  await page.waitForTimeout(5000);
  const draft = page.getByText(subject, { exact: false }).first();
  const draftByRecipient = page.getByText(recipient, { exact: false }).first();
  if (await draft.isVisible().catch(() => false)) {
    await draft.dblclick().catch(async () => draft.click());
  } else if (await draftByRecipient.isVisible().catch(() => false)) {
    await draftByRecipient.dblclick().catch(async () => draftByRecipient.click());
  } else {
    return false;
  }
  await page.waitForTimeout(3000);
  await page.keyboard.press('Enter').catch(() => null);
  await page.waitForTimeout(3000);
  await dismissBlockingDialogs(page);
  await attemptSendFromCurrentCompose(page);
  return true;
}

async function assertReportSent(page, subject, recipient) {
  if (await folderContains(page, 'sentitems', subject, recipient)) return;
  if (await folderContains(page, 'drafts', subject, recipient)) {
    const retried = await reopenDraftAndSend(page, subject, recipient);
    if (retried && await folderContains(page, 'sentitems', subject, recipient)) return;
    throw new Error('Status report remained in Drafts after retry.');
  }
  if (await folderContains(page, 'outbox', subject, recipient)) {
    throw new Error('Status report is still in Outbox after send attempt.');
  }
  throw new Error('Status report was not found in Sent Items after send attempt.');
}

function listValue(value) {
  if (Array.isArray(value)) return value.filter(Boolean).join(', ');
  if (typeof value === 'string') {
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) return parsed.filter(Boolean).join(', ');
    } catch {
      return value;
    }
  }
  return value == null ? '' : String(value);
}

function truncateCell(value, maxLength = 42) {
  const text = listValue(value).replace(/\s+/g, ' ').trim();
  if (!text) return '-';
  return text.length > maxLength ? `${text.slice(0, maxLength - 3)}...` : text;
}

function formatMarkdownTable(rows) {
  if (!rows.length) return ['No ADX activity rows found for this validation window.'];
  const headers = ['User', 'Activities', 'Services', 'Actions', 'Outcomes', 'External', 'Last activity'];
  const body = rows.map((row) => [
    truncateCell(row.AgentName || row.AgentUPN, 28),
    String(row.Activities || 0),
    truncateCell(row.Services, 34),
    truncateCell(row.Actions || row.ActivityTypes, 40),
    truncateCell(row.Outcomes, 34),
    String(row.ExternalEvents || 0),
    formatColombia(row.LastActivity)
  ]);
  return [
    `| ${headers.join(' | ')} |`,
    `| ${headers.map(() => '---').join(' | ')} |`,
    ...body.map((row) => `| ${row.join(' | ')} |`)
  ];
}

function buildReport({ targetJob, expectedWindowStart, latest, rerun, mdca, activitySummary }) {
  const status = latest?.properties?.status || 'Missing';
  const lines = [
    'BrowserAgents execution status report',
    '',
    `Target job: ${targetJob}`,
    `Validation time Colombia: ${formatColombia(new Date().toISOString())}`,
    `Lookback start Colombia: ${formatColombia(expectedWindowStart.toISOString())}`,
    '',
    'BrowserAgents:',
    `- Latest execution: ${latest?.name || 'none'}`,
    `- Status: ${status}`,
    `- Started Colombia: ${formatColombia(latest?.properties?.startTime)}`,
    `- Ended Colombia: ${formatColombia(latest?.properties?.endTime)}`,
    `- Rerun attempted: ${rerun?.attempted ? 'yes' : 'no'}`,
    `- Rerun execution: ${rerun?.executionName || 'n/a'}`,
    `- Rerun final status: ${rerun?.finalStatus || 'n/a'}`,
    '',
    'MDCA log collector:',
    `- Runbook: ${mdca?.runbook || mdcaRunbookName}`,
    `- Latest status: ${mdca?.status || 'Unknown'}`,
    `- Started Colombia: ${formatColombia(mdca?.startTime)}`,
    `- Ended Colombia: ${formatColombia(mdca?.endTime)}`,
    `- Job id: ${mdca?.jobId || 'n/a'}`
  ];
  if (mdca?.error) lines.push(`- Error: ${mdca.error}`);
  lines.push(
    '',
    'ADX activity by user:',
    `- Query status: ${activitySummary?.status || 'Unknown'}`,
    `- Rows shown: ${activitySummary?.rows?.length || 0}`
  );
  if (activitySummary?.error) lines.push(`- Error: ${activitySummary.error}`);
  lines.push('', ...formatMarkdownTable(activitySummary?.rows || []));
  return lines.join('\n');
}

async function sendReportEmail(body) {
  const agent = (config.agents || []).find((item) => item.sam === senderSam) || (config.agents || []).find((item) => item.sam === 'devon.reyes');
  if (!agent) throw new Error(`Status sender '${senderSam}' was not found in config.`);

  process.env.BROWSER_AGENT_PERSONA = agent.sam;
  process.env.BROWSER_AGENT_UPN = agent.userPrincipalName;
  process.env.BROWSER_AGENT_DISPLAY_NAME = agent.displayName;
  const storageState = path.resolve(__dirname, `../.auth/${agent.sam}.json`);
  const ctx = getPersonaContext();

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext(fs.existsSync(storageState) ? { storageState } : {});
  const page = await context.newPage();
  try {
    await page.goto('https://outlook.office.com/mail/inbox', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => {
      const text = document.body?.innerText || '';
      const href = location.href.toLowerCase();
      const signedIn = href.includes('outlook.office.com') && href.includes('/mail');
      return signedIn && /mail|inbox|new mail|new message|bandeja|correo nuevo/i.test(text);
    }, { timeout: 90000 });

    await dismissBlockingDialogs(page);

    const newMail = page.getByRole('button', { name: /new mail|new message|nuevo correo|correo nuevo/i }).first();
    if (await newMail.isVisible().catch(() => false)) {
      await newMail.click();
    } else {
      await page.goto('https://outlook.office.com/mail/deeplink/compose', { waitUntil: 'domcontentloaded' });
    }

    const toBox = page.locator('div[role="textbox"][aria-label*="To"], div[role="textbox"][aria-label*="Para"], div[aria-label*="To"][contenteditable="true"], div[aria-label*="Para"][contenteditable="true"], input[aria-label*="To"], input[aria-label*="Para"]').first();
    try {
      await toBox.waitFor({ state: 'visible', timeout: 15000 });
    } catch {
      await page.goto('https://outlook.office.com/mail/deeplink/compose', { waitUntil: 'domcontentloaded' });
      await toBox.waitFor({ state: 'visible', timeout: 90000 });
    }
    await toBox.click();
    await page.keyboard.type(reportRecipient);
    await page.keyboard.press('Enter');
    await resolveRecipient(page, reportRecipient);

    const subjectBox = page.locator('input[aria-label*="Subject"], input[placeholder*="Subject"], input[aria-label*="Asunto"], input[placeholder*="Asunto"]').first();
    await subjectBox.waitFor({ state: 'visible', timeout: 30000 });
    await subjectBox.fill(reportSubject);

    const bodyBox = page.locator('[aria-label*="Message body"], [aria-label*="Cuerpo"], div[contenteditable="true"]').last();
    await bodyBox.waitFor({ state: 'visible', timeout: 30000 });
    await bodyBox.fill(`${body}\n\nSent by ${ctx.displayName} <${ctx.upn}>`);

    await attemptSendFromCurrentCompose(page);
    await assertReportSent(page, reportSubject, reportRecipient);
  } finally {
    await browser.close();
  }
}

async function main() {
  if (!subscriptionId || !resourceGroup || !targetJob) {
    throw new Error('AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, and BROWSER_AGENT_STATUS_TARGET_JOB are required.');
  }

  const token = await getArmToken();
  const expectedWindowStart = new Date(Date.now() - lookbackMinutes * 60 * 1000);
  const executions = await listExecutions(token, targetJob);
  let latest = executions.find((item) => new Date(item.properties?.startTime || 0) >= expectedWindowStart) || executions[0];
  let rerun = { attempted: false };

  const shouldRerun = !latest ||
    new Date(latest.properties?.startTime || 0) < expectedWindowStart ||
    !['Succeeded', 'Running'].includes(latest.properties?.status || '');

  if (shouldRerun && forceRerun) {
    const started = await startJob(token, targetJob);
    const executionName = started.name || String(started.id || '').split('/').pop();
    rerun = { attempted: true, executionName };
    const completed = await waitForExecution(token, targetJob, executionName);
    if (completed) {
      rerun.finalStatus = completed.properties?.status || 'Unknown';
      latest = completed;
    } else {
      rerun.finalStatus = 'TimedOutWaiting';
    }
  }

  const mdca = await getMdcaRunbookStatus(token);
  const activityWindowStart = latest?.properties?.startTime
    ? new Date(new Date(latest.properties.startTime).getTime() - 10 * 60 * 1000)
    : expectedWindowStart;
  const activityWindowEnd = latest?.properties?.endTime
    ? new Date(new Date(latest.properties.endTime).getTime() + 10 * 60 * 1000)
    : new Date();
  const activitySummary = await queryAdxActivitySummary(activityWindowStart, activityWindowEnd);
  const body = buildReport({ targetJob, expectedWindowStart, latest, rerun, mdca, activitySummary });
  console.log(body);
  if (!skipEmail) {
    await sendReportEmail(body);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
