// Probes: cada fuente devuelve { status: "ok" | "degraded" | "down", detail }.
// Si la sonda falla (red, formato inesperado) lanza; el monitor lo trata como "unknown"
// y no cambia el estado confirmado.

const TIMEOUT_MS = 10_000;

const get = (url) => fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { "user-agent": "switchboard" } });

const getJson = async (url) => {
  const res = await get(url);
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return res.json();
};

const RANK = { ok: 0, degraded: 1, down: 2 };
const worst = (a, b) => (RANK[b] > RANK[a] ? b : a);

const COMPONENT_STATUS = {
  operational: "ok",
  under_maintenance: "ok",
  degraded_performance: "degraded",
  partial_outage: "degraded",
  major_outage: "down",
};

// Atlassian Statuspage: mira solo los componentes que importan para usar la herramienta.
export const fromStatuspage = (summary, relevant) => {
  const picked = summary.components.filter((c) => relevant.includes(c.name));
  if (!picked.length) throw new Error("ninguno de los componentes esperados existe en la página de estado");
  let status = "ok";
  const bad = [];
  for (const c of picked) {
    const s = COMPONENT_STATUS[c.status];
    if (s === undefined) throw new Error(`estado de componente desconocido: ${c.status}`);
    status = worst(status, s);
    if (s !== "ok") bad.push(`${c.name}: ${c.status}`);
  }
  return { status, detail: bad.length ? bad.join("; ") : "componentes clave operativos" };
};

// Google Cloud: incidentes sin `end` que mencionen Gemini/Vertex AI. Es una aproximación
// para Antigravity, que no publica página de estado propia.
export const fromGoogleIncidents = (incidents) => {
  const active = incidents.filter((i) => {
    if (i.end) return false;
    const where = [i.service_name, ...(i.affected_products ?? []).map((p) => p.title)].join(" ");
    return /gemini|vertex ai|antigravity/i.test(where);
  });
  if (!active.length) return { status: "ok", detail: "sin incidentes activos de Gemini/Vertex AI (aprox.)" };
  const down = active.some((i) => i.status_impact === "SERVICE_OUTAGE");
  return { status: down ? "down" : "degraded", detail: active.map((i) => i.external_desc).join("; ") };
};

// OpenCode: status.opencode.ai/api/status trae el estado global y por componente.
// `stale` indica que la propia página no se está actualizando: no es fiable.
const OPENCODE_STATUS = { operational: "ok", degraded: "degraded", down: "down", outage: "down", major_outage: "down" };

export const fromOpenCodeStatus = (data) => {
  if (data.stale) throw new Error("status.opencode.ai marca sus datos como obsoletos (stale)");
  const status = OPENCODE_STATUS[data.status];
  if (!status) throw new Error(`estado global de OpenCode desconocido: "${data.status}"`);
  const bad = (data.components ?? [])
    .filter((c) => c.status !== "operational")
    .map((c) => `${c.service}: ${c.status} (${c.reason})`);
  return { status, detail: bad.length ? bad.join("; ") : "servicios operativos" };
};

export const SOURCES = {
  claude: {
    label: "Claude",
    check: async () =>
      fromStatuspage(await getJson("https://status.claude.com/api/v2/summary.json"), [
        "claude.ai",
        "Claude API (api.anthropic.com)",
        "Claude Code",
      ]),
  },
  openai: {
    label: "GPT",
    check: async () =>
      fromStatuspage(await getJson("https://status.openai.com/api/v2/summary.json"), [
        "Chat Completions",
        "Responses",
        "Conversations",
        "Login",
        "Codex in ChatGPT Desktop",
      ]),
  },
  antigravity: {
    label: "Antigravity",
    check: async () => fromGoogleIncidents(await getJson("https://status.cloud.google.com/incidents.json")),
  },
  opencode: {
    label: "OpenCode",
    check: async () => {
      const fromPage = fromOpenCodeStatus(await getJson("https://status.opencode.ai/api/status"));
      // Sonda real: el catálogo de modelos de Zen debe responder.
      const zen = await get("https://opencode.ai/zen/v1/models").catch(() => null);
      if (!zen?.ok) return { status: "down", detail: `Zen /models no responde (${zen?.status ?? "sin red"})` };
      return fromPage;
    },
  },
};
