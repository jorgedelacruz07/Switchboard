import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export const message = ({ label, event }) =>
  ({
    recovered: `${label} ya está disponible`,
    degraded: `${label} presenta problemas`,
    down: `${label} está caído`,
  })[event];

// Salidas: consola siempre; macOS, Telegram y webhook (Home Assistant) solo si están activadas.
// DRY_RUN=1 imprime sin enviar nada.
export const makeNotifier = (env = process.env) => {
  const dry = env.DRY_RUN === "1";
  return async (evt) => {
    const text = message(evt);
    console.log(`${dry ? "[dry-run] " : ""}${evt.event.toUpperCase()}: ${text}${evt.detail ? ` (${evt.detail})` : ""}`);
    if (dry) return;

    const jobs = [];
    if (env.NOTIFY_MACOS === "1")
      jobs.push(
        run("osascript", [
          "-e",
          'on run argv\ndisplay notification (item 1 of argv) with title "AI Status"\nend run',
          text,
        ]),
      );
    if (env.NOTIFY_TELEGRAM === "1") jobs.push(run(env.TELEGRAM_NOTIFY_BIN ?? "notify-telegram", [text, "AI Status"]));
    if (env.HA_WEBHOOK_URL)
      jobs.push(
        fetch(env.HA_WEBHOOK_URL, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ tool: evt.id, event: evt.event, message: text }),
          signal: AbortSignal.timeout(10_000),
        }).then((r) => {
          if (!r.ok) throw new Error(`webhook -> HTTP ${r.status}`);
        }),
      );
    for (const r of await Promise.allSettled(jobs))
      if (r.status === "rejected") console.error(`aviso falló: ${r.reason.message}`);
  };
};
