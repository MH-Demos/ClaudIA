const models = [...document.querySelectorAll('.model')];
const modelBadge = document.getElementById('modelBadge');
const conversation = document.getElementById('conversation');
const composer = document.getElementById('composer');
const promptBox = document.getElementById('prompt');
const documentUpload = document.getElementById('documentUpload');
const fileStatus = document.getElementById('fileStatus');
const statusText = document.getElementById('status');
let uploadedDocument = null;

function currentModel() {
  const active = document.querySelector('.model.active') || models[0];
  return {
    id: active.dataset.model,
    provider: active.dataset.provider,
    family: active.dataset.family,
    name: active.querySelector('span')?.innerText || active.dataset.model
  };
}

function setActiveModel(id) {
  const target = models.find((button) => button.dataset.model === id) || models[0];
  models.forEach((button) => button.classList.toggle('active', button === target));
  modelBadge.innerText = target.querySelector('span')?.innerText || target.dataset.model;
  statusText.innerText = `Selected ${modelBadge.innerText}`;
}

function addMessage(role, title, text) {
  const article = document.createElement('article');
  article.className = `message ${role}`;
  const strong = document.createElement('strong');
  strong.innerText = title;
  const body = document.createElement('p');
  body.innerText = text;
  article.append(strong, body);
  conversation.append(article);
  conversation.scrollTop = conversation.scrollHeight;
}

function buildResponse(model, prompt) {
  const riskTerms = [
    'employee', 'salary', 'invoice', 'routing', 'account', 'token',
    'customer', 'legal', 'confidential', 'incident', 'discount'
  ];
  const hits = riskTerms.filter((term) => prompt.toLowerCase().includes(term));
  const signal = hits.length > 0 ? hits.join(', ') : 'general business context';
  const documentLine = uploadedDocument
    ? `Uploaded document: ${uploadedDocument.name} (${uploadedDocument.size} bytes).`
    : 'No document was uploaded.';
  const outputType = /presentation|slides|deck|powerpoint/i.test(prompt)
    ? 'Suggested output: draft a 5-slide presentation with risk summary, key findings, recommended controls, owner actions, and demo notes.'
    : 'Suggested output: create an executive summary, key risks, and handling recommendation.';
  return [
    `${model.name} processed the synthetic lab prompt.`,
    documentLine,
    `Detected risk indicators: ${signal}.`,
    outputType,
    'Recommended handling: keep this response in the approved lab workspace, avoid external forwarding, and apply the appropriate Purview sensitivity label before sharing.',
    `Provider family: ${model.provider} / ${model.family}.`
  ].join('\n');
}

models.forEach((button) => {
  button.addEventListener('click', () => setActiveModel(button.dataset.model));
});

documentUpload.addEventListener('change', () => {
  const file = documentUpload.files?.[0] || null;
  uploadedDocument = file ? { name: file.name, size: file.size, type: file.type || 'application/octet-stream' } : null;
  fileStatus.innerText = uploadedDocument
    ? `${uploadedDocument.name} (${uploadedDocument.size} bytes)`
    : 'No document selected';
});

composer.addEventListener('submit', (event) => {
  event.preventDefault();
  const prompt = promptBox.value.trim();
  if (!prompt) {
    statusText.innerText = 'Enter a prompt before sending.';
    return;
  }
  const model = currentModel();
  addMessage('user', 'Prompt', prompt);
  statusText.innerText = `${model.name} is processing...`;
  window.setTimeout(() => {
    addMessage('assistant', `${model.name} response`, buildResponse(model, prompt));
    statusText.innerText = 'Response complete';
    document.body.dataset.lastModel = model.id;
    document.body.dataset.lastProvider = model.provider;
    document.body.dataset.lastFamily = model.family;
    document.body.dataset.lastInteraction = 'AIAppInteraction';
    document.body.dataset.lastUploadedFile = uploadedDocument?.name || '';
  }, 900);
});

const queryModel = new URLSearchParams(window.location.search).get('model');
setActiveModel(queryModel || 'deepseek');
