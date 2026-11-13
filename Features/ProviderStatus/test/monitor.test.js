import { test } from "node:test";
import assert from "node:assert/strict";
import { step, DEFAULTS } from "../src/monitor.js";
import { fromStatuspage, fromGoogleIncidents, fromOpenCodeStatus } from "../src/sources.js";
import { makeNotifier } from "../src/notify.js";

const MIN = 60_000;
const ok = { status: "ok" };
const bad = { status: "degraded" };
const down = { status: "down" };

// Aplica una secuencia de [observación, minuto] y devuelve los eventos emitidos.
const play = (seq, opts = DEFAULTS) => {
  let state;
  const events = [];
  for (const [obs, minute] of seq) {
    const r = step(state, obs, minute * MIN, opts);
    state = r.state;
    if (r.event) events.push([r.event, minute]);
  }
  return { state, events };
};

test("la primera lectura no avisa, aunque esté degradado", () => {
  const { events, state } = play([[bad, 0]]);
  assert.deepEqual(events, []);
  assert.equal(state.confirmed, "degraded");
});

test("avisa 'recovered' solo tras mantenerse ok el tiempo estable", () => {
  const { events } = play([
    [bad, 0],
    [ok, 2],
    [ok, 5],
    [ok, 11],
    [ok, 12],
    [ok, 14],
  ]);
  assert.deepEqual(events, [["recovered", 12]]);
});

test("una recaída durante la espera reinicia el contador", () => {
  const { events } = play([
    [bad, 0],
    [ok, 2],
    [bad, 6],
    [ok, 8],
    [ok, 17],
    [ok, 18],
  ]);
  assert.deepEqual(events, [["recovered", 18]]);
});

test("una lectura mala aislada no genera aviso; dos seguidas sí", () => {
  assert.deepEqual(
    play([
      [ok, 0],
      [bad, 2],
      [ok, 4],
    ]).events,
    [],
  );
  assert.deepEqual(
    play([
      [ok, 0],
      [bad, 2],
      [bad, 4],
      [bad, 6],
    ]).events,
    [["degraded", 4]],
  );
});

test("escala de degraded a down, pero no repite el aviso", () => {
  const { events } = play([
    [ok, 0],
    [bad, 2],
    [bad, 4],
    [down, 6],
    [down, 8],
    [down, 10],
  ]);
  assert.deepEqual(events, [
    ["degraded", 4],
    ["down", 8],
  ]);
});

test("las lecturas unknown conservan el estado confirmado sin avisar", () => {
  const { events, state } = play([
    [bad, 0],
    [{ status: "unknown" }, 2],
    [{ status: "unknown" }, 20],
  ]);
  assert.deepEqual(events, []);
  assert.equal(state.confirmed, "degraded");
});

test("unknown interrumpe la espera de recuperación sin confirmar disponibilidad", () => {
  const { events } = play([
    [bad, 0],
    [ok, 2],
    [{ status: "unknown" }, 10],
    [ok, 12],
    [ok, 20],
    [ok, 22],
  ]);
  assert.deepEqual(events, [["recovered", 22]]);
  assert.equal(step(undefined, { status: "unknown" }, 0).state, undefined);
});

test("unknown rompe las rachas de degradación y caída", () => {
  const { events } = play([
    [ok, 0],
    [bad, 2],
    [{ status: "unknown" }, 4],
    [bad, 6],
    [bad, 8],
    [down, 10],
    [{ status: "unknown" }, 12],
    [down, 14],
    [down, 16],
  ]);
  assert.deepEqual(events, [
    ["degraded", 8],
    ["down", 16],
  ]);
});

test("statuspage: toma el peor de los componentes relevantes e ignora el resto", () => {
  const summary = {
    components: [
      { name: "Claude Code", status: "operational" },
      { name: "claude.ai", status: "partial_outage" },
      { name: "Claude for Government", status: "major_outage" },
    ],
  };
  const r = fromStatuspage(summary, ["Claude Code", "claude.ai"]);
  assert.equal(r.status, "degraded");
  assert.match(r.detail, /claude\.ai/);
});

test("statuspage: falla ruidosamente si cambian los nombres de componentes", () => {
  assert.throws(() => fromStatuspage({ components: [{ name: "X", status: "operational" }] }, ["Claude Code"]));
});

test("google: solo cuentan incidentes activos de Gemini/Vertex AI", () => {
  const incidents = [
    { end: "2026-10-20T14:00:00+00:00", service_name: "Vertex AI Gemini API", external_desc: "viejo" },
    { service_name: "Cloud SQL", external_desc: "otro producto" },
    { service_name: "Vertex AI Gemini API", status_impact: "SERVICE_DISRUPTION", external_desc: "activo" },
  ];
  assert.deepEqual(fromGoogleIncidents(incidents), { status: "degraded", detail: "activo" });
  assert.equal(fromGoogleIncidents([]).status, "ok");
});

test("opencode: estado global y componentes", () => {
  const ok = {
    status: "operational",
    stale: false,
    components: [{ service: "inference", status: "operational", reason: "none" }],
  };
  assert.deepEqual(fromOpenCodeStatus(ok), { status: "ok", detail: "servicios operativos" });
  const bad = { status: "degraded", components: [{ service: "console", status: "degraded", reason: "errors" }] };
  assert.deepEqual(fromOpenCodeStatus(bad), { status: "degraded", detail: "console: degraded (errors)" });
});

test("opencode: datos obsoletos o estado desconocido no se interpretan como ok", () => {
  assert.throws(() => fromOpenCodeStatus({ status: "operational", stale: true }), /obsoletos/);
  assert.throws(() => fromOpenCodeStatus({ status: "algo-nuevo" }), /desconocido/);
});

test("el webhook entrega los cuatro identificadores que acepta Home Assistant", async (t) => {
  const requests = [];
  t.mock.method(globalThis, "fetch", async (url, init) => {
    requests.push({ url, ...init, body: JSON.parse(init.body) });
    return { ok: true, status: 200 };
  });
  t.mock.method(console, "log", () => {});
  const url = "http://homeassistant.invalid/api/webhook/fixture";
  const notify = makeNotifier({ HA_WEBHOOK_URL: url });
  const tools = [
    ["claude", "Claude"],
    ["openai", "GPT"],
    ["antigravity", "Antigravity"],
    ["opencode", "OpenCode"],
  ];
  for (const [id, label] of tools) await notify({ id, label, event: "recovered" });
  assert.equal(requests.length, 4);
  for (const [index, request] of requests.entries()) {
    assert.equal(request.url, url);
    assert.equal(request.method, "POST");
    assert.equal(request.headers["content-type"], "application/json");
    assert.deepEqual(request.body, {
      tool: tools[index][0],
      event: "recovered",
      message: `${tools[index][1]} ya está disponible`,
    });
  }
});

test("DRY_RUN no dispara el webhook aunque esté configurado", async (t) => {
  const fetchMock = t.mock.method(globalThis, "fetch", async () => ({ ok: true }));
  t.mock.method(console, "log", () => {});
  const notify = makeNotifier({ DRY_RUN: "1", HA_WEBHOOK_URL: "http://homeassistant.invalid/api/webhook/fixture" });
  await notify({ id: "claude", label: "Claude", event: "recovered" });
  assert.equal(fetchMock.mock.callCount(), 0);
});
