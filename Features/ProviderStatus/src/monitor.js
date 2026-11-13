// Máquina de estados por herramienta. Solo emite eventos en transiciones confirmadas:
//   - "degraded"/"down": el problema se observa en `badChecks` lecturas seguidas.
//   - "recovered": tras un problema, el estado se mantiene "ok" durante `stableMs`.
// Las lecturas "unknown" conservan el estado confirmado, pero interrumpen la confirmación pendiente.

export const DEFAULTS = { badChecks: 2, stableMs: 10 * 60_000 };

const blank = (status, now) => ({ confirmed: status, badStreak: 0, downStreak: 0, okSince: null, since: now });

export const step = (prev, obs, now, opts = DEFAULTS) => {
  if (obs.status === "unknown")
    return { state: prev ? { ...prev, badStreak: 0, downStreak: 0, okSince: null } : prev, event: null };

  // Primera lectura: fija la base sin avisar, para poder anunciar la recuperación más tarde.
  if (!prev) return { state: blank(obs.status, now), event: null };

  const state = { ...prev };
  let event = null;

  if (obs.status === "ok") {
    state.badStreak = 0;
    state.downStreak = 0;
    if (state.confirmed !== "ok") {
      state.okSince ??= now;
      if (now - state.okSince >= opts.stableMs) {
        event = "recovered";
        Object.assign(state, { confirmed: "ok", okSince: null, since: now });
      }
    }
  } else {
    state.okSince = null;
    state.badStreak += 1;
    state.downStreak = obs.status === "down" ? state.downStreak + 1 : 0;
    // "down" exige sus propias lecturas seguidas; "degraded" basta con cualquier problema sostenido.
    const next =
      state.downStreak >= opts.badChecks && state.confirmed !== "down"
        ? "down"
        : state.badStreak >= opts.badChecks && state.confirmed === "ok"
          ? "degraded"
          : null;
    if (next) {
      event = next;
      Object.assign(state, { confirmed: next, since: now });
    }
  }
  return { state, event };
};

export const runOnce = async ({ sources, store, notify, now = Date.now(), opts = DEFAULTS }) => {
  const state = await store.load();
  const report = [];
  for (const [id, src] of Object.entries(sources)) {
    let obs;
    try {
      obs = await src.check();
    } catch (err) {
      obs = { status: "unknown", detail: err.message };
    }
    const { state: next, event } = step(state[id], obs, now, opts);
    if (next) state[id] = next;
    report.push({
      id,
      label: src.label,
      observed: obs.status,
      confirmed: state[id]?.confirmed ?? "unknown",
      detail: obs.detail,
      event,
    });
    if (event) await notify({ id, label: src.label, event, detail: obs.detail });
  }
  await store.save(state);
  return report;
};
