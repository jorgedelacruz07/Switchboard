---
name: switchboard-release-and-audit
description: Build, test and audit the Switchboard macOS menu-bar app before a local release - gates, memory footprint, subprocess spawn rate and staged-bundle safety. Use when preparing or reviewing a Switchboard change that affects background work, timers, subprocesses, build/install or login registration.
---

# Switchboard release and audit

Local-only workflow. It never pushes, notarizes, publishes, installs over a
running app, reloads a LaunchAgent or changes login items. Those need the
owner's explicit approval for that specific action.

## 1. Preconditions

- Work on a branch or isolated worktree; leave other people's uncommitted
  changes untouched (`git status --porcelain` before and after).
- Read `AGENTS.md` in the repo root: RAM target, provider/source boundaries,
  login and staged-update rules are authoritative.
- On a shared or loaded host, check `uptime` before compiling. When the 1-minute
  load is high, run targeted checks first and record the full build as deferred.

## 2. Gates (all must pass)

```sh
./switchboard.sh test   # Python unit tests + isolated Swift self-test binary
npm run quick           # Node syntax, Prettier check, provider tests (incl. parity)
git diff --check
```

- `switchboard.sh test` builds `build/SwitchboardTests`; it never touches the
  installed app, real projects or login items.
- Provider status parsers exist in Node (`src/sources.js`) and Swift
  (`AIProviderStatus.swift`). Change both together; the shared fixture
  `Features/ProviderStatus/test/fixtures/parity.json` must pass in both suites.
- Never relax an assertion or skip a test to get green.

## 3. Background-load audit

Review every timer and subprocess the change touches:

| Check                      | Expectation                                                                                                                  |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| One-minute tick            | Ports + launcher catalog only; no Git, no network                                                                            |
| Git status                 | Own five-minute cadence; menu-open refresh has a cooldown; one helper at a time; bounded worker pool; `GIT_OPTIONAL_LOCKS=0` |
| AI usage / provider status | At most every five minutes; manual refresh cooldown; no IDE/browser/model launch                                             |
| Subprocesses               | Every `Process` has a timeout and is terminated (TERM, then KILL) on expiry                                                  |
| Main thread                | No file reads, hashing, subprocesses or network on the main thread                                                           |

Measure, do not estimate:

- Spawn count per cycle: run the CLI (`--snapshot`, or the helper script
  directly) with a test-only `posix_spawn`/`fork` counter injected through
  `DYLD_INSERT_LIBRARIES`, plus a logging `git` shim first in `PATH` for the
  helper's grandchildren. System binaries under SIP drop `DYLD_*`; launch the
  target through a small non-system launcher and count shell forks with a
  re-signed copy of the shell. Keep these tools outside the repo.
- Spawns per minute = per-cycle counts x cadence; state the assumptions (menu
  closed, provider status on/off).
- Memory: `footprint <pid>` for the running app (read-only) and
  `/usr/bin/time -l` max RSS for CLI paths and helpers, before and after.
- A second GUI instance exits at launch by design; do not kill or restart the
  installed app to measure it.

## 4. Local release build

- `./switchboard.sh build` stages, signs and verifies an isolated bundle.
- Replacing an installed app follows the staged-update rules in `AGENTS.md`
  (identity-verified status, no legacy entry, app not running, atomic exchange,
  old bundle preserved). Never rewrite signed installed code in place, never
  auto-register login items, never retry after a denial.

## 5. Evidence to record

Commit hash, diff stat, gate output lines, spawn and footprint numbers (before
and after, with method), `git status` clean, and anything deferred and why.
