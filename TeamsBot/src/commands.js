const { runPowerShell } = require('./powershell');
const fs = require('fs');
const path = require('path');

const SERVICE_ALIASES = new Set([
  'spo',
  'sharepoint',
  'files',
  'mail',
  'email',
  'exchange',
  'outlook',
  'teams',
  'chat',
  'lists',
  'fabric',
  'meetings',
  'fileops',
  'activityexplorer',
  'copilot',
  'externalai',
  'foundry',
  'llama',
  'claude',
  'deepseek',
  'grok',
  'irm',
  'owa',
  'banking',
  'internalai'
]);

function normalizeText(text) {
  return (text || '')
    .replace(/<at>.*?<\/at>/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function parseTokens(text) {
  return normalizeText(text).split(' ').filter(Boolean);
}

function parseKeyValues(tokens) {
  const values = {};
  const positional = [];

  for (const token of tokens) {
    const match = token.match(/^([^=]+)=(.*)$/);
    if (match) {
      values[match[1].toLowerCase()] = match[2];
    } else {
      positional.push(token);
    }
  }

  return { values, positional };
}

function splitList(value) {
  if (!value) {
    return [];
  }

  return value
    .split(',')
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
}

function validateServices(services) {
  const invalid = services.filter((service) => !SERVICE_ALIASES.has(service));
  if (invalid.length > 0) {
    throw new Error(`Servicios no soportados: ${invalid.join(', ')}`);
  }
}

function formatHelp() {
  return [
    '**ClaudIA lista. Comandos disponibles:**',
    '',
    '`help` - muestra esta ayuda.',
    '`ping` - valida que el bot esta activo.',
    '`agents` - lista personajes configurados.',
    '`status [agente]` - muestra ultimos jobs de Azure Automation.',
    '`run <agente> [services=mail,teams]` - fuerza actividad de runbook para un personaje.',
    '`browser <agente> [services=owa,copilot] [azure=true]` - fuerza actividad BrowserAgent.',
    '`report runbook|browser|labels [agente]` - consulta reportes operativos.',
    '`storymap refresh [agente]` - genera datos frescos para Activity Story Map.',
    '`personaje <agente> [services=claude]` - alias de run para activar un personaje/modelo.',
    '',
    'Ejemplos:',
    '`run devon.reyes services=claude`',
    '`browser priya.sharma services=owa,copilot azure=true`',
    '`report labels laura.gomez`'
  ].join('\n');
}

function formatResult(title, result) {
  const status = result.ok ? 'OK' : `ERROR${result.code === null ? '' : ` (${result.code})`}`;
  const output = [result.stdout, result.stderr].filter(Boolean).join('\n\n');
  const body = output || 'Sin salida del comando.';

  return [`**${title}: ${status}**`, '', '```text', body, '```'].join('\n');
}

function withConfigPaths(config, args = {}) {
  const next = { ...args };
  if (config.commandConfigPath) {
    next.ConfigPath = config.commandConfigPath;
  }
  if (config.installationDefinitionsPath) {
    next.InstallationDefinitionsPath = config.installationDefinitionsPath;
  }
  return next;
}

function withConfigPathOnly(config, args = {}) {
  const next = { ...args };
  if (config.commandConfigPath) {
    next.ConfigPath = config.commandConfigPath;
  }
  return next;
}

function listAgents(config) {
  const configPath = config.commandConfigPath || path.join(config.repoRoot, 'config', 'agents.json');
  const labConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const agents = (labConfig.agents || []).map((agent) => {
    const sam = agent.sam || '';
    const display = agent.displayName || sam;
    const department = agent.department || '';
    const copilot = agent.copilotLicense ? 'copilot' : 'no-copilot';
    return `- ${sam} - ${display} (${department}, ${copilot})`;
  });

  return ['**Personajes configurados**', '', ...agents].join('\n');
}

async function executeCommand(config, text) {
  const tokens = parseTokens(text);
  const verb = (tokens.shift() || 'help').toLowerCase();

  if (['help', 'ayuda', '?'].includes(verb)) {
    return formatHelp();
  }

  if (['ping', 'hola', 'statusbot'].includes(verb)) {
    return 'ClaudIA esta activa y escuchando comandos.';
  }

  if (['agents', 'agentes', 'personajes'].includes(verb)) {
    return listAgents(config);
  }

  if (verb === 'status') {
    const { values, positional } = parseKeyValues(tokens);
    const agent = values.agent || positional[0] || '';
    const result = await runPowerShell(config, 'tools\\Get-RunbookStatus.ps1', withConfigPaths(config, {
      Agent: agent,
      Last: values.last || 10,
      SinceHours: values.hours || 48,
      IncludeStreams: values.streams === 'true' || positional.includes('streams'),
      IncludeOutput: values.output === 'true'
    }));
    return formatResult('Runbook status', result);
  }

  if (['run', 'ejecutar', 'personaje'].includes(verb)) {
    const { values, positional } = parseKeyValues(tokens);
    const agent = values.agent || positional[0];
    if (!agent) {
      return 'Indica el personaje: `run devon.reyes services=mail,teams`.';
    }

    const services = splitList(values.services || values.servicios || positional.slice(1).join(','));
    validateServices(services);

    const result = await runPowerShell(config, 'tests\\Test-SingleAgent.ps1', withConfigPaths(config, {
      Agent: agent,
      Services: services,
      SendEmail: values.sendemail === 'true',
      Sensitive: values.sensitive === 'true',
      Label: values.label || ''
    }));
    return formatResult(`Actividad forzada para ${agent}`, result);
  }

  if (verb === 'browser') {
    const { values, positional } = parseKeyValues(tokens);
    const agent = values.agent || positional[0];
    if (!agent) {
      return 'Indica el personaje: `browser priya.sharma services=owa,copilot azure=true`.';
    }

    const services = splitList(values.services || values.servicios || 'owa,copilot');
    validateServices(services);

    const result = await runPowerShell(config, 'tools\\Invoke-BrowserAgentDaily.ps1', withConfigPaths(config, {
      Agent: agent,
      Services: services,
      Azure: values.azure === 'true',
      SendEmail: values.sendemail === 'true',
      Sensitive: values.sensitive === 'true',
      Label: values.label || ''
    }));
    return formatResult(`BrowserAgent para ${agent}`, result);
  }

  if (verb === 'report') {
    const type = (tokens.shift() || 'runbook').toLowerCase();
    const { values, positional } = parseKeyValues(tokens);
    const agent = values.agent || positional[0] || '';

    if (['runbook', 'jobs'].includes(type)) {
      const result = await runPowerShell(config, 'tools\\Get-RunbookStatus.ps1', withConfigPaths(config, {
        Agent: agent,
        Last: values.last || 10,
        SinceHours: values.hours || 48,
        IncludeStreams: true
      }));
      return formatResult('Reporte runbook', result);
    }

    if (['browser', 'browseragent'].includes(type)) {
      const result = await runPowerShell(config, 'tools\\Get-BrowserAgentTelemetry.ps1', withConfigPathOnly(config, {
        Agent: agent,
        SinceMinutes: values.minutes || 120,
        Top: values.top || 30
      }));
      return formatResult('Reporte BrowserAgent', result);
    }

    if (['labels', 'label', 'etiquetas'].includes(type)) {
      const result = await runPowerShell(config, 'tools\\Get-LabelActivity.ps1', withConfigPaths(config, {
        Agent: agent,
        SinceHours: values.hours || 24,
        Top: values.top || 50
      }));
      return formatResult('Reporte etiquetas', result);
    }

    return 'Reporte no reconocido. Usa `report runbook`, `report browser` o `report labels`.';
  }

  if (verb === 'storymap') {
    const subcommand = (tokens.shift() || '').toLowerCase();
    if (!['refresh', 'refrescar', 'actualizar'].includes(subcommand)) {
      return 'Usa `storymap refresh [agente]`.';
    }

    const { values, positional } = parseKeyValues(tokens);
    const agent = values.agent || positional[0] || '';
    const result = await runPowerShell(config, 'tools\\Invoke-ActivityStoryMapRefresh.ps1', withConfigPaths(config, {
      Agents: agent ? [agent] : [],
      Parallel: values.parallel === 'true',
      NoADXWait: values.nowait === 'true'
    }));
    return formatResult('Activity Story Map refresh', result);
  }

  return `No reconozco \`${verb}\`. Usa \`help\` para ver comandos.`;
}

module.exports = {
  executeCommand,
  formatHelp
};
