#!/usr/bin/env node
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runOnce, DEFAULTS } from "./monitor.js";
import { makeNotifier } from "./notify.js";
import { SOURCES } from "./sources.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const STATE_FILE = process.env.AI_STATUS_STATE ?? join(ROOT, ".data", "state.json");

const store = {
  load: async () => {
    try {
      return JSON.parse(await readFile(STATE_FILE, "utf8"));
    } catch (err) {
      if (err.code === "ENOENT") return {};
      throw err;
    }
  },
  save: async (state) => {
    await mkdir(dirname(STATE_FILE), { recursive: true });
    const tmp = `${STATE_FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(state, null, 2));
    await rename(tmp, STATE_FILE);
  },
};

const color = process.env.NO_COLOR ? (_, s) => s : (c, s) => `\x1b[${c}m${s}\x1b[0m`;
const PAINT = {
  ok: (s) => color(32, s),
  degraded: (s) => color(33, s),
  down: (s) => color(31, s),
  unknown: (s) => color(90, s),
};

const print = (report) => {
  for (const r of report)
    console.log(`${PAINT[r.observed](r.observed.padEnd(8))} ${r.label.padEnd(12)} ${r.detail ?? ""}`);
};

const [cmd = "once", ...flags] = process.argv.slice(2);
const opts = {
  badChecks: Number(process.env.BAD_CHECKS ?? DEFAULTS.badChecks),
  stableMs: Number(process.env.STABLE_MINUTES ?? DEFAULTS.stableMs / 60_000) * 60_000,
};

if (cmd === "status") {
  // Solo lectura: no toca el estado ni envía avisos. Pensado para la futura skill de Alexa.
  const report = [];
  for (const [id, src] of Object.entries(SOURCES)) {
    const obs = await src.check().catch((e) => ({ status: "unknown", detail: e.message }));
    report.push({ id, label: src.label, observed: obs.status, detail: obs.detail });
  }
  if (flags.includes("--json")) console.log(JSON.stringify(report, null, 2));
  else print(report);
} else if (cmd === "once") {
  const report = await runOnce({ sources: SOURCES, store, notify: makeNotifier(), opts });
  if (!flags.includes("--quiet")) print(report);
} else {
  console.error(
    "uso: cli.js [once [--quiet] | status [--json]]\nvariables: DRY_RUN, NO_COLOR, STABLE_MINUTES, BAD_CHECKS, NOTIFY_MACOS, NOTIFY_TELEGRAM, HA_WEBHOOK_URL",
  );
  process.exit(2);
}
