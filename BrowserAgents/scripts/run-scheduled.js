const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const browserRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(browserRoot, '..');
const configPath = process.env.BROWSER_AGENT_CONFIG_PATH || path.join(repoRoot, 'config', 'agents.json');
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

function splitList(value, fallback = []) {
  if (!value) return fallback;
  return String(value)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

const configuredExternalRecipients = Array.isArray(config.externalRecipients)
  ? config.externalRecipients.filter(Boolean).join(',')
  : '';
const defaultExternalRecipients = configuredExternalRecipients || 'demo.recipient@example.com';

function findAgents() {
  const allAgents = Array.isArray(config.agents) ? config.agents : [];
  const wanted = splitList(process.env.BROWSER_AGENT_RUN_AGENTS);
  if (wanted.length === 0 || wanted.some((item) => item.toLowerCase() === 'all')) return allAgents;

  const keys = new Set(wanted.map((item) => item.toLowerCase()));
  return allAgents.filter((agent) => {
    return keys.has(String(agent.sam || '').toLowerCase())
      || keys.has(String(agent.userPrincipalName || '').toLowerCase())
      || keys.has(String(agent.displayName || '').toLowerCase());
  });
}

function hashText(value) {
  let hash = 0;
  for (let i = 0; i < value.length; i += 1) {
    hash = ((hash << 5) - hash) + value.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash);
}

function applyWeekendThrottle(agents) {
  const percent = Number(process.env.BROWSER_AGENT_WEEKEND_ACTIVITY_PERCENT || '0');
  if (!Number.isFinite(percent) || percent <= 0 || percent >= 100) return agents;

  const now = process.env.BROWSER_AGENT_RUN_DATE
    ? new Date(process.env.BROWSER_AGENT_RUN_DATE)
    : new Date();
  const day = now.getUTCDay();
  if (day !== 0 && day !== 6) return agents;

  const count = Math.max(1, Math.ceil(agents.length * (percent / 100)));
  const seed = now.toISOString().slice(0, 10);
  return [...agents]
    .sort((a, b) => hashText(`${seed}:${a.sam}`) - hashText(`${seed}:${b.sam}`))
    .slice(0, count);
}

function serviceTestFiles(services) {
  const files = [];
  for (const service of services) {
    const normalized = service.toLowerCase();
    if (normalized === 'owa' || normalized === 'mail') {
      files.push('tests/owa-daily-activity.spec.js');
    } else if (normalized === 'copilot' || normalized === 'ai') {
      files.push('tests/m365-copilot-daily-activity.spec.js');
    } else if (normalized === 'internalai' || normalized === 'internal-ai' || normalized === 'externalai' || normalized === 'foundry' || normalized === 'deepseek' || normalized === 'claude' || normalized === 'grok' || normalized === 'llama' || normalized === 'gemini') {
      files.push('tests/internal-ai-portal.spec.js');
    } else if (normalized === 'banking' || normalized === 'banking-wave1' || normalized === 'finance' || normalized === 'bf-wave1') {
      files.push('tests/banking-finance-wave1.spec.js');
    } else if (normalized === 'preflight') {
      files.push('tests/preflight.spec.js');
    } else {
      throw new Error(`Unknown BrowserAgent service '${service}'. Supported values: owa,copilot,internalai,banking,preflight.`);
    }
  }
  return [...new Set(files)];
}

function storageStatePath(agent) {
  return path.join(browserRoot, '.auth', `${agent.sam}.json`);
}

function ensureAuthState(agent) {
  const filePath = storageStatePath(agent);
  if (!fs.existsSync(filePath)) {
    throw new Error(`Browser session state '${path.relative(browserRoot, filePath)}' does not exist.`);
  }
  return filePath;
}

function runAgent(agent, services, testFiles) {
  const storageState = ensureAuthState(agent);
  const env = {
    ...process.env,
    BROWSER_AGENT_CONFIG_PATH: configPath,
    BROWSER_AGENT_PERSONA: agent.sam,
    BROWSER_AGENT_UPN: agent.userPrincipalName,
    BROWSER_AGENT_DISPLAY_NAME: agent.displayName,
    BROWSER_AGENT_STORAGE_STATE: storageState,
    BROWSER_AGENT_EMAIL_RECIPIENT: process.env.BROWSER_AGENT_EXTERNAL_RECIPIENT || defaultExternalRecipients,
    BROWSER_AGENT_SEND_EMAIL: process.env.BROWSER_AGENT_SEND_EMAIL || 'true',
    BROWSER_AGENT_INCLUDE_SENSITIVE: process.env.BROWSER_AGENT_INCLUDE_SENSITIVE || 'true',
    BROWSER_AGENT_EMAIL_LABEL: process.env.BROWSER_AGENT_EMAIL_LABEL || 'General'
  };

  const modelAlias = services.find((service) => /^(deepseek|claude|grok|llama|gemini)$/i.test(service));
  if (modelAlias && !env.BROWSER_AGENT_INTERNAL_AI_MODEL) {
    env.BROWSER_AGENT_INTERNAL_AI_MODEL = modelAlias.toLowerCase();
  }

  const playwrightCli = path.join(browserRoot, 'node_modules', 'playwright', 'cli.js');
  const args = [playwrightCli, 'test', ...testFiles];
  if (process.env.PLAYWRIGHT_SERVICE_URL) {
    args.push('-c', 'playwright.azure.config.js');
  } else {
    args.push('--project=chromium');
  }

  console.log(`\n=== BrowserAgent: ${agent.displayName} <${agent.userPrincipalName}> ===`);
  console.log(`Services: ${services.join(',')}`);
  console.log(`Mode: ${process.env.PLAYWRIGHT_SERVICE_URL ? 'Azure Playwright Workspace' : 'local Chromium'}`);

  const result = spawnSync(process.execPath, args, {
    cwd: browserRoot,
    env,
    stdio: 'inherit',
    shell: false
  });

  if (result.error) {
    throw result.error;
  }

  return {
    agent: agent.sam,
    displayName: agent.displayName,
    status: result.status === 0 ? 'success' : 'failed',
    exitCode: result.status == null ? 1 : result.status
  };
}

async function main() {
  const services = splitList(process.env.BROWSER_AGENT_SERVICES, ['owa', 'copilot', 'banking']);
  const configuredAgents = findAgents();
  const agents = applyWeekendThrottle(configuredAgents);
  if (agents.length === 0) {
    throw new Error('No BrowserAgents selected.');
  }
  const testFiles = serviceTestFiles(services);
  const continueOnFailure = /^true$/i.test(process.env.BROWSER_AGENT_CONTINUE_ON_FAILURE || '');

  console.log('=== BrowserAgent Scheduled Container Run ===');
  console.log(`Agents: ${agents.length}${agents.length !== configuredAgents.length ? ` of ${configuredAgents.length} after weekend throttle` : ''}`);
  console.log(`Services: ${services.join(',')}`);
  console.log(`External recipient(s): ${process.env.BROWSER_AGENT_EXTERNAL_RECIPIENT || defaultExternalRecipients}`);

  const summary = [];
  for (const agent of agents) {
    try {
      const result = runAgent(agent, services, testFiles);
      summary.push(result);
      if (result.status !== 'success' && !continueOnFailure) break;
    } catch (error) {
      summary.push({
        agent: agent.sam,
        displayName: agent.displayName,
        status: 'failed',
        exitCode: 1,
        comments: error.message
      });
      console.error(`[FAILED] ${agent.sam}: ${error.message}`);
      if (!continueOnFailure) break;
    }
  }

  console.log('\n=== BrowserAgent Scheduled Container Results ===');
  console.table(summary);
  if (summary.some((item) => item.status !== 'success')) {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
