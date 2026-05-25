const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const packRoot = process.env.BROWSER_AGENT_CONTENT_PACK_PATH || path.join(repoRoot, 'synthetic-m365-purview-pack');
const outputPath = path.join(packRoot, 'content-pack.json');
const files = [
  ['email-subjects.json', 'emailSubjects'],
  ['email-templates.json', 'emailTemplates'],
  ['chat-threads.json', 'chatThreads'],
  ['documents.json', 'documents'],
  ['ai-prompts.json', 'aiPrompts'],
  ['external-sharing-scenarios.json', 'externalSharingScenarios'],
  ['labeling-scenarios.json', 'labelingScenarios']
];

function read(fileName) {
  const filePath = path.join(packRoot, fileName);
  const json = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  return json;
}

function validate() {
  const combined = {
    metadata: {
      packName: 'Synthetic Microsoft 365 Purview Demo Lab Content Pack',
      version: '1.0',
      fictionalDataOnly: true,
      generatedAt: new Date().toISOString()
    }
  };
  const report = [];
  const issues = [];

  for (const [fileName, key] of files) {
    const json = read(fileName);
    const arr = json[key];
    if (!Array.isArray(arr)) {
      issues.push(`${fileName}: missing array key ${key}`);
      combined[key] = [];
      continue;
    }
    combined[key] = arr;
    const ids = arr.map((item) => item.id).filter(Boolean);
    const uniqueIds = new Set(ids);
    report.push({ fileName, key, count: arr.length, ids: ids.length, duplicateIds: ids.length - uniqueIds.size });
  }

  const docs = new Set((combined.documents || []).map((doc) => String(doc.fileName || '').toLowerCase()));
  for (const scenario of combined.externalSharingScenarios || []) {
    const attachment = String(scenario.attachmentName || '').toLowerCase();
    if (attachment && !docs.has(attachment)) {
      issues.push(`external-sharing ${scenario.id}: attachment '${scenario.attachmentName}' is a derivative or missing document brief`);
    }
  }
  for (const scenario of combined.labelingScenarios || []) {
    const fileName = String(scenario.fileName || '').toLowerCase();
    if (fileName && !docs.has(fileName)) {
      issues.push(`labeling ${scenario.id}: file '${scenario.fileName}' is a derivative or missing document brief`);
    }
  }

  fs.writeFileSync(outputPath, JSON.stringify(combined, null, 2));
  console.log(JSON.stringify({ packRoot, outputPath, report, issueCount: issues.length, issues: issues.slice(0, 50) }, null, 2));
  if (issues.some((issue) => !/derivative or missing/.test(issue))) process.exitCode = 1;
}

validate();
