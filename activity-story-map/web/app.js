const params = new URLSearchParams(location.search);
const apiBase = (params.get("api") || window.ACTIVITY_API_BASE || "").replace(/\/$/, "");
const welcomeScreenEl = document.getElementById("welcomeScreen");
const appShellEl = document.getElementById("appShell");
const startButton = document.getElementById("startButton");
const graphEl = document.getElementById("graph");
const statusEl = document.getElementById("status");
const noticeEl = document.getElementById("notice");
const actorSelect = document.getElementById("actorSelect");
const hoursSelect = document.getElementById("hoursSelect");
const activitySelect = document.getElementById("activitySelect");
const viewSelect = document.getElementById("viewSelect");
const refreshButton = document.getElementById("refreshButton");
const fitButton = document.getElementById("fitButton");
const detailsEl = document.getElementById("details");
const portalStatusEl = document.getElementById("portalStatus");
const timelineEl = document.getElementById("timeline");
const journeyComponentSectionEl = document.getElementById("journeyComponentSection");
const journeyComponentTable = document.getElementById("journeyComponentTable");
const journeyComponentSummary = document.getElementById("journeyComponentSummary");
const journeyNarrativeEl = document.getElementById("journeyNarrative");
const storyTitleEl = document.getElementById("storyTitle");
const eventMetricLabelEl = document.getElementById("eventMetricLabel");
const activityControlsEl = document.getElementById("activityControls");
const solutionControlsEl = document.getElementById("solutionControls");
const solutionScopeLabel = document.getElementById("solutionScopeLabel");
const solutionCharacterLabel = document.getElementById("solutionCharacterLabel");
const solutionCharacterLabelText = document.getElementById("solutionCharacterLabelText");
const solutionScopeSelect = document.getElementById("solutionScopeSelect");
const solutionCharacterSelect = document.getElementById("solutionCharacterSelect");
const componentControlsEl = document.getElementById("componentControls");
const componentScopeSelect = document.getElementById("componentScopeSelect");
const componentCatalogSectionEl = document.getElementById("componentCatalogSection");
const componentCatalogTable = document.getElementById("componentCatalogTable");
const componentCatalogSummary = document.getElementById("componentCatalogSummary");
const activityModeButton = document.getElementById("activityModeButton");
const solutionModeButton = document.getElementById("solutionModeButton");
const charactersModeButton = document.getElementById("charactersModeButton");
const journeyModeButton = document.getElementById("journeyModeButton");
const componentsModeButton = document.getElementById("componentsModeButton");
const modeSelect = document.getElementById("modeSelect");
const journeyControlsEl = document.getElementById("journeyControls");
const journeyScenarioSelect = document.getElementById("journeyScenarioSelect");
const journeySpeedSelect = document.getElementById("journeySpeedSelect");
const journeyReplayButton = document.getElementById("journeyReplayButton");
const helpButton = document.getElementById("helpButton");
const guideOverlay = document.getElementById("guideOverlay");
const guideStepLabel = document.getElementById("guideStepLabel");
const guideTitle = document.getElementById("guideTitle");
const guideBody = document.getElementById("guideBody");
const guideSkipButton = document.getElementById("guideSkipButton");
const guideNextButton = document.getElementById("guideNextButton");

let cy;
let lastPayload;
let solutionPayload;
let isLoading = false;
let assetMap = { characters: {}, services: {} };
let characterProfiles = { profiles: [] };
let activeMode = "activity";
let visitStats = null;
let lastDataRefreshAt = null;
let hasStarted = false;
let journeyStepIndex = 0;
let journeyTimer = null;
let guideStepIndex = 0;

const journeyScenarios = [
  {
    id: "identity-rbac",
    title: "Identity, RBAC and least privilege",
    actionLabel: "Perform authorized action",
    serviceKey: "outlook",
    targetLabel: "Microsoft 365",
    outcome: "The demo shows why agents should run with explicit identities, scoped permissions, and auditable access.",
    steps: [
      { node: "service:tenant", label: "Tenant provides identity plane", detail: "The demo starts with Microsoft Entra users and the Azure subscription boundary." },
      { node: "service:subscription", label: "Azure subscription hosts resources", detail: "The subscription is the billing, policy, and deployment boundary for Azure components." },
      { node: "service:resource-group", label: "Resource group organizes services", detail: "Automation, Key Vault, ADX, Storage, Functions, and Front Door are grouped for operations." },
      { node: "service:entra", label: "Entra ID represents users and agents", detail: "The selected persona has a user object, licenses, and workload permissions." },
      { node: "service:licenses", label: "Licenses define usable workloads", detail: "A persona can only use services assigned to that account." },
      { node: "activity:schedule", label: "Schedule starts the demo", detail: "A scheduled trigger makes the agent predictable and repeatable." },
      { node: "service:automation", label: "Automation Account hosts the runbook", detail: "The runbook executes from Azure rather than a presenter laptop." },
      { node: "activity:runbook", label: "Runbook receives managed identity", detail: "Azure Automation can use a managed identity instead of hard-coded credentials." },
      { node: "service:rbac", label: "RBAC scopes what the agent can do", detail: "Roles limit access to only the resources needed for the demo." },
      { node: "service:keyvault", label: "Key Vault validates secret access", detail: "The identity can read selected secrets without exposing them in code." },
      { node: "service:storyline", label: "Agent definitions select the persona", detail: "Config and storyline decide who acts, why, and against which workload." },
      { node: "service:openai", label: "Azure OpenAI generates content", detail: "Generated emails, prompts, and documents make demos realistic without static canned text." },
      { node: "service:office", label: "Microsoft 365 checks permissions", detail: "The simulated user can only reach services licensed and allowed for that account." },
      { node: "activity:action", label: "Agent performs the task", detail: "The action is useful because identity, permission, and workload context are aligned." },
      { node: "service:adx", label: "ADX cluster receives evidence", detail: "Each run becomes queryable telemetry for validation and storytelling." },
      { node: "service:adx-table", label: "ADX table stores normalized events", detail: "The portal can filter by actor, workload, action, and target." },
      { node: "service:purview", label: "Purview adds governance view", detail: "Security teams can review activity through audit, DLP, and compliance signals." }
    ]
  },
  {
    id: "keyvault-secrets",
    title: "Key Vault and secret hygiene",
    actionLabel: "Use secret securely",
    serviceKey: "azure",
    targetLabel: "Azure Key Vault",
    outcome: "The demo explains how secrets stay outside scripts, logs, browser code, and portal configuration.",
    steps: [
      { node: "activity:schedule", label: "Schedule starts the run", detail: "The agent can run unattended because secrets are managed centrally." },
      { node: "service:resource-group", label: "Resource group contains dependencies", detail: "The demo components are operated as a related solution, not as isolated resources." },
      { node: "service:automation", label: "Automation Account executes securely", detail: "The runbook runs in Azure with a controlled identity boundary." },
      { node: "activity:runbook", label: "Runbook asks for an agent", detail: "The runbook decides which persona and workload need credentials." },
      { node: "service:rbac", label: "RBAC checks the caller", detail: "Only the Automation identity or browser job identity should reach Key Vault." },
      { node: "service:keyvault", label: "Key Vault returns selected secrets", detail: "Secrets are retrieved at runtime and never committed to the repo." },
      { node: "activity:user-secret", label: "User secret is mapped to persona", detail: "The demo can emulate a user without sharing passwords with the presenter." },
      { node: "service:playwright", label: "Playwright uses the secret indirectly", detail: "The browser session receives what it needs without knowing the vault internals." },
      { node: "service:edge", label: "Edge signs in to Office Web", detail: "The audience sees the result, while secret handling remains hidden and secure." },
      { node: "service:office", label: "Office action runs as that user", detail: "The simulated activity is attributable to the intended account." },
      { node: "activity:action", label: "Agent completes the scenario", detail: "Credentials enabled the task, but did not leak into application code." },
      { node: "service:adx", label: "ADX receives sanitized telemetry", detail: "Telemetry should include what happened, not the secret values." },
      { node: "service:adx-table", label: "ADX table keeps only event data", detail: "Secrets should never appear in telemetry payloads or portal details." },
      { node: "service:purview", label: "Purview shows governance impact", detail: "Compliance views focus on activity and risk, not credential material." }
    ]
  },
  {
    id: "playwright-browser",
    title: "Playwright browser automation",
    actionLabel: "Automate browser workflow",
    serviceKey: "edge",
    targetLabel: "Playwright Workspace",
    outcome: "The demo shows why browser agents are useful when APIs do not reproduce the full user interaction.",
    steps: [
      { node: "activity:schedule", label: "Schedule starts browser job", detail: "The automation can create realistic activity on a cadence." },
      { node: "service:browser-platform", label: "Browser agent layer is selected", detail: "This path uses Container Apps jobs for richer browser-based activity." },
      { node: "service:acr", label: "ACR provides the job image", detail: "The job pulls a known container image with Playwright tests and dependencies." },
      { node: "service:container-env", label: "Container Apps Environment hosts jobs", detail: "The environment provides runtime isolation, networking, and scale control." },
      { node: "service:container-jobs", label: "Container Apps Jobs run the scenario", detail: "Morning, midday, and afternoon jobs can run independently." },
      { node: "service:browser-identity", label: "Managed Identity authorizes the job", detail: "The job reads only the secrets and telemetry targets it is allowed to access." },
      { node: "service:keyvault", label: "Key Vault provides sign-in material", detail: "The job receives credentials securely at runtime." },
      { node: "service:storyline", label: "Storyline gives human intent", detail: "The agent gets realistic business instructions and content." },
      { node: "service:openai", label: "Azure OpenAI can enrich content", detail: "Some scenarios generate believable business text before browser execution." },
      { node: "service:playwright", label: "Playwright workspace runs the session", detail: "The browser is isolated, repeatable, and observable." },
      { node: "service:edge", label: "Edge renders the real UI", detail: "The demo can show actual screens instead of only API calls." },
      { node: "service:office", label: "Office Web performs user workflow", detail: "Buttons, upload flows, sharing dialogs, and web-only paths can be exercised." },
      { node: "activity:action", label: "Agent performs visible activity", detail: "The audience sees the agent do something a human would recognize." },
      { node: "service:loganalytics", label: "Log Analytics captures job logs", detail: "Operational logs help troubleshoot job startup, image pull, and runtime failures." },
      { node: "service:adx", label: "ADX records browser telemetry", detail: "Run details become queryable for validation and troubleshooting." },
      { node: "service:adx-table", label: "ADX table normalizes events", detail: "The Activity Map reads a consistent schema rather than raw browser traces." },
      { node: "service:purview", label: "Purview correlates user activity", detail: "The browser activity appears in governance and audit stories." }
    ]
  },
  {
    id: "storage-portal",
    title: "Storage, portal and API pattern",
    actionLabel: "Publish educational portal",
    serviceKey: "azure",
    targetLabel: "Static Website",
    outcome: "The demo explains why a static portal, API layer, storage, and telemetry backend are separated.",
    steps: [
      { node: "service:subscription", label: "Subscription hosts portal resources", detail: "The portal resources live in the Azure subscription under the lab resource group." },
      { node: "service:resource-group", label: "Resource group groups the portal", detail: "Storage, Function App, Front Door, ADX, and monitoring are operated together." },
      { node: "service:storage", label: "Storage hosts static web assets", detail: "HTML, CSS, JavaScript, icons, and character images can be served cheaply." },
      { node: "service:assets", label: "Assets make the portal teachable", detail: "Service icons, character images, and branding make architecture easier to explain." },
      { node: "service:edgefront", label: "Front Door exposes the portal", detail: "An edge route can add a friendly endpoint and performance layer." },
      { node: "service:api", label: "Function API protects backend access", detail: "The browser calls an API instead of connecting directly to ADX." },
      { node: "service:function-storage", label: "Function Storage supports runtime state", detail: "Azure Functions uses storage for runtime metadata and lightweight portal counters." },
      { node: "service:rbac", label: "Managed identity controls API access", detail: "The Function can query backend services with least privilege." },
      { node: "service:adx", label: "ADX serves activity queries", detail: "The portal asks for filtered graph data from telemetry tables." },
      { node: "service:adx-table", label: "ADX table provides graph data", detail: "The API projects rows into nodes, edges, filters, and timeline entries." },
      { node: "service:appinsights", label: "Application Insights observes the API", detail: "API health and diagnostics are separate from agent activity telemetry." },
      { node: "service:storyline", label: "Storyline assets explain context", detail: "Profiles, scenarios, and labels turn raw events into a teachable story." },
      { node: "activity:action", label: "Presenter filters a scenario", detail: "The audience can switch between learning paths during the demo." },
      { node: "service:purview", label: "Purview provides security narrative", detail: "The portal links technical architecture to compliance outcomes." }
    ]
  },
  {
    id: "adx-observability",
    title: "ADX telemetry and observability",
    actionLabel: "Query telemetry",
    serviceKey: "microsoft.purview",
    targetLabel: "ADX and Purview",
    outcome: "The demo shows how raw agent actions become evidence that can be queried, filtered, and explained.",
    steps: [
      { node: "activity:schedule", label: "Schedule creates repeatable runs", detail: "Repeated activity gives the demo enough telemetry to analyze." },
      { node: "service:openai", label: "Azure OpenAI can generate scenario content", detail: "Content generation is part of the activity story when scenarios need realistic text." },
      { node: "activity:runbook", label: "Runbook emits normalized events", detail: "Each run should log agent, actor, workload, action, target, and detail." },
      { node: "service:container-jobs", label: "Browser jobs add UI telemetry", detail: "UI automation can produce signals that pure Graph calls do not." },
      { node: "service:purview", label: "Purview captures governance signals", detail: "DLP, audit, sensitivity, and sharing activity enrich the story." },
      { node: "service:adx", label: "ADX stores the activity model", detail: "The table keeps event history for fast KQL queries and graph building." },
      { node: "service:adx-table", label: "ADX table stores normalized payloads", detail: "A consistent schema makes filters and graph construction predictable." },
      { node: "service:workbook", label: "Workbook validates telemetry health", detail: "The workbook helps verify counts, recent runs, and ingestion quality." },
      { node: "service:api", label: "Function API queries ADX", detail: "The portal receives clean graph payloads instead of raw backend details." },
      { node: "service:storage", label: "Portal displays cached assets", detail: "Icons and profiles make telemetry easier to understand." },
      { node: "activity:action", label: "Presenter filters the evidence", detail: "Filters can show email, files, AI, identity, or governance scenarios." }
    ]
  }
];

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function slug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/@.*$/, "")
    .replace(/[^a-z0-9]+/g, ".")
    .replace(/^\.+|\.+$/g, "");
}

function formatDateTime(value) {
  if (!value) return "--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "--";
  return date.toLocaleString([], {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit"
  });
}

function updatePortalStatus() {
  if (!portalStatusEl) return;
  const visits = visitStats && Number.isFinite(Number(visitStats.totalVisits))
    ? Number(visitStats.totalVisits).toLocaleString()
    : "--";
  const unique = visitStats && Number.isFinite(Number(visitStats.uniqueVisitors))
    ? Number(visitStats.uniqueVisitors).toLocaleString()
    : "--";
  portalStatusEl.textContent = `Last data refresh: ${formatDateTime(lastDataRefreshAt)} | Visits: ${visits} | Unique: ${unique}`;
}

async function updateVisitStats({ countVisit = false } = {}) {
  if (!apiBase) {
    updatePortalStatus();
    return;
  }
  try {
    const response = await fetch(`${apiBase}/api/visits`, {
      method: countVisit ? "POST" : "GET",
      cache: "no-store"
    });
    if (response.ok) {
      visitStats = await response.json();
      updatePortalStatus();
    }
  } catch {
    updatePortalStatus();
  }
}

async function loadAssetMap() {
  try {
    const response = await fetch("./images/manifest.json", { cache: "no-store" });
    if (response.ok) assetMap = await response.json();
  } catch {
    assetMap = { characters: {}, services: {} };
  }
}

async function loadCharacterProfiles() {
  try {
    const response = await fetch("./character-profiles.json", { cache: "no-store" });
    if (response.ok) characterProfiles = await response.json();
  } catch {
    characterProfiles = { profiles: [] };
  }
}

function getCharacterProfile(idOrKey) {
  const key = slug(String(idOrKey || "").replace(/^agent:/, ""));
  return (characterProfiles.profiles || []).find((profile) => (
    profile.id === idOrKey ||
    profile.key === key ||
    slug(profile.displayName) === key ||
    slug(profile.upn) === key
  ));
}

function serviceKey(value, event = {}) {
  const raw = String(value || "");
  const normalizedSlug = slug(raw);
  const normalized = normalizedSlug.replaceAll(".", "");
  const detail = `${event.Detail || ""} ${event.TargetName || ""} ${event.SearchQuery || ""}`;
  const combined = `${raw} ${event.Service || ""} ${event.Workload || ""} ${event.ActivityType || ""} ${detail}`;
  const combinedKey = slug(combined).replaceAll(".", "");
  if (combinedKey.includes("azureaifoundry") || combinedKey.includes("foundry")) {
    if (combinedKey.includes("claude") || combinedKey.includes("anthropic")) return "azure.ai.foundry.claude";
    if (combinedKey.includes("deepseek")) return "azure.ai.foundry.deepseek";
    if (combinedKey.includes("grok") || combinedKey.includes("xai")) return "azure.ai.foundry.grok";
    if (combinedKey.includes("llama") || combinedKey.includes("meta")) return "azure.ai.foundry.llama";
    return "azure.ai.foundry";
  }
  if (combinedKey.includes("externalai")) {
    if (combinedKey.includes("claude") || combinedKey.includes("anthropic")) return "claude";
    if (combinedKey.includes("deepseek")) return "deepseek";
    if (combinedKey.includes("grok") || combinedKey.includes("xai")) return "grok";
    if (combinedKey.includes("llama") || combinedKey.includes("meta")) return "llama";
    if (combinedKey.includes("chatgpt") || combinedKey.includes("openai")) return "azure.ai.foundry";
  }
  if (normalized.includes("securitycopilot")) return "security.copilot";
  if (normalized.includes("copilot")) return "copilot";
  if (normalized.includes("team")) return "teams";
  if (normalized.includes("sharepoint") || normalized === "spo") return "sharepoint";
  if (normalized.includes("onedrive") || normalized === "odb") return "onedrive";
  if (normalized.includes("outlook")) return "outlook";
  if (normalized.includes("exchange") || normalized.includes("mail") || normalized.includes("email")) return "mail";
  if (normalized.includes("powerbi")) return "power.bi";
  if (normalized.includes("powerpoint")) return "powerpoint";
  if (normalized.includes("excel")) return "excel";
  if (normalized.includes("word")) return "word";
  if (normalized.includes("forms")) return "forms";
  if (normalized.includes("stream")) return "stream";
  if (normalized.includes("onenote")) return "onenote";
  if (normalized.includes("powershell")) return "powershell";
  if (normalized.includes("fabric")) return "fabric";
  if (normalized.includes("entra")) return "entra.id";
  if (normalized.includes("purview")) return "microsoft.purview";
  if (normalized.includes("sentinel")) return "microsoft.sentinel";
  if (normalized.includes("defender")) return "defender";
  if (normalized.includes("intune")) return "intune";
  if (normalized === "azure" || normalized.includes("azureportal")) return "azure";
  if (normalized.includes("edge")) return "edge";
  if (normalized.includes("viva")) return "viva";
  if (normalized.includes("deepseek")) return "deepseek";
  if (normalized.includes("claude") || normalized.includes("anthropic")) return "claude";
  if (normalized.includes("grok") || normalized.includes("xai")) return "grok";
  if (normalized.includes("llama") || normalized.includes("meta")) return "llama";
  if (normalized.includes("foundry")) return "azure.ai.foundry";
  return normalizedSlug;
}

function serviceLabel(event) {
  const service = event.Service || event.Workload || event.ActivityType || "Activity";
  if ((event.Workload || "").toLowerCase() === "externalai" && event.Service) return event.Service;
  return service;
}

function nodeColor(type) {
  switch ((type || "").toLowerCase()) {
    case "user": return "#49a4ff";
    case "service": return "#68d391";
    case "activity": return "#202428";
    case "tenant": return "#7dd3fc";
    case "subscription": return "#38bdf8";
    case "resourcegroup": return "#2f6b9f";
    case "paas": return "#68d391";
    case "saas": return "#b18cff";
    case "security": return "#f6c453";
    case "ai": return "#f472b6";
    case "data": return "#22c55e";
    case "api": return "#60a5fa";
    case "web": return "#2dd4bf";
    case "storage": return "#a3e635";
    case "edge": return "#f97316";
    case "process": return "#c084fc";
    case "definition": return "#94a3b8";
    case "asset": return "#fb7185";
    case "license": return "#fde047";
    case "monitoring": return "#22d3ee";
    case "compute": return "#38bdf8";
    case "identity": return "#facc15";
    case "email":
    case "emailthread": return "#f6c453";
    case "searchquery": return "#b18cff";
    case "file":
    case "image": return "#ff9f43";
    default: return "#d8dee6";
  }
}

function actionName(event) {
  return event.Action || event.ActivityType || "activity";
}

function activityName(event) {
  const action = actionName(event);
  const service = serviceLabel(event);
  return `${service} | ${action}`;
}

function shortTarget(event) {
  return event.TargetName || event.Subject || event.SearchQuery || event.Detail || event.RecipientName || event.RecipientUPN || "";
}

function eventTitle(event) {
  const actor = event.ActorName || event.AgentName || "Someone";
  const action = actionName(event);
  const target = shortTarget(event);
  const recipient = event.RecipientName || event.RecipientUPN || "";
  if (recipient) return `${actor} ${action} to ${recipient}`;
  if (target) return `${actor} ${action}: ${target}`;
  return `${actor} ${action}`;
}

function selectedActors() {
  return [...actorSelect.selectedOptions].map((option) => option.value).filter(Boolean);
}

function actorMatches(event, actors) {
  if (actors.length === 0) return true;
  const actorValues = [
    event.ActorName,
    event.AgentName,
    event.ActorUPN,
    event.AgentUPN,
    slug(event.ActorName),
    slug(event.AgentName),
    slug(event.ActorUPN),
    slug(event.AgentUPN)
  ].filter(Boolean);
  return actors.some((actor) => actorValues.includes(actor) || actorValues.includes(slug(actor)));
}

function addNode(nodes, id, label, type, extra = {}) {
  if (!id || nodes.has(id)) return;
  const characterImage = assetMap.characters[id] || assetMap.characters[slug(id)] || assetMap.characters[slug(label)] || "";
  const serviceImage = assetMap.services[extra.serviceKey] || assetMap.services[serviceKey(label)] || "";
  const image = type === "user" ? characterImage : serviceImage;
  nodes.set(id, {
    id,
    label,
    type,
    color: nodeColor(type),
    image,
    ...extra
  });
}

function addEdge(edges, source, target, label, event) {
  if (!source || !target) return;
  const key = `${source}|${target}|${label}`;
  if (!edges.has(key)) {
    edges.set(key, {
      id: key,
      source,
      target,
      label,
      count: 0,
      events: [],
      firstSeen: event.TimeGenerated,
      lastSeen: event.TimeGenerated
    });
  }
  const edge = edges.get(key);
  edge.count += 1;
  edge.events.push(event);
  if (event.TimeGenerated < edge.firstSeen) edge.firstSeen = event.TimeGenerated;
  if (event.TimeGenerated > edge.lastSeen) edge.lastSeen = event.TimeGenerated;
}

function filteredEvents(payload) {
  const selectedActivity = activitySelect.value;
  const actors = selectedActors();
  const events = payload.events || [];
  return events.filter((event) => {
    if (selectedActivity && activityName(event) !== selectedActivity) return false;
    return actorMatches(event, actors);
  });
}

function buildSummaryGraph(events) {
  const nodes = new Map();
  const edges = new Map();

  events.forEach((event) => {
    const actorId = event.ActorUPN || event.AgentUPN || event.ActorName || event.AgentName;
    const actorLabel = event.ActorName || event.AgentName || actorId;
    const activity = activityName(event);
    const activityId = `activity:${activity}`;
    const recipientId = event.RecipientUPN || "";

    addNode(nodes, actorId, actorLabel, "user", { department: event.Department });
    addNode(nodes, activityId, activity.replace(" | ", "\n"), "activity", { activity, serviceKey: serviceKey(serviceLabel(event), event) });
    addEdge(edges, actorId, activityId, actionName(event), event);

    if (recipientId) {
      addNode(nodes, recipientId, event.RecipientName || recipientId, "user");
      addEdge(edges, activityId, recipientId, "to recipient", event);
    }
  });

  return {
    nodes: [...nodes.values()],
    edges: [...edges.values()].map((edge) => ({
      ...edge,
      label: `${edge.label} (${edge.count})`,
      rawLabel: edge.label
    }))
  };
}

function buildDetailGraph(events) {
  const nodes = new Map();
  const edges = new Map();

  events.forEach((event) => {
    const actorId = event.ActorUPN || event.AgentUPN || event.ActorName || event.AgentName;
    const actorLabel = event.ActorName || event.AgentName || actorId;
    const service = serviceLabel(event);
    const serviceId = `service:${service}`;
    const target = event.RecipientUPN || event.TargetName || event.Subject || event.SearchQuery || serviceId;
    const targetType = event.RecipientUPN ? "user" : (event.TargetType || "file");
    const targetId = event.RecipientUPN || `${targetType}:${target}`;

    addNode(nodes, actorId, actorLabel, "user", { department: event.Department });
    addNode(nodes, serviceId, service, "service", { serviceKey: serviceKey(service, event) });
    addNode(nodes, targetId, event.RecipientName || target, targetType);
    addEdge(edges, actorId, serviceId, actionName(event), event);
    addEdge(edges, serviceId, targetId, actionName(event), event);
  });

  return {
    nodes: [...nodes.values()],
    edges: [...edges.values()].map((edge) => ({
      ...edge,
      label: `${edge.rawLabel || edge.label} (${edge.count})`,
      rawLabel: edge.rawLabel || edge.label
    }))
  };
}

function selectedJourneyScenario() {
  return journeyScenarios.find((scenario) => scenario.id === journeyScenarioSelect.value) || journeyScenarios[0];
}

function selectedJourneyAgent() {
  const profiles = characterProfiles.profiles || [];
  return profiles.find((profile) => profile.id === "agent:alexander.meyer") || profiles[0] || {
    id: "agent:alexander.meyer",
    key: "alexander.meyer",
    displayName: "Alexander Meyer",
    role: "Autonomous agent"
  };
}

function journeyNodeImage(type, key, label) {
  if (type === "user") return assetMap.characters[key] || assetMap.characters[slug(label)] || "";
  return assetMap.services[key] || assetMap.services[serviceKey(label)] || "";
}

function buildJourneyGraph() {
  const scenario = selectedJourneyScenario();
  const agent = selectedJourneyAgent();
  const nodes = [
    {
      id: "service:tenant",
      label: "Tenant\ncontoso.example",
      type: "tenant",
      layer: "Foundation",
      details: {
        "Solution component": "tenant:contoso.example",
        Purpose: "Identity and governance boundary for Microsoft 365 and Azure access",
        "Why it matters": "Every agent, user, app, permission, and audit story sits inside this trust boundary."
      }
    },
    {
      id: "service:subscription",
      label: "Azure Subscription\nClaudIA Demo Subscription",
      type: "subscription",
      layer: "Foundation",
      details: {
        "Solution component": "subscription:karla",
        Purpose: "Hosts the Azure resource group and paid services",
        "Why it matters": "Beginners need to know where cost, policy, and Azure RBAC start."
      }
    },
    {
      id: "service:resource-group",
      label: "Resource Group\nrg-claudia-lab",
      type: "resourceGroup",
      layer: "Foundation",
      details: {
        "Solution component": "rg:claudia-lab",
        Purpose: "Groups the solution resources for deployment and operations",
        "Why it matters": "Shows how related Azure services are organized, monitored, and cleaned up."
      }
    },
    {
      id: "service:entra",
      label: "Microsoft Entra ID\nUsers and identities",
      type: "saas",
      serviceKey: "entra.id",
      image: journeyNodeImage("service", "entra.id", "Entra ID"),
      layer: "Identity",
      details: {
        "Solution component": "m365:entra",
        Purpose: "Stores users, app identities, and sign-in context",
        "Why it matters": "Agent demos need attributable identities so activity is understandable and auditable."
      }
    },
    {
      id: "service:licenses",
      label: "Microsoft 365\nLicenses",
      type: "license",
      layer: "Identity",
      details: {
        "Solution component": "m365:licenses",
        Purpose: "Controls which M365 workloads each persona can use",
        "Why it matters": "A user can only perform actions in services they are licensed and allowed to access."
      }
    },
    {
      id: "service:automation",
      label: "Automation Account\naa-claudia-lab",
      type: "paas",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Automation",
      details: {
        "Solution component": "aa:aa-claudia-lab",
        Purpose: "Hosts and schedules the PowerShell runbook",
        "Why it matters": "Moves orchestration into Azure so demos are repeatable and not tied to one laptop."
      }
    },
    {
      id: "activity:schedule",
      label: "Schedule",
      type: "process",
      layer: "Automation",
      details: { Purpose: "Starts the scheduled scenario", Scenario: scenario.title }
    },
    {
      id: "activity:runbook",
      label: "Azure Automation\nRunbook",
      type: "process",
      layer: "Automation",
      details: {
        Purpose: "Selects scenario, persona, and browser task",
        "Why it matters": "Keeps repeatable agent orchestration outside the presenter laptop."
      }
    },
    {
      id: agent.id,
      label: `${agent.displayName}\n${agent.role || "Agent persona"}`,
      type: "user",
      image: journeyNodeImage("user", agent.key || slug(agent.displayName), agent.displayName),
      layer: "Persona",
      details: {
        UPN: agent.upn,
        Department: agent.department,
        Role: agent.role,
        "Why it matters": "Personas make agent activity human-readable during demos."
      }
    },
    {
      id: "service:rbac",
      label: "Managed Identity\n+ RBAC",
      type: "identity",
      layer: "Access control",
      details: {
        Purpose: "Grants the automation identity only the permissions it needs",
        "Demo point": "Use this to explain least privilege, role assignment, and why secrets alone are not an access model."
      }
    },
    {
      id: "service:browser-platform",
      label: "Browser Agents\nRegional automation",
      type: "process",
      layer: "Browser agents",
      details: {
        "Solution component": "browser:platform",
        Purpose: "Groups the regional browser automation runtime",
        "Why it matters": "Separates richer UI-driven simulations from the core runbook path."
      }
    },
    {
      id: "service:acr",
      label: "Azure Container\nRegistry",
      type: "storage",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Browser agents",
      details: {
        "Solution component": "browser:acr",
        Purpose: "Stores the browser-agent container image",
        "Why it matters": "Jobs run a known, versioned image with Playwright dependencies."
      }
    },
    {
      id: "service:container-env",
      label: "Container Apps\nEnvironment",
      type: "compute",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Browser agents",
      details: {
        "Solution component": "browser:environment",
        Purpose: "Hosts browser automation jobs",
        "Why it matters": "Provides runtime isolation, scaling boundary, and Log Analytics integration."
      }
    },
    {
      id: "service:container-jobs",
      label: "Container Apps\nJobs",
      type: "compute",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Browser agents",
      details: {
        "Solution component": "browser:jobs",
        Purpose: "Runs scheduled browser scenarios",
        "Why it matters": "Turns Playwright tests into repeatable agent-like activity."
      }
    },
    {
      id: "service:browser-identity",
      label: "Browser Job\nManaged Identity",
      type: "identity",
      layer: "Browser agents",
      details: {
        "Solution component": "browser:identity",
        Purpose: "Authorizes browser jobs to read secrets and write telemetry",
        "Why it matters": "Avoids embedding service credentials in container images or scripts."
      }
    },
    {
      id: "service:loganalytics",
      label: "Log Analytics\nJob logs",
      type: "monitoring",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Observability",
      details: {
        "Solution component": "browser:loganalytics",
        Purpose: "Captures operational logs from browser jobs",
        "Why it matters": "Helps troubleshoot container startup, image pulls, and runtime failures."
      }
    },
    {
      id: "service:keyvault",
      label: "Azure\nKey Vault",
      type: "security",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Secrets",
      details: {
        Purpose: "Stores agent, user, app, and ingestion secrets",
        "Why it matters": "Secrets stay out of scripts, browser code, config files, and screenshots.",
        "Demo point": "Show the difference between retrieving a secret at runtime and embedding it in code."
      }
    },
    {
      id: "service:openai",
      label: "Azure OpenAI\nContent generation",
      type: "ai",
      serviceKey: "azure.ai.foundry",
      image: journeyNodeImage("service", "azure.ai.foundry", "Azure AI Foundry"),
      layer: "AI",
      details: {
        "Solution component": "oai:oai-claudia-lab",
        Purpose: "Generates realistic prompt, email, document, and scenario content",
        "Why it matters": "The demo shows agents producing useful business context rather than fixed canned samples."
      }
    },
    {
      id: "service:playwright",
      label: "Playwright Workspace\nRegional",
      type: "paas",
      serviceKey: "edge",
      image: journeyNodeImage("service", "edge", "Edge"),
      layer: "Browser automation",
      details: {
        "Solution component": "browser:playwright-americas / europe / asia",
        Purpose: "Runs isolated browser automation",
        "Why it matters": "Some demos require real UI behavior, not only API calls.",
        "Demo point": "Use it to show login, browser state, uploads, sharing dialogs, and web-only paths."
      }
    },
    {
      id: "service:storyline",
      label: "Storyline\nscenario",
      type: "definition",
      layer: "Scenario",
      details: {
        "Solution component": "defs:agents + Storyline content",
        Purpose: "Chooses prompt, file, recipient, and business context",
        "Why it matters": "Turns technical events into a story the audience can follow."
      }
    },
    {
      id: "service:edge",
      label: "Microsoft\nEdge",
      type: "service",
      serviceKey: "edge",
      image: journeyNodeImage("service", "edge", "Edge"),
      layer: "Browser",
      details: {
        Purpose: "Interactive surface used by the browser agent",
        "Demo point": "The presenter can explain what the agent is doing while the UI changes."
      }
    },
    {
      id: "activity:user-secret",
      label: "Simulated user\ncredentials",
      type: "identity",
      layer: "Identity",
      details: {
        Purpose: "Credential used to emulate a business user",
        "Why it matters": "Lets the lab generate attributable user activity without using real employee accounts."
      }
    },
    {
      id: "service:office",
      label: "Microsoft 365\nOffice Web",
      type: "service",
      serviceKey: "office",
      image: journeyNodeImage("service", scenario.serviceKey, scenario.targetLabel),
      layer: "M365",
      details: {
        Workload: scenario.targetLabel,
        "Why it matters": "This is where agent behavior becomes Microsoft 365 user activity."
      }
    },
    {
      id: "activity:action",
      label: scenario.actionLabel,
      type: "activity",
      serviceKey: scenario.serviceKey,
      image: journeyNodeImage("service", scenario.serviceKey, scenario.targetLabel),
      layer: "User action",
      details: {
        Scenario: scenario.title,
        Outcome: scenario.outcome,
        "Presenter cue": "Pause here to connect the technical components to the business activity."
      }
    },
    {
      id: "service:storage",
      label: "Static Website\nStorage",
      type: "storage",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Portal",
      details: {
        "Solution component": "storage:web",
        Purpose: "Hosts static website files, assets, counters, and lightweight state",
        "Why it matters": "Separates cheap static delivery from backend query logic."
      }
    },
    {
      id: "service:assets",
      label: "Images and Branding\nassets",
      type: "asset",
      layer: "Content",
      details: {
        "Solution component": "assets:images",
        Purpose: "Provides character images, service icons, and branding",
        "Why it matters": "Visual context helps beginners understand the architecture faster."
      }
    },
    {
      id: "service:edgefront",
      label: "Azure Front Door\nedge route",
      type: "edge",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Portal",
      details: {
        "Solution component": "afd:profile",
        Purpose: "Publishes the educational portal through an edge endpoint",
        "Why it matters": "Adds a clean public route in front of the storage origin."
      }
    },
    {
      id: "service:api",
      label: "Function API\n/api/graph",
      type: "api",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "API",
      details: {
        "Solution component": "func:story",
        Purpose: "Queries ADX and returns graph-shaped data to the portal",
        "Why it matters": "The browser never needs direct access to the telemetry backend."
      }
    },
    {
      id: "service:function-storage",
      label: "Function Storage\nruntime",
      type: "storage",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Portal",
      details: {
        "Solution component": "storage:function",
        Purpose: "Stores Azure Functions runtime data and lightweight portal state",
        "Why it matters": "Keeps function runtime dependencies separate from static website hosting."
      }
    },
    {
      id: "service:appinsights",
      label: "Application Insights\nAPI diagnostics",
      type: "monitoring",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Observability",
      details: {
        "Solution component": "ai:appinsights",
        Purpose: "Tracks Function API diagnostics",
        "Why it matters": "Separates portal/API health from agent activity telemetry."
      }
    },
    {
      id: "service:adx",
      label: "Azure Data Explorer\nTelemetry",
      type: "data",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Observability",
      details: {
        "Solution component": "adx:cluster",
        Purpose: "Stores normalized agent activity in queryable tables",
        "Demo point": "Use ADX to explain KQL, ingestion mapping, retention, and fast investigation."
      }
    },
    {
      id: "service:adx-table",
      label: "ADX Table\nCLAUDIA_Activity",
      type: "data",
      serviceKey: "azure",
      image: journeyNodeImage("service", "azure", "Azure"),
      layer: "Observability",
      details: {
        "Solution component": "adx:table",
        Purpose: "Stores the normalized Event payload consumed by the portal",
        "Why it matters": "A stable schema lets the portal build graphs, filters, and timelines."
      }
    },
    {
      id: "service:workbook",
      label: "ADX Workbook\nValidation",
      type: "monitoring",
      layer: "Observability",
      details: {
        "Solution component": "workbook:activity",
        Purpose: "Validates telemetry counts, recent activity, and ingestion health",
        "Why it matters": "Gives operators a second view when the portal data looks surprising."
      }
    },
    {
      id: "service:purview",
      label: "Purview + ADX\nTelemetry",
      type: "security",
      serviceKey: "microsoft.purview",
      image: journeyNodeImage("service", "microsoft.purview", "Purview"),
      layer: "Monitoring",
      details: {
        Purpose: "Adds audit, DLP, sensitivity, and governance context",
        "Why it matters": "Connects the agent architecture to security and compliance outcomes."
      }
    }
  ];
  const path = scenario.steps.map((step) => step.node);
  const edgeLabels = {
    "service:tenant|service:entra": "identity plane",
    "service:tenant|service:subscription": "hosts",
    "service:subscription|service:resource-group": "contains",
    "service:resource-group|service:entra": "uses identity",
    "service:resource-group|service:automation": "contains",
    "service:resource-group|service:storage": "contains",
    "service:entra|service:licenses": "assigns",
    "service:licenses|activity:schedule": "enables",
    "activity:schedule|activity:runbook": "starts",
    "activity:schedule|service:automation": "triggers",
    "service:automation|activity:runbook": "executes",
    "activity:runbook|service:rbac": "uses identity",
    "activity:runbook|agent": "selects",
    "service:rbac|service:keyvault": "authorizes",
    "service:rbac|service:adx": "allows query",
    "service:keyvault|activity:user-secret": "returns secret",
    "activity:user-secret|service:playwright": "feeds session",
    "service:keyvault|service:storyline": "unlocks context",
    "service:storyline|service:openai": "requests content",
    "service:openai|service:office": "generates context",
    "service:openai|activity:runbook": "generates content",
    "service:keyvault|service:playwright": "provides auth",
    "service:storyline|service:playwright": "guides",
    "service:storyline|service:edge": "opens path",
    "service:storyline|service:office": "selects workload",
    "service:playwright|service:edge": "launches",
    "service:edge|service:office": "signs in",
    "service:office|activity:action": "performs",
    "service:keyvault|service:playwright": "provides auth",
    "activity:action|service:storage": "stores output",
    "activity:action|service:adx": "emits telemetry",
    "activity:action|service:purview": "audits",
    "service:purview|service:adx": "enriches",
    "service:adx|service:adx-table": "stores events",
    "service:adx-table|service:purview": "supports review",
    "service:adx-table|service:api": "serves graph",
    "service:adx-table|service:workbook": "validates",
    "service:workbook|service:api": "cross-checks",
    "service:adx|service:api": "serves query",
    "service:api|service:storage": "supports portal",
    "service:storage|service:assets": "serves",
    "service:assets|service:edgefront": "published by",
    "service:storage|service:edgefront": "origin",
    "service:edgefront|service:api": "calls",
    "service:api|service:function-storage": "runtime state",
    "service:api|service:rbac": "uses identity",
    "service:rbac|service:adx": "allows query",
    "service:adx|service:storage": "feeds portal",
    "service:adx|service:adx-table": "contains",
    "service:adx-table|service:appinsights": "diagnostics separate",
    "service:function-storage|service:rbac": "supports",
    "service:adx-table|service:storyline": "contextualized by",
    "service:storage|service:storyline": "serves assets",
    "service:storyline|activity:action": "educates",
    "service:purview|activity:action": "contextualizes",
    "activity:runbook|service:playwright": "starts",
    "activity:runbook|service:container-jobs": "parallels",
    "service:browser-platform|service:acr": "uses image",
    "service:acr|service:container-env": "deploys into",
    "service:container-env|service:container-jobs": "hosts",
    "service:container-jobs|service:browser-identity": "runs as",
    "service:browser-identity|service:keyvault": "reads secrets",
    "service:container-jobs|service:keyvault": "reads secret",
    "service:container-jobs|service:playwright": "uses workspace",
    "activity:schedule|service:browser-platform": "selects",
    "activity:schedule|activity:runbook": "starts",
    "service:container-jobs|service:purview": "creates signals",
    "activity:action|service:loganalytics": "writes logs",
    "service:loganalytics|service:adx": "troubleshoots",
    "service:playwright|service:purview": "creates signals",
    "service:purview|service:api": "summarizes",
    "service:api|activity:action": "filters"
  };
  const pathNodes = new Set(path);
  const visibleNodes = nodes
    .filter((node) => pathNodes.has(node.id))
    .map((node) => ({ ...node }));
  const visibleNodeIds = new Set(visibleNodes.map((node) => node.id));
  const edges = path.slice(0, -1)
    .filter((source, index) => visibleNodeIds.has(source) && visibleNodeIds.has(path[index + 1]))
    .map((source, index) => ({
      id: `journey-edge-${index}`,
      source,
      target: path[index + 1],
      label: edgeLabels[`${source}|${path[index + 1]}`] ||
        edgeLabels[`${source}|agent`] ||
        "connects",
      stepIndex: index + 1
    }));
  applyJourneyPositions(visibleNodes, path);
  return {
    scenario,
    agent,
    nodes: visibleNodes,
    edges,
    steps: scenario.steps.map((step, index) => ({
      ...step,
      index,
      agent,
      scenario
    }))
  };
}

function applyJourneyPositions(nodes, path) {
  const nodeById = new Map(nodes.map((node) => [node.id, node]));
  const columns = 4;
  const columnGap = 260;
  const rowGap = 135;
  const originX = 140;
  const originY = 80;
  path.forEach((nodeId, index) => {
    const node = nodeById.get(nodeId);
    if (!node) return;
    const row = Math.floor(index / columns);
    const offset = index % columns;
    const col = row % 2 === 0 ? offset : columns - 1 - offset;
    node.position = {
      x: originX + col * columnGap,
      y: originY + row * rowGap
    };
  });
}

function fitJourneyView() {
  if (!cy) return;
  cy.fit(cy.elements(), 88);
  cy.panBy({ x: 0, y: -70 });
}

function journeyNarrativeText(graph, step) {
  if (!step) return {};
  const node = (graph.nodes || []).find((item) => item.id === step.node) || {};
  const details = node.details || {};
  const previous = graph.steps[step.index - 1];
  const edge = step.index > 0 ? graph.edges[step.index - 1] : null;
  const previousLabel = previous ? previous.label : "The journey";
  const connection = previous
    ? `${previousLabel} connects to this step through "${edge ? edge.label : "connects"}".`
    : `This is the starting point for "${graph.scenario.title}".`;
  const why = details["Why it matters"] || details["Demo point"] || details.Purpose || step.detail;
  const teachingCue = step.node === "service:keyvault"
    ? "Through the agent service principal or managed identity, RBAC with a role such as Key Vault Secrets User allows the flow to request only the credential it needs."
    : step.node === "service:rbac"
    ? "This is where the presenter can explain that RBAC decides which identity can read, query, or execute, instead of giving the agent broad default permissions."
    : step.node === "activity:user-secret"
    ? "The secret maps to the simulated user. The presenter does not need to see or copy the password; the flow consumes it in a controlled way."
    : step.node === "service:playwright"
    ? "Playwright receives the authorized context and runs the browser interaction without becoming the place where secrets live."
    : step.node === "service:adx"
    ? "ADX turns agent activity into queryable evidence: what happened, who acted, which workload was touched, and how the demo can prove it."
    : "Use this point to connect the technical component with the learning objective of the demo.";
  return { connection, why, teachingCue };
}

function renderJourneyNarrative(graph) {
  if (!journeyNarrativeEl) return;
  const step = graph.steps[journeyStepIndex];
  if (!step) {
    journeyNarrativeEl.hidden = true;
    return;
  }
  const node = (graph.nodes || []).find((item) => item.id === step.node) || {};
  const narrative = journeyNarrativeText(graph, step);
  journeyNarrativeEl.innerHTML = `
    <span>Step ${step.index + 1} of ${graph.steps.length}</span>
    <h2>${escapeHtml(step.label)}</h2>
    <p>${escapeHtml(narrative.connection)}</p>
    <p>${escapeHtml(narrative.teachingCue)}</p>
    <dl>
      <dt>Component</dt>
      <dd>${escapeHtml(String(node.label || step.node).replace(/\n/g, " - "))}</dd>
      <dt>Why it matters</dt>
      <dd>${escapeHtml(narrative.why)}</dd>
    </dl>
  `;
  journeyNarrativeEl.hidden = false;
}

function hideJourneyNarrative() {
  if (journeyNarrativeEl) journeyNarrativeEl.hidden = true;
}

function hideComponentCatalog() {
  if (componentCatalogSectionEl) componentCatalogSectionEl.hidden = true;
}

const componentPermissionHints = {
  "tenant:contoso.example": "Global Reader or appropriate tenant admin role to inspect; workload admin roles to configure services.",
  "subscription:karla": "Reader to inspect; Contributor or Owner/User Access Administrator to deploy and assign Azure RBAC.",
  "rg:claudia-lab": "Reader for visibility; Contributor for resource lifecycle; User Access Administrator for role assignments.",
  "aa:aa-claudia-lab": "Automation Contributor to manage; managed identity needs scoped access to Key Vault, ADX, and target services.",
  "runbook:invoke-agent": "Automation Runbook Operator to run; Automation Contributor to edit; managed identity permissions for downstream services.",
  "kv:kv-claudia-lab": "Key Vault Secrets User for runtime reads; Key Vault Administrator or Secrets Officer to manage secrets.",
  "oai:oai-claudia-lab": "Cognitive Services OpenAI User to call deployments; Contributor to manage model deployments.",
  "adx:cluster": "ADX Database Viewer for queries; Ingestor for writes; Admin for schema and retention.",
  "adx:table": "Database Viewer to read; Table Ingestor or database ingestion permissions to write normalized events.",
  "workbook:activity": "Workbook Reader plus ADX query access to view; Workbook Contributor to edit.",
  "func:story": "Function App Contributor to manage; managed identity needs ADX query access and storage access.",
  "ai:appinsights": "Monitoring Reader to inspect telemetry; Application Insights Component Contributor to configure.",
  "storage:web": "Storage Blob Data Contributor to publish; public/static website access for readers through Front Door.",
  "storage:function": "Storage Account Contributor for management; Storage Blob/Queue/Table Data roles for runtime as needed.",
  "afd:profile": "Front Door Contributor to manage routes, origin, and cache purge.",
  "m365:entra": "User Administrator or Global Reader to inspect users; workload-specific admin roles for service changes.",
  "m365:licenses": "License Administrator to assign licenses; Global Reader to inspect assignments.",
  "m365:sharepoint": "SharePoint Administrator or site permissions; delegated user access for simulated activity.",
  "m365:onedrive": "SharePoint/OneDrive admin or user delegated access to files and sharing.",
  "m365:exchange": "Exchange Administrator for configuration; mailbox permissions or delegated user sign-in for activity.",
  "m365:teams": "Teams Administrator for configuration; delegated user access for chats, channels, and meetings.",
  "m365:lists": "SharePoint/List permissions on the target site or list.",
  "m365:copilot": "Assigned Copilot license and Microsoft 365 workload permissions for the user.",
  "m365:fabric": "Fabric capacity/workspace permissions and workload license as required.",
  "defs:agents": "Repository or storage write access to update personas and scenario definitions.",
  "assets:images": "Storage Blob Data Contributor to publish images, service icons, and branding.",
  "browser:platform": "Contributor on the browser automation resource group resources.",
  "browser:acr": "AcrPull for jobs; AcrPush or Contributor for image publishing.",
  "browser:identity": "Managed Identity Operator to assign; scoped Key Vault, ADX, and ACR roles for runtime.",
  "browser:loganalytics": "Log Analytics Reader for logs; Contributor to configure workspace settings.",
  "browser:environment": "Container Apps Contributor to manage the environment.",
  "browser:jobs": "Container Apps Jobs Contributor to create and run jobs; managed identity roles for dependencies.",
  "browser:playwright-americas": "Playwright workspace access plus Key Vault-provided user credentials for browser sign-in.",
  "browser:playwright-europe": "Playwright workspace access plus Key Vault-provided user credentials for browser sign-in.",
  "browser:playwright-asia": "Playwright workspace access plus Key Vault-provided user credentials for browser sign-in."
};

function componentScopeMatches(node, scope) {
  if (!node) return false;
  if (scope === "all") return !isCharacterNode(node);
  const id = String(node.id || "");
  const layer = String(node.layer || "").toLowerCase();
  const type = String(node.type || "").toLowerCase();
  if (scope === "azure") return id.startsWith("subscription:") || id.startsWith("rg:") || ["paas", "security", "ai", "data", "api", "web", "storage", "edge", "monitoring", "compute", "identity", "resourcegroup", "subscription"].includes(type);
  if (scope === "portal") return ["storage:web", "storage:function", "func:story", "afd:profile", "assets:images", "ai:appinsights"].includes(id);
  if (scope === "automation") return id.startsWith("aa:") || id.startsWith("runbook:") || id.startsWith("browser:") || id === "defs:agents" || id === "kv:kv-claudia-lab" || id === "oai:oai-claudia-lab";
  if (scope === "m365") return id.startsWith("m365:") || layer === "saas";
  if (scope === "observability") return ["adx:cluster", "adx:table", "workbook:activity", "ai:appinsights", "browser:loganalytics"].includes(id) || layer.includes("telemetry") || layer.includes("observability");
  return true;
}

function selectedComponentNodeIds(payload) {
  const scope = componentScopeSelect ? componentScopeSelect.value : "all";
  const ids = new Set((payload.nodes || [])
    .filter((node) => componentScopeMatches(node, scope))
    .map((node) => node.id));
  if (scope !== "m365") {
    ids.add("tenant:contoso.example");
    ids.add("subscription:karla");
    ids.add("rg:claudia-lab");
  }
  return ids;
}

function componentLearningInfo(node, payload) {
  const incoming = (payload.edges || []).filter((edge) => edge.target === node.id);
  const outgoing = (payload.edges || []).filter((edge) => edge.source === node.id);
  const nodeMap = solutionNodesById(payload);
  const usedBy = incoming
    .map((edge) => nodeMap.get(edge.source))
    .filter(Boolean)
    .map((source) => String(source.label || source.id).replace(/\n/g, " - "));
  const providesTo = outgoing
    .map((edge) => nodeMap.get(edge.target))
    .filter(Boolean)
    .map((target) => String(target.label || target.id).replace(/\n/g, " - "));
  const details = node.details || {};
  const use = details.Purpose || details["Why it matters"] || details.Description || `${node.layer || "Solution"} component used by the autonomous agent environment.`;
  return {
    name: String(node.label || node.id).replace(/\n/g, " - "),
    use,
    usedBy: usedBy.length ? usedBy.join(" | ") : providesTo.length ? `Provides to ${providesTo.join(" | ")}` : "Referenced by the solution map.",
    permissions: componentPermissionHints[node.id] || "Use least-privilege Azure RBAC, Microsoft Entra role, or workload permissions appropriate to the operation."
  };
}

function renderComponentCatalog(payload, graph) {
  if (!componentCatalogSectionEl || !componentCatalogTable) return;
  const tbody = componentCatalogTable.querySelector("tbody");
  if (!tbody) return;
  const nodes = (graph.nodes || [])
    .filter((node) => !isCharacterNode(node))
    .sort((a, b) => String(a.layer || "").localeCompare(String(b.layer || "")) || String(a.label || "").localeCompare(String(b.label || "")));
  tbody.innerHTML = nodes.map((node) => {
    const info = componentLearningInfo(node, payload);
    return `
      <tr>
        <td>${escapeHtml(info.name)}</td>
        <td>${escapeHtml(info.use)}</td>
        <td>${escapeHtml(info.usedBy)}</td>
        <td>${escapeHtml(info.permissions)}</td>
      </tr>
    `;
  }).join("");
  if (componentCatalogSummary) {
    const scopeText = componentScopeSelect ? componentScopeSelect.options[componentScopeSelect.selectedIndex].textContent : "All components";
    componentCatalogSummary.textContent = `${scopeText}: ${nodes.length} components explained from resource group, front end, automation, telemetry, and Microsoft 365 dependencies.`;
  }
  componentCatalogSectionEl.hidden = false;
}

function renderJourneyTimeline(graph) {
  storyTitleEl.textContent = "Learning journey";
  timelineEl.innerHTML = "";
  graph.steps.forEach((step, index) => {
    const item = document.createElement("li");
    item.className = index === journeyStepIndex ? "journey-step-active" : "";
    const time = document.createElement("time");
    time.textContent = `Step ${index + 1}`;
    const title = document.createElement("strong");
    title.textContent = step.label;
    const meta = document.createElement("small");
    meta.textContent = step.detail;
    item.append(time, title, meta);
    timelineEl.appendChild(item);
  });
}

function renderJourneyComponentTable(graph) {
  if (!journeyComponentSectionEl || !journeyComponentTable) return;
  const tbody = journeyComponentTable.querySelector("tbody");
  if (!tbody) return;
  const nodesById = new Map((graph.nodes || []).map((node) => [node.id, node]));
  const seen = new Set();
  const rows = [];
  graph.steps.forEach((step) => {
    if (seen.has(step.node)) return;
    seen.add(step.node);
    const node = nodesById.get(step.node);
    if (!node) return;
    const details = node.details || {};
    const componentName = String(node.label || node.id).replace(/\n/g, " - ");
    const solutionComponent = details["Solution component"] ? ` (${details["Solution component"]})` : "";
    rows.push({
      component: `${componentName}${solutionComponent}`,
      role: step.label,
      relevance: details["Why it matters"] || details["Demo point"] || details.Purpose || step.detail
    });
  });
  tbody.innerHTML = rows.map((row) => `
    <tr>
      <td>${escapeHtml(row.component)}</td>
      <td>${escapeHtml(row.role)}</td>
      <td>${escapeHtml(row.relevance)}</td>
    </tr>
  `).join("");
  if (journeyComponentSummary) journeyComponentSummary.textContent = graph.scenario.outcome;
  journeyComponentSectionEl.hidden = false;
}

function hideJourneyComponentTable() {
  if (journeyComponentSectionEl) journeyComponentSectionEl.hidden = true;
}

function applyJourneyStep(graph) {
  if (!cy) return;
  cy.elements().removeClass("journey-active journey-complete");
  graph.steps.slice(0, journeyStepIndex).forEach((step, index) => {
    cy.getElementById(step.node).addClass("journey-complete");
    cy.getElementById(`journey-edge-${index}`).addClass("journey-complete");
  });
  const active = graph.steps[journeyStepIndex];
  if (active) cy.getElementById(active.node).addClass("journey-active");
  if (journeyStepIndex > 0) cy.getElementById(`journey-edge-${journeyStepIndex - 1}`).addClass("journey-active");
  renderJourneyTimeline(graph);
  renderJourneyComponentTable(graph);
  renderJourneyNarrative(graph);
  statusEl.textContent = `${graph.scenario.title}: step ${Math.min(journeyStepIndex + 1, graph.steps.length)} of ${graph.steps.length}`;
}

function stopJourneyAnimation() {
  if (journeyTimer) {
    clearInterval(journeyTimer);
    journeyTimer = null;
  }
}

function startJourneyAnimation({ restart = true } = {}) {
  stopJourneyAnimation();
  const graph = buildJourneyGraph();
  if (restart) journeyStepIndex = 0;
  applyJourneyStep(graph);
  journeyTimer = setInterval(() => {
    journeyStepIndex = (journeyStepIndex + 1) % graph.steps.length;
    applyJourneyStep(graph);
  }, Number(journeySpeedSelect.value || 1100));
}

function renderJourneyDetails(data) {
  detailsEl.hidden = false;
  const rows = Object.entries({
    Layer: data.layer,
    Type: data.type,
    ...(data.details || {})
  })
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .map(([key, value]) => `<dt>${escapeHtml(key)}</dt><dd>${escapeHtml(value)}</dd>`)
    .join("");
  detailsEl.innerHTML = `<h3>${escapeHtml(String(data.label || data.id || "Journey step").replace(/\n/g, " - "))}</h3><dl>${rows}</dl>`;
}

function renderTimeline(events) {
  timelineEl.innerHTML = "";
  events.slice(-80).reverse().forEach((event) => {
    const item = document.createElement("li");
    const time = document.createElement("time");
    time.textContent = new Date(event.TimeGenerated).toLocaleString();
    const title = document.createElement("strong");
    title.textContent = eventTitle(event);
    const meta = document.createElement("small");
    meta.textContent = activityName(event);
    item.append(time, title, meta);
    timelineEl.appendChild(item);
  });
}

function renderDetails(data) {
  if (activeMode === "journey") {
    renderJourneyDetails(data);
    return;
  }
  const profile = data.type === "user" ? getCharacterProfile(data.id) : null;
  if (profile) {
    renderCharacterProfile(profile);
    return;
  }
  if (activeMode !== "activity" && solutionPayload && data.id) {
    renderSolutionDetails(data);
    return;
  }
  detailsEl.hidden = false;
  const title = data.events
    ? `${data.rawLabel || data.label} - ${data.count} activities`
    : (data.label || data.TargetName || data.Subject || data.AgentName || "Activity");
  const sourceRows = data.details
    ? { Layer: data.layer, Type: data.type, ...data.details }
    : data.events
    ? {
        Count: data.count,
        First: new Date(data.firstSeen).toLocaleString(),
        Last: new Date(data.lastSeen).toLocaleString(),
        Source: data.source,
        Target: data.target,
        Recent: data.events.slice(-8).reverse().map(eventTitle).join(" | ")
      }
    : data;
  const rows = Object.entries(sourceRows || {})
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .slice(0, 18)
    .map(([key, value]) => `<dt>${escapeHtml(key)}</dt><dd>${escapeHtml(value)}</dd>`)
    .join("");
  detailsEl.innerHTML = `<h3>${escapeHtml(title)}</h3><dl>${rows}</dl>`;
}

function renderSolutionDetails(data) {
  detailsEl.hidden = false;
  const title = String(data.label || data.id || "Component").replace(/\n/g, " - ");
  const incoming = (solutionPayload.edges || []).filter((edge) => edge.target === data.id);
  const outgoing = (solutionPayload.edges || []).filter((edge) => edge.source === data.id);
  const nodeMap = solutionNodesById(solutionPayload);
  const dependencyRows = [
    ...incoming.map((edge) => ({ direction: "Depends on", label: edge.label, node: nodeMap.get(edge.source) })),
    ...outgoing.map((edge) => ({ direction: "Provides to", label: edge.label, node: nodeMap.get(edge.target) }))
  ];
  const sourceRows = {
    Layer: data.layer,
    Type: data.type,
    ...(data.details || {}),
    "Visible dependencies": dependencyRows.length || "None"
  };
  const rows = Object.entries(sourceRows)
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .map(([key, value]) => `<dt>${escapeHtml(key)}</dt><dd>${escapeHtml(value)}</dd>`)
    .join("");
  const dependencies = dependencyRows.length
    ? `<section><h4>Dependencies</h4><ul>${dependencyRows.map((item) => {
        const name = item.node ? String(item.node.label || item.node.id).replace(/\n/g, " - ") : "Unknown component";
        return `<li><strong>${escapeHtml(item.direction)}:</strong> ${escapeHtml(name)}<span>${escapeHtml(item.label || "")}</span></li>`;
      }).join("")}</ul></section>`
    : `<section><h4>Dependencies</h4><p class="profile-intro">No visible dependencies in the current solution map.</p></section>`;
  detailsEl.innerHTML = `<h3>${escapeHtml(title)}</h3><dl>${rows}</dl>${dependencies}`;
}

function renderList(title, values) {
  const items = (values || []).filter(Boolean);
  if (items.length === 0) return "";
  return `<section><h4>${escapeHtml(title)}</h4><ul>${items.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul></section>`;
}

function renderPeople(title, people) {
  const items = (people || []).filter((person) => person && (person.displayName || person.upn));
  if (items.length === 0) return "";
  return `<section><h4>${escapeHtml(title)}</h4><ul>${items.map((person) => {
    const role = [person.jobTitle, person.department].filter(Boolean).join(" | ");
    return `<li><strong>${escapeHtml(person.displayName || person.upn)}</strong>${role ? `<span>${escapeHtml(role)}</span>` : ""}</li>`;
  }).join("")}</ul></section>`;
}

function profileServiceUsage() {
  const usage = new Map();
  const register = (name, source) => {
    const key = serviceKey(name);
    if (!key) return;
    const current = usage.get(key) || { key, label: name, count: 0, people: new Set() };
    current.count += 1;
    if (source) current.people.add(source);
    usage.set(key, current);
  };

  (characterProfiles.profiles || []).forEach((profile) => {
    (profile.technologies || []).forEach((technology) => register(technology, profile.displayName));
  });

  return [...usage.values()]
    .filter((item) => item.count > 0)
    .sort((a, b) => b.people.size - a.people.size || a.label.localeCompare(b.label));
}

function appendServiceBubbles() {
  const usage = profileServiceUsage();
  if (usage.length === 0) return;
  const max = Math.max(...usage.map((item) => item.people.size || item.count));
  const item = document.createElement("li");
  item.className = "service-usage";
  const title = document.createElement("strong");
  title.textContent = "Service usage";
  const body = document.createElement("div");
  body.className = "service-bubbles";
  usage.slice(0, 10).forEach((service) => {
    const size = 34 + Math.round(((service.people.size || service.count) / max) * 26);
    const bubble = document.createElement("button");
    bubble.type = "button";
    bubble.className = "service-bubble";
    bubble.style.width = `${size}px`;
    bubble.style.height = `${size}px`;
    bubble.title = `${service.label}: ${service.people.size} character(s)`;
    const image = assetMap.services[service.key] || "";
    if (image) {
      const img = document.createElement("img");
      img.src = image;
      img.alt = "";
      bubble.appendChild(img);
    } else {
      bubble.textContent = service.label.slice(0, 2).toUpperCase();
    }
    body.appendChild(bubble);
  });
  const caption = document.createElement("small");
  caption.textContent = "Based on character profile technologies; separated from the organization graph.";
  item.append(title, body, caption);
  timelineEl.appendChild(item);
}

function renderCharacterProfile(profile) {
  detailsEl.hidden = false;
  const manager = profile.entra && profile.entra.manager ? [profile.entra.manager] : [];
  const directReports = profile.entra ? profile.entra.directReports : [];
  const image = assetMap.characters[profile.key] || "";
  detailsEl.innerHTML = `
    <div class="profile-card">
      ${image ? `<img src="${escapeHtml(image)}" alt="">` : ""}
      <div>
        <h3>${escapeHtml(profile.displayName)}</h3>
        <p>${escapeHtml(profile.tagline || "")}</p>
      </div>
    </div>
    <dl>
      <dt>UPN</dt><dd>${escapeHtml(profile.upn || "")}</dd>
      <dt>Role</dt><dd>${escapeHtml(profile.role || "")}</dd>
      <dt>Department</dt><dd>${escapeHtml(profile.department || "")}</dd>
      <dt>Location</dt><dd>${escapeHtml(profile.location || "")}</dd>
      <dt>Assigned licenses</dt><dd>${escapeHtml(profile.licenses || "")}</dd>
      ${profile.highlights && profile.highlights.length ? `<dt>Highlights</dt><dd>${escapeHtml(profile.highlights.join(" | "))}</dd>` : ""}
      <dt>Identity status</dt><dd>${profile.entra && profile.entra.exists ? "Microsoft Entra user found" : "Not found yet"}</dd>
    </dl>
    <p class="profile-intro">${escapeHtml(profile.introduction || "")}</p>
    ${renderPeople("Manager", manager)}
    ${renderPeople("Direct reports", directReports)}
    ${renderList("Personality", profile.personality)}
    ${renderList("Daily activities", profile.dailyActivities)}
    ${renderList("Technologies", profile.technologies)}
    ${renderList("Sensitive data exposure", profile.sensitiveDataExposure)}
    ${renderList("Areas of expertise", profile.areasOfExpertise)}
    ${renderList("Demo focus", profile.demoFocus)}
    ${renderList("Community & leadership", profile.communityLeadership)}
    ${profile.personalMotto ? `<section><h4>Personal motto</h4><p class="profile-intro">${escapeHtml(profile.personalMotto)}</p></section>` : ""}
  `;
}

function solutionNodeImage(node) {
  if (node.image) return node.image;
  if (node.type === "user") {
    const name = String(node.label || "").split("\n")[0];
    return assetMap.characters[node.id] || assetMap.characters[slug(node.id.replace(/^agent:/, ""))] || assetMap.characters[slug(name)] || "";
  }
  if (node.type === "service") {
    return assetMap.services[node.serviceKey] || assetMap.services[serviceKey(node.label)] || "";
  }
  return "";
}

function solutionNodesById(payload) {
  return new Map((payload.nodes || []).map((node) => [node.id, node]));
}

function isCharacterNode(node) {
  return node.type === "user" && String(node.id || "").startsWith("agent:");
}

function connectedNodeIds(payload, seedIds) {
  const ids = new Set(seedIds);
  (payload.edges || []).forEach((edge) => {
    if (ids.has(edge.source)) ids.add(edge.target);
    if (ids.has(edge.target)) ids.add(edge.source);
  });
  return ids;
}

function selectedSolutionNodeIds(payload) {
  const nodes = payload.nodes || [];
  const profileIds = (characterProfiles.profiles || []).map((profile) => profile.id);
  if (activeMode === "components") return selectedComponentNodeIds(payload);
  const characterId = solutionCharacterSelect.value;
  if (characterId === "__orgchart") {
    const orgIds = new Set(profileIds);
    (characterProfiles.profiles || []).forEach((profile) => {
      if (profile.entra && profile.entra.manager) orgIds.add(profile.entra.manager.id);
      (profile.entra && profile.entra.directReports || []).forEach((person) => orgIds.add(person.id));
    });
    return orgIds;
  }
  if (characterId) {
    const directIds = activeMode === "characters"
      ? new Set([characterId])
      : new Set([characterId, "defs:agents", "m365:entra", "m365:licenses"]);
    if (activeMode !== "characters") {
      (payload.edges || []).forEach((edge) => {
        if (edge.source === characterId) directIds.add(edge.target);
        if (edge.target === characterId) directIds.add(edge.source);
      });
    }
    const profile = getCharacterProfile(characterId);
    if (profile && profile.entra) {
      if (profile.entra.manager) directIds.add(profile.entra.manager.id);
      (profile.entra.directReports || []).forEach((person) => directIds.add(person.id));
    }
    return directIds;
  }

  if (activeMode === "characters") {
    const orgIds = new Set(profileIds);
    (characterProfiles.profiles || []).forEach((profile) => {
      if (profile.entra && profile.entra.manager) orgIds.add(profile.entra.manager.id);
      (profile.entra && profile.entra.directReports || []).forEach((person) => orgIds.add(person.id));
    });
    return orgIds;
  }

  switch (solutionScopeSelect.value) {
    case "full":
      return new Set(nodes.map((node) => node.id));
    case "characters":
      return new Set([...nodes
        .filter((node) => isCharacterNode(node) || ["defs:agents", "m365:entra", "m365:licenses"].includes(node.id) || node.type === "service")
        .map((node) => node.id), ...profileIds]);
    case "data":
      return connectedNodeIds(payload, ["runbook:invoke-agent", "adx:cluster", "adx:table", "func:story", "storage:web", "afd:profile"]);
    case "m365":
      return new Set([...nodes
        .filter((node) => ["tenant", "saas", "service", "license"].includes(node.type) || isCharacterNode(node))
        .map((node) => node.id), ...profileIds]);
    case "core":
    default:
      return new Set(nodes
        .filter((node) => !isCharacterNode(node))
        .map((node) => node.id));
  }
}

function buildSolutionGraph(payload) {
  const includedIds = selectedSolutionNodeIds(payload);
  const nodeMap = new Map((payload.nodes || []).map((node) => [node.id, node]));
  function ensurePersonNode(person) {
    if (!person || !person.id || nodeMap.has(person.id)) return;
    nodeMap.set(person.id, {
      id: person.id,
      label: `${person.displayName || person.upn}\n${person.department || person.jobTitle || "External relation"}`,
      type: "user",
      layer: "Organization",
      details: {
        UPN: person.upn,
        Department: person.department,
        "Job title": person.jobTitle,
        Copilot: "Unknown"
      }
    });
  }
  (characterProfiles.profiles || []).forEach((profile) => {
    if (!nodeMap.has(profile.id)) {
      nodeMap.set(profile.id, {
        id: profile.id,
        label: `${profile.displayName}\n${profile.department || "Character"}`,
        type: "user",
        layer: "Characters",
        details: {
          UPN: profile.upn,
          Department: profile.department,
          "Job title": profile.role,
          Copilot: (profile.licenses || "").toLowerCase().includes("copilot") ? "Yes" : "No"
        }
      });
    }
    if (profile.entra && profile.entra.manager) ensurePersonNode(profile.entra.manager);
    (profile.entra && profile.entra.directReports || []).forEach(ensurePersonNode);
  });
  const profileEdges = [];
  (characterProfiles.profiles || []).forEach((profile) => {
    profileEdges.push({
      source: "defs:agents",
      target: profile.id,
      label: "defines"
    });
    profileEdges.push({
      source: "m365:entra",
      target: profile.id,
      label: profile.entra && profile.entra.exists ? "user object" : "planned user"
    });
    if ((profile.licenses || "").toLowerCase().includes("copilot")) {
      profileEdges.push({
        source: "m365:licenses",
        target: profile.id,
        label: "Copilot licensed"
      });
    }
    if (profile.entra && profile.entra.manager) {
      profileEdges.push({
        source: profile.entra.manager.id,
        target: profile.id,
        label: "manages"
      });
    }
  });
  return {
    nodes: [...nodeMap.values()]
      .filter((node) => includedIds.has(node.id))
      .map((node) => ({
        ...node,
        color: node.color || nodeColor(node.type),
        image: solutionNodeImage(node)
      })),
    edges: [...(payload.edges || []), ...profileEdges]
      .filter((edge) => includedIds.has(edge.source) && includedIds.has(edge.target))
      .map((edge, index) => ({
        id: edge.id || `solution-edge-${index}`,
        ...edge
      }))
  };
}

function renderSolutionNotes(payload, graph) {
  if (activeMode === "components") {
    storyTitleEl.textContent = "Environment guide";
    timelineEl.innerHTML = "";
    [
      { title: "Start with the Resource Group", body: "Use the resource group as the container for explaining ownership, cost, RBAC, deployment, and cleanup." },
      { title: "Follow consumers and permissions", body: "Each row shows what the component does, who consumes it, and which permissions are normally required." },
      { title: "Include Microsoft 365", body: "Microsoft 365 services are part of the environment because agent activity becomes user activity in those workloads." }
    ].forEach((note) => {
      const item = document.createElement("li");
      const title = document.createElement("strong");
      title.textContent = note.title;
      const body = document.createElement("small");
      body.textContent = note.body;
      item.append(title, body);
      timelineEl.appendChild(item);
    });
    renderComponentCatalog(payload, graph);
    return;
  }
  const isOrgChart = activeMode === "characters" && solutionCharacterSelect.value === "__orgchart";
  storyTitleEl.textContent = isOrgChart ? "Organization" : activeMode === "characters" ? "Characters" : "Architecture";
  timelineEl.innerHTML = "";
  if (isOrgChart) {
    const relationships = (characterProfiles.profiles || [])
      .filter((profile) => profile.entra && profile.entra.manager)
      .sort((a, b) => a.displayName.localeCompare(b.displayName));
    relationships.forEach((profile) => {
      const item = document.createElement("li");
      const title = document.createElement("strong");
      title.textContent = profile.displayName;
      const body = document.createElement("small");
      body.textContent = `Reports to ${profile.entra.manager.displayName}`;
      item.append(title, body);
      timelineEl.appendChild(item);
    });
    return;
  }
  if (activeMode === "characters") {
    if (!solutionCharacterSelect.value) appendServiceBubbles();
    graph.nodes
      .filter(isCharacterNode)
      .sort((a, b) => a.label.localeCompare(b.label))
      .forEach((node) => {
        const profile = getCharacterProfile(node.id);
        const item = document.createElement("li");
        const title = document.createElement("strong");
        title.textContent = profile ? profile.displayName : String(node.label || "").split("\n")[0];
        const body = document.createElement("small");
        const details = profile ? {
          Department: profile.department,
          "Job title": profile.role,
          Copilot: (profile.licenses || "").toLowerCase().includes("copilot") ? "Yes" : "No"
        } : node.details || {};
        body.textContent = `${details.Department || "Department"} | ${details["Job title"] || "Role"} | Copilot: ${details.Copilot || "No"}`;
        item.addEventListener("click", () => {
          solutionCharacterSelect.value = node.id;
          renderGraph(solutionPayload);
          if (profile) renderCharacterProfile(profile);
        });
        item.append(title, body);
        timelineEl.appendChild(item);
      });
    return;
  }
  (payload.notes || []).forEach((note) => {
    const item = document.createElement("li");
    const title = document.createElement("strong");
    title.textContent = note.title;
    const body = document.createElement("small");
    body.textContent = note.body;
    item.append(title, body);
    timelineEl.appendChild(item);
  });
}

function layoutOptions(isSolution) {
  if (activeMode === "journey") {
    return {
      name: "preset",
      animate: false,
      padding: 90,
      avoidOverlap: true
    };
  }
  if (isSolution) {
    if (activeMode === "characters" && solutionCharacterSelect.value === "__orgchart") {
      return {
        name: "breadthfirst",
        directed: true,
        animate: false,
        padding: 70,
        spacingFactor: 1.6,
        avoidOverlap: true
      };
    }
    return {
      name: "breadthfirst",
      directed: true,
      animate: false,
      padding: 70,
      spacingFactor: 1.25,
      avoidOverlap: true
    };
  }
  return { name: "cose", animate: false, padding: 52, nodeRepulsion: 9000 };
}

function renderGraph(payload) {
  const isJourney = activeMode === "journey";
  const isSolution = activeMode === "solution" || activeMode === "characters" || activeMode === "components";
  const events = isSolution ? [] : filteredEvents(payload);
  const graph = isJourney
    ? buildJourneyGraph()
    : isSolution
    ? buildSolutionGraph(payload)
    : viewSelect.value === "detail" ? buildDetailGraph(events) : buildSummaryGraph(events);
  const elements = [
    ...graph.nodes.map((node) => ({
      data: node,
      position: node.position,
      classes: node.image ? `${node.type}-image` : ""
    })),
    ...graph.edges.map((edge) => ({ data: edge }))
  ];

  if (!cy) {
    cy = cytoscape({
      container: graphEl,
      elements,
      style: [
        {
          selector: "node",
          style: {
            "background-color": "data(color)",
            label: "data(label)",
            color: "#f2f4f6",
            "font-size": 11,
            "text-wrap": "wrap",
            "text-max-width": 110,
            "text-valign": "bottom",
            "text-margin-y": 8,
            width: 34,
            height: 34,
            "border-width": 1,
            "border-color": "#101214"
          }
        },
        {
          selector: "node[type = 'tenant'], node[type = 'subscription'], node[type = 'resourceGroup']",
          style: {
            shape: "round-rectangle",
            width: 178,
            height: 54,
            "font-size": 10,
            "text-valign": "center",
            "text-halign": "center",
            "text-margin-y": 0,
            "border-width": 2,
            "border-color": "#d3dae1"
          }
        },
        {
          selector: "node[type = 'paas'], node[type = 'saas'], node[type = 'security'], node[type = 'ai'], node[type = 'data'], node[type = 'api'], node[type = 'web'], node[type = 'storage'], node[type = 'edge'], node[type = 'process'], node[type = 'definition'], node[type = 'asset'], node[type = 'license'], node[type = 'monitoring'], node[type = 'compute'], node[type = 'identity']",
          style: {
            shape: "round-rectangle",
            width: 154,
            height: 50,
            "font-size": 10,
            "text-valign": "center",
            "text-halign": "center",
            "text-margin-y": 0,
            color: "#101214",
            "border-width": 1,
            "border-color": "#f2f4f6"
          }
        },
        {
          selector: "node.journey-active",
          style: {
            "border-width": 5,
            "border-color": "#f6c453",
            "background-color": "#f6c453",
            color: "#101214"
          }
        },
        {
          selector: "node.journey-complete",
          style: {
            "border-width": 3,
            "border-color": "#68d391"
          }
        },
        {
          selector: "node.user-image",
          style: {
            "background-image": "data(image)",
            "background-fit": "cover",
            "background-opacity": 1,
            width: 44,
            height: 44,
            "border-width": 2,
            "border-color": "#f2f4f6"
          }
        },
        {
          selector: "node.service-image",
          style: {
            shape: "ellipse",
            "background-color": "#171a1d",
            "background-image": "data(image)",
            "background-fit": "contain",
            "background-opacity": 1,
            width: 52,
            height: 52,
            "border-width": 1,
            "border-color": "#323941"
          }
        },
        {
          selector: "node[type = 'activity']",
          style: {
            shape: "round-rectangle",
            width: 150,
            height: 46,
            "background-color": "#202428",
            "font-size": 10,
            "text-valign": "center",
            "text-halign": "center",
            "text-margin-y": 0,
            color: "#f2f4f6",
            "border-width": 1,
            "border-color": "#48515b"
          }
        },
        {
          selector: "node.activity-image",
          style: {
            "background-image": "data(image)",
            "background-fit": "contain",
            "background-width": "28px",
            "background-height": "28px",
            "background-position-x": "10px",
            "background-position-y": "50%",
            "background-opacity": 1,
            "text-margin-x": 18
          }
        },
        {
          selector: "edge",
          style: {
            width: 2.4,
            "line-color": "#6f7a84",
            "target-arrow-color": "#6f7a84",
            "target-arrow-shape": "triangle",
            "curve-style": "bezier",
            label: "data(label)",
            color: "#d3dae1",
            "font-size": 10,
            "text-background-color": "#101214",
            "text-background-opacity": .9,
            "text-background-padding": 2
          }
        },
        {
          selector: "edge.journey-active",
          style: {
            width: 5,
            "line-color": "#f6c453",
            "target-arrow-color": "#f6c453",
            color: "#fff"
          }
        },
        {
          selector: "edge.journey-complete",
          style: {
            width: 4,
            "line-color": "#68d391",
            "target-arrow-color": "#68d391"
          }
        },
        {
          selector: "node:selected, edge:selected",
          style: {
            "border-width": 3,
            "border-color": "#f6c453",
            "line-color": "#f6c453",
            "target-arrow-color": "#f6c453"
          }
        }
      ],
      layout: layoutOptions(isSolution)
    });

    cy.on("tap", "node", (event) => renderDetails(event.target.data()));
    cy.on("tap", "edge", (event) => renderDetails(event.target.data()));
    cy.on("tap", (event) => {
      if (event.target === cy) detailsEl.hidden = true;
    });
  } else {
    cy.elements().remove();
    cy.add(elements);
    cy.layout(layoutOptions(isSolution)).run();
  }

  if (isJourney) {
    document.getElementById("eventCount").textContent = graph.steps.length;
    eventMetricLabelEl.textContent = "steps";
    document.getElementById("nodeCount").textContent = graph.nodes.length;
    document.getElementById("edgeCount").textContent = graph.edges.length;
    renderJourneyTimeline(graph);
    setTimeout(() => applyJourneyStep(graph), 0);
    return;
  }

  const isOrgChart = isSolution && solutionCharacterSelect.value === "__orgchart";
  const solutionShowsCharacters = isSolution && (activeMode === "characters" || solutionScopeSelect.value === "characters" || Boolean(solutionCharacterSelect.value));
  document.getElementById("eventCount").textContent = isSolution
    ? solutionShowsCharacters ? graph.nodes.filter(isCharacterNode).length : graph.nodes.length
    : events.length;
  eventMetricLabelEl.textContent = isSolution ? isOrgChart ? "people" : solutionShowsCharacters ? "characters" : "components" : "events";
  document.getElementById("nodeCount").textContent = graph.nodes.length;
  document.getElementById("edgeCount").textContent = graph.edges.length;
  if (isSolution) renderSolutionNotes(payload, graph);
  else renderTimeline(events);
}

function updateSelect(select, values, allLabel, selected) {
  const current = selected || select.value;
  select.innerHTML = allLabel ? `<option value="">${allLabel}</option>` : "";
  values.forEach((value) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    if (value === current) option.selected = true;
    select.appendChild(option);
  });
}

function updateFilters(payload) {
  const selected = selectedActors();
  actorSelect.innerHTML = "";
  (payload.actors || []).forEach((actor) => {
    const option = document.createElement("option");
    option.value = actor;
    option.textContent = actor;
    if (selected.includes(actor)) option.selected = true;
    actorSelect.appendChild(option);
  });
  const activities = [...new Set((payload.events || []).map(activityName))].sort();
  updateSelect(activitySelect, activities, "All activities", activitySelect.value);
}

function showNotice(message) {
  noticeEl.textContent = message || "";
  noticeEl.hidden = !message;
}

async function fetchGraph() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 60000);
  const query = new URLSearchParams({
    hours: hoursSelect.value
  });
  try {
    const response = await fetch(`${apiBase}/api/graph?${query}`, {
      cache: "no-store",
      signal: controller.signal
    });
    if (!response.ok) throw new Error(await response.text());
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchSolutionMap() {
  const response = await fetch("./solution-map.json", { cache: "no-store" });
  if (!response.ok) throw new Error(await response.text());
  return await response.json();
}

async function loadSolutionMap() {
  stopJourneyAnimation();
  hideJourneyComponentTable();
  hideJourneyNarrative();
  hideComponentCatalog();
  appShellEl.classList.remove("journey-active-shell");
  activeMode = "solution";
  activityControlsEl.hidden = true;
  solutionControlsEl.hidden = false;
  journeyControlsEl.hidden = true;
  componentControlsEl.hidden = true;
  refreshButton.hidden = true;
  activityModeButton.classList.remove("active");
  solutionModeButton.classList.add("active");
  charactersModeButton.classList.remove("active");
  journeyModeButton.classList.remove("active");
  componentsModeButton.classList.remove("active");
  if (modeSelect) modeSelect.value = "solution";
  solutionScopeLabel.hidden = false;
  solutionScopeSelect.disabled = false;
  solutionCharacterLabelText.textContent = "Character";
  statusEl.textContent = "Loading solution architecture...";
  try {
    solutionPayload = solutionPayload || await fetchSolutionMap();
    updateSolutionFilters(solutionPayload);
    renderGraph(solutionPayload);
    detailsEl.hidden = true;
    showNotice("");
    document.getElementById("subtitle").textContent = "Solution architecture";
    statusEl.textContent = `${document.getElementById("nodeCount").textContent} architecture nodes loaded`;
  } catch (error) {
    statusEl.textContent = "Unable to load solution map";
    detailsEl.hidden = false;
    detailsEl.innerHTML = `<h3>Solution map error</h3><p>${escapeHtml(error.message)}</p>`;
  }
}

async function loadCharactersMap() {
  stopJourneyAnimation();
  hideJourneyComponentTable();
  hideJourneyNarrative();
  hideComponentCatalog();
  appShellEl.classList.remove("journey-active-shell");
  activeMode = "characters";
  activityControlsEl.hidden = true;
  solutionControlsEl.hidden = false;
  journeyControlsEl.hidden = true;
  componentControlsEl.hidden = true;
  refreshButton.hidden = true;
  activityModeButton.classList.remove("active");
  solutionModeButton.classList.remove("active");
  charactersModeButton.classList.add("active");
  journeyModeButton.classList.remove("active");
  componentsModeButton.classList.remove("active");
  if (modeSelect) modeSelect.value = "characters";
  solutionScopeLabel.hidden = true;
  solutionScopeSelect.disabled = true;
  solutionCharacterSelect.value = "";
  solutionCharacterLabelText.textContent = "View";
  statusEl.textContent = "Loading character profiles...";
  try {
    solutionPayload = solutionPayload || await fetchSolutionMap();
    updateSolutionFilters(solutionPayload);
    renderGraph(solutionPayload);
    detailsEl.hidden = true;
    showNotice("");
    document.getElementById("subtitle").textContent = "Know your characters";
    statusEl.textContent = `${document.getElementById("eventCount").textContent} characters loaded`;
  } catch (error) {
    statusEl.textContent = "Unable to load characters";
    detailsEl.hidden = false;
    detailsEl.innerHTML = `<h3>Characters error</h3><p>${escapeHtml(error.message)}</p>`;
  }
}

function updateJourneyFilters() {
  const selectedScenario = journeyScenarioSelect.value || journeyScenarios[0].id;
  journeyScenarioSelect.innerHTML = "";
  journeyScenarios.forEach((scenario) => {
    const option = document.createElement("option");
    option.value = scenario.id;
    option.textContent = scenario.title;
    if (scenario.id === selectedScenario) option.selected = true;
    journeyScenarioSelect.appendChild(option);
  });
}

function loadJourneyMap() {
  activeMode = "journey";
  appShellEl.classList.add("journey-active-shell");
  activityControlsEl.hidden = true;
  solutionControlsEl.hidden = true;
  journeyControlsEl.hidden = false;
  componentControlsEl.hidden = true;
  refreshButton.hidden = true;
  activityModeButton.classList.remove("active");
  solutionModeButton.classList.remove("active");
  charactersModeButton.classList.remove("active");
  journeyModeButton.classList.add("active");
  componentsModeButton.classList.remove("active");
  if (modeSelect) modeSelect.value = "journey";
  updateJourneyFilters();
  showNotice("");
  detailsEl.hidden = true;
  hideComponentCatalog();
  document.getElementById("subtitle").textContent = "Educational Azure architecture";
  journeyStepIndex = 0;
  renderGraph({});
  fitJourneyView();
  startJourneyAnimation({ restart: false });
}

async function loadDetailedComponents() {
  stopJourneyAnimation();
  hideJourneyComponentTable();
  hideJourneyNarrative();
  appShellEl.classList.remove("journey-active-shell");
  activeMode = "components";
  activityControlsEl.hidden = true;
  solutionControlsEl.hidden = true;
  journeyControlsEl.hidden = true;
  componentControlsEl.hidden = false;
  refreshButton.hidden = true;
  activityModeButton.classList.remove("active");
  solutionModeButton.classList.remove("active");
  charactersModeButton.classList.remove("active");
  journeyModeButton.classList.remove("active");
  componentsModeButton.classList.add("active");
  if (modeSelect) modeSelect.value = "components";
  showNotice("");
  detailsEl.hidden = true;
  document.getElementById("subtitle").textContent = "Detailed environment guide";
  statusEl.textContent = "Loading detailed component guide...";
  try {
    solutionPayload = solutionPayload || await fetchSolutionMap();
    renderGraph(solutionPayload);
    statusEl.textContent = `${document.getElementById("nodeCount").textContent} detailed components loaded`;
  } catch (error) {
    statusEl.textContent = "Unable to load detailed components";
    detailsEl.hidden = false;
    detailsEl.innerHTML = `<h3>Component guide error</h3><p>${escapeHtml(error.message)}</p>`;
  }
}

function updateSolutionFilters(payload) {
  const current = solutionCharacterSelect.value;
  const characters = [
    ...(payload.nodes || []).filter(isCharacterNode).map((node) => ({
      id: node.id,
      displayName: String(node.label || node.id).split("\n")[0]
    })),
    ...(characterProfiles.profiles || []).map((profile) => ({
      id: profile.id,
      displayName: profile.displayName
    }))
  ]
    .filter((item, index, list) => list.findIndex((candidate) => candidate.id === item.id) === index)
    .sort((a, b) => a.displayName.localeCompare(b.displayName));
  solutionCharacterSelect.innerHTML = activeMode === "characters"
    ? '<option value="">All character profiles</option><option value="__orgchart">Complete organization chart</option>'
    : '<option value="">All characters</option>';
  characters.forEach((node) => {
    const option = document.createElement("option");
    option.value = node.id;
    option.textContent = node.displayName;
    if (node.id === current) option.selected = true;
    solutionCharacterSelect.appendChild(option);
  });
}

async function loadGraph({ background = false } = {}) {
  if (isLoading || !apiBase) return;
  stopJourneyAnimation();
  hideJourneyComponentTable();
  hideJourneyNarrative();
  hideComponentCatalog();
  appShellEl.classList.remove("journey-active-shell");
  const requestMode = "activity";
  activeMode = "activity";
  activityControlsEl.hidden = false;
  solutionControlsEl.hidden = true;
  journeyControlsEl.hidden = true;
  componentControlsEl.hidden = true;
  refreshButton.hidden = false;
  activityModeButton.classList.add("active");
  solutionModeButton.classList.remove("active");
  charactersModeButton.classList.remove("active");
  journeyModeButton.classList.remove("active");
  componentsModeButton.classList.remove("active");
  if (modeSelect) modeSelect.value = "activity";
  storyTitleEl.textContent = "Storyline";
  isLoading = true;
  statusEl.textContent = background ? "Refreshing activity..." : "Loading activity from ADX...";
  refreshButton.disabled = true;
  try {
    const payload = await fetchGraph();
    if (activeMode !== requestMode) return;
    lastPayload = payload;
    lastDataRefreshAt = payload.generatedAt;
    updateFilters(payload);
    renderGraph(payload);
    updatePortalStatus();
    detailsEl.hidden = true;
    showNotice("Start by choosing one or more users, an activity type, or a lookback window to focus the story.");
    document.getElementById("subtitle").textContent = `Updated ${new Date(payload.generatedAt).toLocaleTimeString()}`;
    statusEl.textContent = `${filteredEvents(payload).length} events loaded`;
  } catch (error) {
    if (activeMode !== requestMode) return;
    const message = error.name === "AbortError" ? "API request timed out" : error.message;
    if (lastPayload) {
      statusEl.textContent = `${filteredEvents(lastPayload).length} events loaded`;
      showNotice(`Last refresh failed: ${message}. Showing the latest loaded data.`);
      renderGraph(lastPayload);
    } else {
      statusEl.textContent = "Unable to load activity";
      detailsEl.hidden = false;
      detailsEl.innerHTML = `<h3>API error</h3><p>${escapeHtml(message)}</p>`;
    }
  } finally {
    refreshButton.disabled = false;
    isLoading = false;
  }
}

refreshButton.addEventListener("click", () => loadGraph());
actorSelect.addEventListener("change", () => {
  if (lastPayload) {
    renderGraph(lastPayload);
    statusEl.textContent = `${filteredEvents(lastPayload).length} events loaded`;
  }
});
hoursSelect.addEventListener("change", () => loadGraph());
activitySelect.addEventListener("change", () => {
  if (lastPayload) {
    renderGraph(lastPayload);
    statusEl.textContent = `${filteredEvents(lastPayload).length} events loaded`;
  }
});
viewSelect.addEventListener("change", () => {
  if (lastPayload) renderGraph(lastPayload);
});
fitButton.addEventListener("click", () => {
  if (!cy) return;
  if (activeMode === "journey") fitJourneyView();
  else cy.fit(undefined, 30);
});
activityModeButton.addEventListener("click", () => {
  if (activeMode !== "activity") loadGraph({ background: Boolean(lastPayload) });
});
solutionModeButton.addEventListener("click", () => {
  if (activeMode !== "solution") loadSolutionMap();
});
charactersModeButton.addEventListener("click", () => {
  if (activeMode !== "characters") loadCharactersMap();
});
journeyModeButton.addEventListener("click", () => {
  if (activeMode !== "journey") loadJourneyMap();
});
componentsModeButton.addEventListener("click", () => {
  if (activeMode !== "components") loadDetailedComponents();
});
if (modeSelect) {
  modeSelect.addEventListener("change", () => {
    if (modeSelect.value === "activity") loadGraph({ background: Boolean(lastPayload) });
    if (modeSelect.value === "solution") loadSolutionMap();
    if (modeSelect.value === "characters") loadCharactersMap();
    if (modeSelect.value === "journey") loadJourneyMap();
    if (modeSelect.value === "components") loadDetailedComponents();
  });
}
solutionScopeSelect.addEventListener("change", () => {
  if (solutionPayload && activeMode === "solution") renderGraph(solutionPayload);
});
componentScopeSelect.addEventListener("change", () => {
  if (solutionPayload && activeMode === "components") renderGraph(solutionPayload);
});
solutionCharacterSelect.addEventListener("change", () => {
  if (solutionPayload && activeMode !== "activity") {
    renderGraph(solutionPayload);
    const profile = getCharacterProfile(solutionCharacterSelect.value);
    if (profile) renderCharacterProfile(profile);
    else detailsEl.hidden = true;
  }
});
journeyScenarioSelect.addEventListener("change", () => loadJourneyMap());
journeySpeedSelect.addEventListener("change", () => {
  if (activeMode === "journey") startJourneyAnimation({ restart: false });
});
journeyReplayButton.addEventListener("click", () => {
  if (activeMode === "journey") startJourneyAnimation({ restart: true });
});

const guideSteps = [
  {
    title: "Choose a view",
    body: "Use the navigation to move between live activity, solution architecture, personas, learning journeys, and the detailed component guide."
  },
  {
    title: "Filter the Activity Map",
    body: "Start with a user, activity, or lookback window. The graph and storyline will narrow to the selected evidence."
  },
  {
    title: "Teach with Learning Journey",
    body: "Learning Journey animates the flow and explains why each service matters during a demo."
  },
  {
    title: "Explain every component",
    body: "Detailed components lists the Azure and Microsoft 365 services, who uses them, and which permissions are typically required."
  }
];

function finishGuide() {
  if (guideOverlay) guideOverlay.hidden = true;
  try {
    localStorage.setItem("activityStoryMapGuideSeen", "true");
  } catch {
    // Ignore storage restrictions.
  }
}

function renderGuideStep() {
  if (!guideOverlay || !guideTitle || !guideBody || !guideStepLabel || !guideNextButton) return;
  const step = guideSteps[guideStepIndex] || guideSteps[0];
  guideStepLabel.textContent = `Guide ${guideStepIndex + 1} of ${guideSteps.length}`;
  guideTitle.textContent = step.title;
  guideBody.textContent = step.body;
  guideNextButton.textContent = guideStepIndex === guideSteps.length - 1 ? "Done" : "Next";
  guideOverlay.hidden = false;
}

function startGuide({ force = false } = {}) {
  if (!force) {
    try {
      if (localStorage.getItem("activityStoryMapGuideSeen") === "true") return;
    } catch {
      // Ignore storage restrictions.
    }
  }
  guideStepIndex = 0;
  renderGuideStep();
}

if (guideNextButton) {
  guideNextButton.addEventListener("click", () => {
    if (guideStepIndex >= guideSteps.length - 1) {
      finishGuide();
      return;
    }
    guideStepIndex += 1;
    renderGuideStep();
  });
}
if (guideSkipButton) guideSkipButton.addEventListener("click", finishGuide);
if (helpButton) helpButton.addEventListener("click", () => startGuide({ force: true }));

function startPortal() {
  if (hasStarted) return;
  hasStarted = true;
  if (welcomeScreenEl) welcomeScreenEl.classList.add("welcome-hidden");
  if (appShellEl) appShellEl.classList.remove("app-hidden");
  Promise.all([loadAssetMap(), loadCharacterProfiles()]).finally(() => {
    loadGraph();
    setTimeout(() => startGuide(), 500);
  });
}

updatePortalStatus();
updateVisitStats({ countVisit: true });
if (startButton) startButton.addEventListener("click", startPortal);
else startPortal();
setInterval(() => {
  if (hasStarted && activeMode === "activity") loadGraph({ background: true });
}, 5 * 60 * 1000);
