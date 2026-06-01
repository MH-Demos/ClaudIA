const path = require('path');
const fs = require('fs');

function splitCsv(value) {
  return (value || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function resolveRepoRoot() {
  const configured = process.env.CLAUDIA_REPO_ROOT;
  if (configured && configured.trim()) {
    return path.resolve(configured);
  }

  return path.resolve(__dirname, '..', '..');
}

function readJsonIfExists(filePath) {
  if (!filePath || !fs.existsSync(filePath)) {
    return {};
  }

  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function resolveMaybeRelative(baseDir, value) {
  if (!value || !String(value).trim()) {
    return '';
  }

  if (path.isAbsolute(value)) {
    return path.resolve(value);
  }

  return path.resolve(baseDir, value);
}

function getConfig() {
  const defaultConfigPath = path.resolve(__dirname, '..', 'config', 'claudia.runtime.json');
  const botConfigPath = process.env.CLAUDIA_BOT_CONFIG
    ? path.resolve(process.env.CLAUDIA_BOT_CONFIG)
    : defaultConfigPath;
  const botConfig = readJsonIfExists(botConfigPath);
  const botConfigDir = path.dirname(botConfigPath);
  const runtime = botConfig.runtime || {};
  const bot = botConfig.bot || {};
  const repoRoot = resolveRepoRoot();

  return {
    port: Number(process.env.PORT || bot.port || 3978),
    repoRoot,
    botConfigPath: fs.existsSync(botConfigPath) ? botConfigPath : '',
    powershell: process.env.CLAUDIA_POWERSHELL || bot.powershell || 'pwsh',
    timeoutSeconds: Number(process.env.CLAUDIA_COMMAND_TIMEOUT_SECONDS || bot.timeoutSeconds || 900),
    outputMaxChars: Number(process.env.CLAUDIA_OUTPUT_MAX_CHARS || bot.outputMaxChars || 3500),
    allowedUsers: splitCsv(process.env.CLAUDIA_ALLOWED_USERS || (bot.allowedUsers || []).join(',')).map((item) => item.toLowerCase()),
    commandConfigPath: resolveMaybeRelative(
      botConfigDir,
      process.env.CLAUDIA_CONFIG_PATH || runtime.configPath || path.join(repoRoot, 'config', 'agents.json')
    ),
    installationDefinitionsPath: resolveMaybeRelative(
      botConfigDir,
      process.env.CLAUDIA_INSTALLATION_DEFINITIONS_PATH || runtime.installationDefinitionsPath || path.join(repoRoot, 'config', 'Installation_definitions.json')
    ),
    subscriptionId: process.env.CLAUDIA_SUBSCRIPTION_ID || runtime.subscriptionId || '',
    adxSubscriptionId: process.env.CLAUDIA_ADX_SUBSCRIPTION_ID || runtime.adxSubscriptionId || '',
    browserAgentsSubscriptionId: process.env.CLAUDIA_BROWSER_AGENTS_SUBSCRIPTION_ID || runtime.browserAgentsSubscriptionId || ''
  };
}

module.exports = {
  getConfig
};
