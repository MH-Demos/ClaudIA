const fs = require('fs');
const path = require('path');

function readAgentConfig(persona, upn) {
  const configPath = process.env.BROWSER_AGENT_CONFIG_PATH || path.resolve(__dirname, '..', '..', 'config', 'agents.json');
  if (!fs.existsSync(configPath)) return {};
  try {
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const agents = Array.isArray(config.agents) ? config.agents : [];
    return agents.find((agent) => {
      const sam = String(agent.sam || '').toLowerCase();
      const agentUpn = String(agent.userPrincipalName || agent.upn || '').toLowerCase();
      return sam === String(persona || '').toLowerCase() || agentUpn === String(upn || '').toLowerCase();
    }) || {};
  } catch {
    return {};
  }
}

function getPersonaContext() {
  const persona = process.env.BROWSER_AGENT_PERSONA || 'priya.sharma';
  const upn = process.env.BROWSER_AGENT_UPN || 'priya.sharma@contoso.example';
  const agent = readAgentConfig(persona, upn);
  const displayName = process.env.BROWSER_AGENT_DISPLAY_NAME || agent.displayName || 'Priya Sharma';
  const region = process.env.BROWSER_AGENT_REGION || 'US';
  const now = new Date();
  const stamp = now.toISOString().replace(/[:.]/g, '-');

  return {
    persona,
    upn,
    displayName,
    department: agent.department || '',
    jobTitle: agent.jobTitle || '',
    copilotLicense: agent.copilotLicense === true,
    firstName: displayName.split(/\s+/)[0],
    region,
    stamp,
    scenarioId: `${persona}-${region}-${stamp}`,
    sensitiveBrief: [
      `Scenario ID: ${persona}-${region}-${stamp}`,
      'Synthetic lab data only.',
      'Customer: Morgan Lee, morgan.lee@example.com, +1 206 555 0174',
      'Employee: Jordan Avery',
      'SSN: 384-29-5187',
      'ABA routing number: 021000021',
      'Bank account number: 492017388201',
      'Project: Copilot-assisted HR and sales correlation',
      'Risk: Sensitive HR, banking, and customer data combined in a browser workflow.'
    ].join('\n'),
    normalBrief: [
      `Scenario ID: ${persona}-${region}-${stamp}`,
      'Synthetic lab data only.',
      'Project: BrowserAgent external mail delivery validation',
      'Summary: Routine collaboration test without sensitive personal data.',
      'Action: Confirm external delivery, routing, and browser automation reliability.'
    ].join('\n')
  };
}

module.exports = { getPersonaContext };
