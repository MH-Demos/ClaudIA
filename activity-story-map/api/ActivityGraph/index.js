function escapeKql(value) {
  return String(value || "").replace(/'/g, "''");
}

function rowToObject(columns, row) {
  const item = {};
  columns.forEach((column, index) => {
    item[column.ColumnName] = row[index];
  });
  return item;
}

async function getManagedIdentityToken() {
  const endpoint = process.env.IDENTITY_ENDPOINT || process.env.MSI_ENDPOINT;
  const header = process.env.IDENTITY_HEADER || process.env.MSI_SECRET;
  if (!endpoint || !header) {
    throw new Error("Managed identity endpoint is not available.");
  }

  const resource = encodeURIComponent("https://kusto.kusto.windows.net");
  const url = `${endpoint}?api-version=2019-08-01&resource=${resource}`;
  const response = await fetch(url, {
    headers: {
      "X-IDENTITY-HEADER": header,
      Metadata: "true"
    }
  });

  if (!response.ok) {
    throw new Error(`Managed identity token request failed: ${response.status}`);
  }

  const payload = await response.json();
  return payload.access_token;
}

function addNode(nodes, id, label, type, extra = {}) {
  if (!id || nodes.has(id)) return;
  nodes.set(id, { id, label: label || id, type, ...extra });
}

function addEdge(edges, source, target, label, event) {
  if (!source || !target) return;
  const id = `${source}|${label}|${target}|${event.TimeGenerated}`;
  edges.push({
    id,
    source,
    target,
    label,
    timestamp: event.TimeGenerated,
    activityType: event.ActivityType,
    event
  });
}

function buildGraph(events) {
  const nodes = new Map();
  const edges = [];

  for (const event of events) {
    const actorId = event.ActorUPN || event.AgentUPN || event.AgentName;
    const actorName = event.ActorName || event.AgentName || actorId;
    const serviceName = event.Service || event.ActivityType || "Activity";
    const serviceId = `service:${serviceName}`;
    const action = event.Action || event.ActivityType || "performed";

    addNode(nodes, actorId, actorName, "User", { department: event.Department });
    addNode(nodes, serviceId, serviceName, "Service");
    addEdge(edges, actorId, serviceId, action, event);

    if (event.TargetName) {
      const targetType = event.TargetType || "Target";
      const targetId = `${targetType.toLowerCase()}:${event.TargetName}`;
      addNode(nodes, targetId, event.TargetName, targetType, {
        path: event.TargetPath,
        sensitivityLabel: event.SensitivityLabel
      });
      addEdge(edges, serviceId, targetId, action, event);
    }

    if (event.RecipientUPN) {
      addNode(nodes, event.RecipientUPN, event.RecipientName || event.RecipientUPN, "User");
      addEdge(edges, actorId, event.RecipientUPN, action, event);
    }
  }

  return {
    nodes: Array.from(nodes.values()),
    edges
  };
}

module.exports = async function (context, req) {
  try {
    const queryUri = process.env.ADX_QUERY_URI;
    const database = process.env.ADX_DATABASE;
    const table = process.env.ADX_TABLE;
    if (!queryUri || !database || !table) {
      throw new Error("ADX_QUERY_URI, ADX_DATABASE, and ADX_TABLE app settings are required.");
    }

    const hours = Math.max(1, Math.min(parseInt(req.query.hours || "24", 10) || 24, 168));
    const actor = escapeKql(req.query.actor || "");
    const actorFilter = actor
      ? `| where AgentName == '${actor}' or AgentUPN == '${actor}' or ActorName == '${actor}' or ActorUPN == '${actor}'`
      : "";

    const kql = `
table('${escapeKql(table)}')
| where TimeGenerated > ago(${hours}h)
| extend
    AgentUPN = tostring(Event.AgentUPN),
    AgentName = tostring(Event.AgentName),
    ActorUPN = coalesce(tostring(Event.ActorUPN), tostring(Event.AgentUPN)),
    ActorName = coalesce(tostring(Event.ActorName), tostring(Event.AgentName)),
    Department = tostring(Event.Department),
    ActivityType = tostring(Event.ActivityType),
    Service = tostring(Event.Service),
    Action = tostring(Event.Action),
    Workload = tostring(Event.Workload),
    TargetName = tostring(Event.TargetName),
    TargetType = tostring(Event.TargetType),
    TargetPath = tostring(Event.TargetPath),
    RecipientName = tostring(Event.RecipientName),
    RecipientUPN = tostring(Event.RecipientUPN),
    Subject = tostring(Event.Subject),
    ThreadName = tostring(Event.ThreadName),
    SearchQuery = tostring(Event.SearchQuery),
    HitCount = tostring(Event.HitCount),
    SensitivityLabel = tostring(Event.SensitivityLabel),
    Detail = tostring(Event.Detail)
| where AgentName !in ('Test', 'DirectTest')
${actorFilter}
| project TimeGenerated, AgentUPN, AgentName, ActorUPN, ActorName, Department, ActivityType, Service, Action, Workload, TargetName, TargetType, TargetPath, RecipientName, RecipientUPN, Subject, ThreadName, SearchQuery, HitCount, SensitivityLabel, Detail
| order by TimeGenerated asc
| take 1000`;

    const token = await getManagedIdentityToken();
    const response = await fetch(`${queryUri.replace(/\/$/, "")}/v1/rest/query`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ db: database, csl: kql })
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(`ADX query failed: ${response.status} ${text}`);
    }

    const result = await response.json();
    const primary = result.Tables && result.Tables[0];
    const events = primary ? primary.Rows.map((row) => rowToObject(primary.Columns, row)) : [];
    const actors = Array.from(new Set(events.map((event) => event.ActorName || event.AgentName).filter(Boolean))).sort();

    context.res = {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store"
      },
      body: {
        generatedAt: new Date().toISOString(),
        hours,
        actors,
        events,
        graph: buildGraph(events)
      }
    };
  } catch (error) {
    context.log.error(error);
    context.res = {
      status: 500,
      headers: { "Content-Type": "application/json" },
      body: { error: error.message }
    };
  }
};
