const crypto = require("crypto");

const containerName = "activity-story-map";
const blobName = "visits/summary.json";
const storageVersion = "2020-10-02";

function jsonResponse(status, body) {
  return {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store"
    },
    body
  };
}

function parseConnectionString(value) {
  const parts = {};
  String(value || "").split(";").forEach((part) => {
    const index = part.indexOf("=");
    if (index > 0) parts[part.slice(0, index)] = part.slice(index + 1);
  });
  if (!parts.AccountName || !parts.AccountKey) {
    throw new Error("AzureWebJobsStorage must include AccountName and AccountKey.");
  }
  const protocol = parts.DefaultEndpointsProtocol || "https";
  const suffix = parts.EndpointSuffix || "core.windows.net";
  return {
    accountName: parts.AccountName,
    accountKey: parts.AccountKey,
    blobEndpoint: parts.BlobEndpoint || `${protocol}://${parts.AccountName}.blob.${suffix}`
  };
}

function blobAuthHeader({ method, url, headers, contentLength = "" }) {
  const storage = parseConnectionString(process.env.AzureWebJobsStorage);
  const canonicalizedHeaders = Object.keys(headers)
    .filter((key) => key.toLowerCase().startsWith("x-ms-"))
    .map((key) => [key.toLowerCase(), String(headers[key]).trim()])
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}:${value}\n`)
    .join("");
  const canonicalizedResource = `/${storage.accountName}/${containerName}/${blobName}`;
  const contentType = headers["Content-Type"] || "";
  const stringToSign = [
    method,
    "",
    "",
    contentLength,
    "",
    contentType,
    "",
    "",
    "",
    "",
    "",
    "",
    canonicalizedHeaders + canonicalizedResource
  ].join("\n");
  const signature = crypto
    .createHmac("sha256", Buffer.from(storage.accountKey, "base64"))
    .update(stringToSign, "utf8")
    .digest("base64");
  return {
    url,
    authorization: `SharedKey ${storage.accountName}:${signature}`
  };
}

function blobUrl() {
  const storage = parseConnectionString(process.env.AzureWebJobsStorage);
  return `${storage.blobEndpoint.replace(/\/$/, "")}/${containerName}/${blobName}`;
}

async function readVisitState() {
  const headers = {
    "x-ms-date": new Date().toUTCString(),
    "x-ms-version": storageVersion
  };
  const signed = blobAuthHeader({ method: "GET", url: blobUrl(), headers });
  const response = await fetch(signed.url, {
    method: "GET",
    headers: {
      ...headers,
      Authorization: signed.authorization
    }
  });
  if (response.status === 404) return {};
  if (!response.ok) throw new Error(`Visit state read failed: ${response.status} ${await response.text()}`);
  return parseState(await response.text());
}

async function writeVisitState(state) {
  const body = JSON.stringify(state, null, 2);
  const headers = {
    "Content-Type": "application/json",
    "x-ms-blob-type": "BlockBlob",
    "x-ms-date": new Date().toUTCString(),
    "x-ms-version": storageVersion
  };
  const signed = blobAuthHeader({
    method: "PUT",
    url: blobUrl(),
    headers,
    contentLength: Buffer.byteLength(body).toString()
  });
  const response = await fetch(signed.url, {
    method: "PUT",
    headers: {
      ...headers,
      Authorization: signed.authorization,
      "Content-Length": Buffer.byteLength(body).toString()
    },
    body
  });
  if (!response.ok) throw new Error(`Visit state write failed: ${response.status} ${await response.text()}`);
}

function parseState(raw) {
  if (!raw) return {};
  try {
    return typeof raw === "string" ? JSON.parse(raw) : JSON.parse(raw.toString("utf8"));
  } catch {
    return {};
  }
}

function clientFingerprint(req) {
  const forwardedFor = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
  const clientIp = forwardedFor || req.headers["x-client-ip"] || req.headers["x-real-ip"] || "unknown";
  const userAgent = req.headers["user-agent"] || "unknown";
  return crypto
    .createHash("sha256")
    .update(`${clientIp}|${userAgent}|activity-story-map`)
    .digest("hex");
}

function publicStats(state) {
  return {
    totalVisits: state.totalVisits || 0,
    uniqueVisitors: (state.uniqueVisitors || []).length,
    todayVisits: state.todayVisits || 0,
    todayUniqueVisitors: (state.todayUniqueVisitors || []).length,
    firstVisitAt: state.firstVisitAt || null,
    lastVisitAt: state.lastVisitAt || null,
    updatedAt: state.updatedAt || null
  };
}

module.exports = async function (context, req) {
  try {
    const now = new Date();
    const today = now.toISOString().slice(0, 10);
    const shouldCount = String(req.method || "").toUpperCase() === "POST";
    const state = await readVisitState();
    const previousToday = state.today;

    state.totalVisits = Number(state.totalVisits || 0);
    state.uniqueVisitors = Array.isArray(state.uniqueVisitors) ? state.uniqueVisitors : [];
    state.today = today;
    state.todayVisits = previousToday === today ? Number(state.todayVisits || 0) : 0;
    state.todayUniqueVisitors = previousToday === today && Array.isArray(state.todayUniqueVisitors)
      ? state.todayUniqueVisitors
      : [];

    if (shouldCount) {
      const visitor = clientFingerprint(req);
      state.totalVisits += 1;
      state.todayVisits += 1;
      if (!state.uniqueVisitors.includes(visitor)) state.uniqueVisitors.push(visitor);
      if (!state.todayUniqueVisitors.includes(visitor)) state.todayUniqueVisitors.push(visitor);
      state.firstVisitAt = state.firstVisitAt || now.toISOString();
      state.lastVisitAt = now.toISOString();
      state.updatedAt = now.toISOString();
      await writeVisitState(state);
    }

    context.res = jsonResponse(200, publicStats(state));
  } catch (error) {
    context.log.error(error);
    context.res = jsonResponse(500, { error: error.message });
  }
};
