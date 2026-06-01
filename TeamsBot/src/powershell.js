const path = require('path');
const { spawn } = require('child_process');

function toScriptPath(repoRoot, relativePath) {
  return path.join(repoRoot, relativePath);
}

function buildPowerShellArgs(scriptPath, namedArgs) {
  const args = ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath];

  for (const [name, value] of Object.entries(namedArgs || {})) {
    if (value === undefined || value === null || value === false || value === '') {
      continue;
    }

    args.push(`-${name}`);
    if (value === true) {
      continue;
    }

    if (Array.isArray(value)) {
      args.push(value.join(','));
    } else {
      args.push(String(value));
    }
  }

  return args;
}

function trimOutput(text, maxChars) {
  const normalized = (text || '').replace(/\r\n/g, '\n').trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }

  return `${normalized.slice(0, maxChars)}\n\n[output truncated]`;
}

function runPowerShell(config, relativeScriptPath, namedArgs) {
  const scriptPath = toScriptPath(config.repoRoot, relativeScriptPath);
  const args = buildPowerShellArgs(scriptPath, namedArgs);

  return new Promise((resolve) => {
    const child = spawn(config.powershell, args, {
      cwd: config.repoRoot,
      windowsHide: true,
      env: {
        ...process.env,
        CLAUDIA_CONFIG_PATH: config.commandConfigPath || '',
        CLAUDIA_INSTALLATION_DEFINITIONS_PATH: config.installationDefinitionsPath || '',
        CLAUDIA_SUBSCRIPTION_ID: config.subscriptionId || '',
        CLAUDIA_ADX_SUBSCRIPTION_ID: config.adxSubscriptionId || '',
        CLAUDIA_BROWSER_AGENTS_SUBSCRIPTION_ID: config.browserAgentsSubscriptionId || '',
        NO_COLOR: '1'
      }
    });

    let stdout = '';
    let stderr = '';
    let settled = false;

    const timeout = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      child.kill();
      resolve({
        ok: false,
        code: null,
        stdout: trimOutput(stdout, config.outputMaxChars),
        stderr: trimOutput(`${stderr}\nCommand timed out after ${config.timeoutSeconds} seconds.`, config.outputMaxChars)
      });
    }, config.timeoutSeconds * 1000);

    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    child.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    child.on('error', (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      resolve({
        ok: false,
        code: null,
        stdout: trimOutput(stdout, config.outputMaxChars),
        stderr: trimOutput(`${stderr}\n${error.message}`, config.outputMaxChars)
      });
    });

    child.on('close', (code) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      resolve({
        ok: code === 0,
        code,
        stdout: trimOutput(stdout, config.outputMaxChars),
        stderr: trimOutput(stderr, config.outputMaxChars)
      });
    });
  });
}

module.exports = {
  runPowerShell
};
