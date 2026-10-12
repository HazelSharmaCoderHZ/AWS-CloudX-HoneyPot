// lib/api.js - thin HTTP client for the HaaS backend.
// All data comes from the backend. No mock data is ever shown as real.

const BASE = (function () {
  if (typeof window !== "undefined") {
    // Browser: use same origin or env override
    return process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";
  }
  // Server: default to backend service in Docker, else localhost
  return process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";
})();

async function request(path, options = {}) {
  const url = BASE + path;
  const resp = await fetch(url, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    throw new Error(`HTTP ${resp.status} ${path}: ${text || resp.statusText}`);
  }
  return resp.json();
}

export async function health() {
  return request("/health");
}

export async function getStats() {
  return request("/api/stats");
}

export async function getEvents(params = {}) {
  const qs = new URLSearchParams();
  if (params.limit) qs.set("limit", params.limit);
  if (params.src_ip) qs.set("src_ip", params.src_ip);
  if (params.session) qs.set("session", params.session);
  const suffix = qs.toString() ? `?${qs}` : "";
  return request("/api/events" + suffix);
}

export async function getCharts(limit = 12) {
  return request(`/api/charts?limit=${limit}`);
}

export async function getPipeline() {
  return request("/api/pipeline");
}

export async function getConfig() {
  return request("/api/config");
}

export default { health, getStats, getEvents, getCharts, getPipeline, getConfig };