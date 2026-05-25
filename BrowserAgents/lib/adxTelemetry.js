const fs = require('fs');
const path = require('path');
const { execFileSync, execSync } = require('child_process');

const projectRoot = path.resolve(__dirname, '..', '..');
const defaultConfigPath = path.join(projectRoot, 'config', 'agents.json');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function findAgent(config, persona, upn) {
  const agents = Array.isArray(config.agents) ? config.agents : [];
  return agents.find((agent) => {
    const sam = String(agent.sam || '').toLowerCase();
    const agentUpn = String(agent.userPrincipalName || agent.upn || '').toLowerCase();
    return sam === String(persona || '').toLowerCase() || agentUpn === String(upn || '').toLowerCase();
  }) || {};
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
      // Try the next Azure CLI path. Windows Node runners do not always resolve az.cmd through PATHEXT.
    }
  }
  try {
    const command = `"C:\\Program Files\\Microsoft SDKs\\Azure\\CLI2\\wbin\\az.cmd" keyvault secret show --vault-name "${vaultName}" --name "${secretName}" --query value -o tsv`;
    return execSync(command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], shell: true }).trim();
  } catch {
    // Fall through to disabled telemetry.
  }
  return '';
}

async function getClientCredentialToken(tenantId, clientId, clientSecret) {
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    scope: 'https://kusto.kusto.windows.net/.default',
    grant_type: 'client_credentials'
  });
  const response = await fetch(`https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });
  if (!response.ok) {
    throw new Error(`ADX token request failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()).access_token;
}

function compactText(value, maxLength = 30000) {
  const text = value == null ? '' : String(value);
  return text.length > maxLength ? `${text.slice(0, maxLength)}...[truncated]` : text;
}

class AdxTelemetryClient {
  constructor(options = {}) {
    this.configPath = options.configPath || process.env.BROWSER_AGENT_CONFIG_PATH || defaultConfigPath;
    this.config = fs.existsSync(this.configPath) ? readJson(this.configPath) : {};
    this.adx = this.config.adx || {};
    this.enabled = !/^true$/i.test(process.env.BROWSER_AGENT_ADX_DISABLED || '') && this.adx.enabled === true;
    this.token = null;
  }

  getAgentContext() {
    const persona = process.env.BROWSER_AGENT_PERSONA || 'priya.sharma';
    const upn = process.env.BROWSER_AGENT_UPN || `${persona}@${this.config?.tenant?.domain || 'contoso.example'}`;
    const agent = findAgent(this.config, persona, upn);
    return {
      sam: agent.sam || persona,
      upn: agent.userPrincipalName || agent.upn || upn,
      displayName: agent.displayName || process.env.BROWSER_AGENT_DISPLAY_NAME || persona,
      department: agent.department || agent.dept || '',
      jobTitle: agent.jobTitle || agent.role || '',
      copilotLicense: agent.copilotLicense === true
    };
  }

  async initialize() {
    if (!this.enabled || this.token) return this.enabled;
    const tenantId = this.adx.tenantId || this.config?.tenant?.tenantId;
    const clientId = this.adx.clientId;
    const secretName = this.adx.clientSecretName || 'agent-client-secret';
    const vaultName = this.adx.keyVaultName || this.config?.infrastructure?.keyVaultName;
    const clientSecret = process.env.BROWSER_AGENT_ADX_CLIENT_SECRET || getSecretFromAz(vaultName, secretName);

    if (!tenantId || !clientId || !clientSecret || !this.adx.queryBaseUri || !this.adx.databaseName || !this.adx.tableName) {
      this.enabled = false;
      return false;
    }

    this.token = await getClientCredentialToken(tenantId, clientId, clientSecret);
    return true;
  }

  async push(activityType, detail, properties = {}) {
    if (!(await this.initialize())) return false;
    const agent = this.getAgentContext();
    const event = {
      AgentUPN: agent.upn,
      AgentName: agent.displayName,
      Department: agent.department,
      JobTitle: agent.jobTitle,
      ActivityType: activityType,
      Detail: compactText(detail, 4000),
      PromptTokens: 0,
      ResponseTokens: 0,
      PromptContent: compactText(properties.PromptContent || ''),
      ResponseContent: compactText(properties.ResponseContent || ''),
      ActorUPN: agent.upn,
      ActorName: agent.displayName,
      ActorDepartment: agent.department,
      Source: 'BrowserAgent',
      ExecutionMode: process.env.PLAYWRIGHT_SERVICE_URL ? 'azure-playwright' : 'local-browser',
      ScenarioId: properties.ScenarioId || '',
      ...properties
    };

    const record = JSON.stringify({
      TimeGenerated: new Date().toISOString(),
      Event: event
    });

    const database = encodeURIComponent(this.adx.databaseName);
    const table = encodeURIComponent(this.adx.tableName);
    const mapping = encodeURIComponent(this.adx.mappingName || `${this.adx.tableName}_mapping`);
    const baseUri = String(this.adx.queryBaseUri || this.adx.ingestBaseUri).replace(/\/+$/, '');
    const uri = `${baseUri}/v1/rest/ingest/${database}/${table}?streamFormat=json&mappingName=${mapping}`;

    const response = await fetch(uri, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.token}`,
        'Content-Type': 'application/json'
      },
      body: record
    });
    if (!response.ok) {
      throw new Error(`ADX ingestion failed: ${response.status} ${await response.text()}`);
    }
    return true;
  }
}

function createTelemetryClient(options) {
  return new AdxTelemetryClient(options);
}

module.exports = { createTelemetryClient };
