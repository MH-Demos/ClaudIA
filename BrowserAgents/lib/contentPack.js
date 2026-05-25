const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const defaultPackRoot = path.join(repoRoot, 'synthetic-m365-purview-pack');

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function packRoot() {
  return process.env.BROWSER_AGENT_CONTENT_PACK_PATH || defaultPackRoot;
}

function loadPack() {
  const root = packRoot();
  const load = (fileName, key) => {
    const filePath = path.join(root, fileName);
    if (!fs.existsSync(filePath)) return [];
    const json = readJson(filePath);
    return Array.isArray(json[key]) ? json[key] : [];
  };

  return {
    emailSubjects: load('email-subjects.json', 'emailSubjects'),
    emailTemplates: load('email-templates.json', 'emailTemplates'),
    chatThreads: load('chat-threads.json', 'chatThreads'),
    documents: load('documents.json', 'documents'),
    aiPrompts: load('ai-prompts.json', 'aiPrompts'),
    externalSharingScenarios: load('external-sharing-scenarios.json', 'externalSharingScenarios'),
    labelingScenarios: load('labeling-scenarios.json', 'labelingScenarios')
  };
}

function hashText(value) {
  let hash = 0;
  const text = String(value || '');
  for (let i = 0; i < text.length; i += 1) {
    hash = ((hash << 5) - hash) + text.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash);
}

function pick(items, seed) {
  if (!Array.isArray(items) || items.length === 0) return null;
  return items[hashText(seed) % items.length];
}

function normalize(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function roleHints(ctx) {
  const department = normalize(ctx.department);
  const jobTitle = normalize(ctx.jobTitle);
  const displayName = normalize(ctx.displayName);
  const hints = new Set([department, jobTitle, displayName]);

  if (/finance|financial|cfo|commercial|datos/.test(`${department} ${jobTitle}`)) hints.add('finance');
  if (/hr|human|people|rrhh|compensation|recruit/.test(`${department} ${jobTitle}`)) hints.add('hr');
  if (/legal|counsel|abogad/.test(`${department} ${jobTitle}`)) hints.add('legal');
  if (/sales|comercial|account|customer/.test(`${department} ${jobTitle}`)) hints.add('sales');
  if (/engineer|infra|platform|devops|operaciones|operations/.test(`${department} ${jobTitle}`)) hints.add('engineering');
  if (/security|ciso|soc|cyber|seguridad/.test(`${department} ${jobTitle}`)) hints.add('it security');
  if (/data science|scientist|ciencia|analytics/.test(`${department} ${jobTitle}`)) hints.add('data science');
  if (/project|pmo|program/.test(`${department} ${jobTitle}`)) hints.add('pmo');
  if (/support|atenci/.test(`${department} ${jobTitle}`)) hints.add('customer support');
  if (/ceo|executive|leadership|director/.test(`${department} ${jobTitle}`)) hints.add('executive leadership');

  return [...hints].filter(Boolean);
}

function scoreTemplate(template, ctx) {
  const haystack = normalize([
    template.senderRole,
    template.recipientRole,
    template.businessScenario,
    template.subject
  ].join(' '));
  let score = 0;
  for (const hint of roleHints(ctx)) {
    if (hint && haystack.includes(hint)) score += hint.length > 5 ? 3 : 2;
  }
  if (ctx.copilotLicense && /copilot|ai|analysis/.test(haystack)) score += 1;
  return score;
}

function chooseEmailTemplate(ctx, pack = loadPack()) {
  const candidates = pack.emailTemplates
    .map((template) => ({ template, score: scoreTemplate(template, ctx) }))
    .filter((item) => item.score > 0);
  const pool = candidates.length > 0
    ? candidates.sort((a, b) => b.score - a.score).slice(0, 12).map((item) => item.template)
    : pack.emailTemplates;
  return pick(pool, `${ctx.persona}:${ctx.stamp}:email`);
}

function chooseAiPrompt(ctx, pack = loadPack()) {
  const desiredInteraction = ctx.copilotLicense ? 'CopilotInteraction' : 'AIAppInteraction';
  const hints = roleHints(ctx);
  const candidates = pack.aiPrompts.filter((prompt) => {
    const haystack = normalize([prompt.personaRole, prompt.sourceContext, prompt.expectedRisk, prompt.prompt].join(' '));
    return prompt.interactionType === desiredInteraction && hints.some((hint) => haystack.includes(hint));
  });
  return pick(candidates.length > 0 ? candidates : pack.aiPrompts, `${ctx.persona}:${ctx.stamp}:ai`);
}

function scoreDocument(document, ctx) {
  const haystack = normalize([
    document.department,
    document.title,
    document.shortSummary,
    document.sensitivityLevel,
    ...(Array.isArray(document.activityExplorerScenarios) ? document.activityExplorerScenarios : [])
  ].join(' '));
  let score = 0;
  for (const hint of roleHints(ctx)) {
    if (hint && haystack.includes(hint)) score += hint.length > 5 ? 3 : 2;
  }
  if (/confidential|highly confidential/.test(haystack)) score += 1;
  return score;
}

function chooseDocument(ctx, pack = loadPack()) {
  const candidates = pack.documents
    .map((document) => ({ document, score: scoreDocument(document, ctx) }))
    .filter((item) => item.score > 0);
  const pool = candidates.length > 0
    ? candidates.sort((a, b) => b.score - a.score).slice(0, 16).map((item) => item.document)
    : pack.documents;
  return pick(pool, `${ctx.persona}:${ctx.stamp}:document`);
}

function renderDocumentBrief(document) {
  if (!document) return '';
  const lines = [
    `Title: ${document.title}`,
    `File name: ${document.fileName}`,
    `Department: ${document.department}`,
    `Sensitivity: ${document.sensitivityLevel}`,
    `Suggested label: ${document.suggestedSensitivityLabel}`,
    '',
    document.shortSummary || '',
    '',
    'Sections:',
    ...(Array.isArray(document.sections) ? document.sections.map((section) => `- ${section}`) : [])
  ];
  if (Array.isArray(document.sampleRows) && document.sampleRows.length > 0) {
    lines.push('', 'Sample rows:');
    for (const row of document.sampleRows) lines.push(JSON.stringify(row));
  }
  if (Array.isArray(document.activityExplorerScenarios)) {
    lines.push('', `Activity Explorer intent: ${document.activityExplorerScenarios.join(', ')}`);
  }
  return lines.join('\n');
}

function buildEmailScenario(ctx, includeSensitive = true, pack = loadPack()) {
  const template = chooseEmailTemplate(ctx, pack);
  if (!template) return null;

  const body = [
    template.body,
    '',
    includeSensitive ? ctx.sensitiveBrief : ctx.normalBrief,
    '',
    `Synthetic demo reference: ${template.id}`,
    `Prepared by ${ctx.displayName}`
  ].join('\n');

  return {
    id: template.id,
    subject: `${template.subject} - ${ctx.stamp.slice(0, 16)}`,
    body,
    sensitivityLevel: template.sensitivityLevel || '',
    businessScenario: template.businessScenario || '',
    attachmentName: template.optionalAttachmentName || '',
    followUpPrompt: template.optionalFollowUpPrompt || ''
  };
}

function buildAiScenario(ctx, pack = loadPack()) {
  const prompt = chooseAiPrompt(ctx, pack);
  if (!prompt) return null;
  return {
    id: prompt.id,
    prompt: [
      prompt.prompt,
      '',
      'Use synthetic lab context only. Keep the response business-focused and avoid claiming the data is real.',
      '',
      ctx.sensitiveBrief
    ].join('\n'),
    interactionType: prompt.interactionType,
    expectedRisk: prompt.expectedRisk || '',
    safeBusinessPurpose: prompt.safeBusinessPurpose || '',
    sourceContext: prompt.sourceContext || ''
  };
}

module.exports = {
  loadPack,
  buildEmailScenario,
  buildAiScenario,
  chooseDocument,
  renderDocumentBrief,
  chooseEmailTemplate,
  chooseAiPrompt,
  pick
};
