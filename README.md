# Switchboard

A lightweight native macOS menu bar for development projects and AI operations.
Start and stop projects, inspect AI usage quotas and check provider availability.
The local checkout folder is `Switchboard` and the command is `switchboard`;
`mini-bar` remains available as a compatibility alias.

Built with Swift and AppKit. No Electron, web server, third-party Swift packages,
telemetry, or additional API keys.

## Features

- Start or stop all projects from the menu bar.
- Also list services from the workspace's `workspace.registry.json` that have a port but are not in the launcher catalog (for example ProjectsDocs). They have separate service controls without generic Work or Sync actions. ProjectsDocs offers **Start Portal** (its existing private LaunchAgent) and **Open Private Portal in Browser**, using `/docs/` on the private origin configured by ProjectsDocs. Client status checks that private URL directly; it does not require the development tunnel. Other registry services remain outside launcher control. Archived registry projects (for example UnaLukaApp) sit in a collapsed **Archived (n)** submenu at the end of the Projects group, never started and not counted.
- Start, stop, or restart an individual project.
- IdeaDesk has **Start IdeaDesk** and **Open IdeaDesk in Browser** controls. It
  uses the existing Mini LaunchAgent and private HTTPS app, with its built UI on
  the catalog API port (5180). Starting it preserves an already running service
  and verifies HTTP health. Its state does not depend on Vite, a development
  tunnel or Live Sync; generic sync, stop and restart controls are excluded to
  protect host-owned data and active planning jobs.
- See running, partially running, and stopped projects, refreshed every minute.
- See every project in the menu on one line (for example `AcademyDB · Running · :5173`), open it at `http://localhost:<port>`, and view its logs.
- Open each project's production site, production API, repository and ProjectsDocs page from its submenu, when those links are configured.
- Hide projects and reorder them per Mac, and edit production links, from **Configure Projects…**.
- Enable or disable launch at login.
- Keep projects running when you quit the menu.
- Preserve the external launcher's memory guard and error handling.
- Inspect AI usage every five minutes, with a pause toggle and source/freshness labels.
- Check Claude, GPT, Antigravity and OpenCode public service status every five
  minutes, with an independent pause toggle. Unknown or stale sources stay explicit.
- See the app's current physical footprint directly in the menu.

Starting the app or signing in does not automatically start development projects.
Stopping projects delegates to your launcher; the app itself does not stop databases
or infrastructure services.

## Requirements

- macOS 13 or later with Apple developer tools (`xcrun swiftc`) and Python 3.
- A development workspace containing a compatible `project-dev.sh` launcher.
- Any runtimes and tools that your launcher needs, available through mise shims,
  `~/.local/bin`, Homebrew, or the standard system paths.

This app is a controller for an existing workspace. The workspace scripts and your project
repositories are separate dependencies; they are not bundled into this repository.
The original integration uses [projects-tools](https://github.com/jorgedelacruz07/projects-tools).

## Mini workspace and Air remote client

The Mini holds authoritative code, Git state, dev servers and agents. The Air
opens existing Mini folders with **Open Mini Project in Cursor** and previews
servers through the existing SSH tunnel. Project keys and directories come from
the parent launcher catalog; no second launcher or personal home path is stored
here. Cursor's CLI (or its app-bundled executable) receives the remote path as a
literal argument after SSH resolves and checks the folder on `macmini`.

**Start Remote Work** delegates `project-remote.sh work <key>` with `NO_OPEN=1`
and without `--sync`. It preserves unfinished Mini work and is available even
when the legacy baton belongs to the Mini or is unavailable. The parent launcher
owns directory preflight, start/reuse, tunneling and HTTP readiness; nonzero
launcher, SSH and Cursor failures appear in the action result. No installed app
or live service is changed by tests.

Client source transfer, workspace handoff, Align and Air Git-write controls are
removed from this flow. Legacy handoff helpers remain for compatibility outside
the menu; they are not invoked during status refresh or remote work. Source
changes do not update installed binaries: build/install remains a separate,
explicit operation on each device.

## Dual-Role Architecture (Host vs Client)

Switchboard supports both machines in the Multi-Mac development topology:

- **Host Mode (Mac Mini):** Direct server control. Manages local Node/Vite processes via `project-dev.sh`, monitors Mac Mini memory footprint, and exposes local port status.
- **Client Mode (MacBook Air):** Remote workstation orchestrator. Manages remote development on the Mac Mini via `project-remote.sh` (`work`), with 1-click controls for:
  - **Dev Tunnel (`macmini-tunnel`):** Connects or disconnects the SSH port-forwarding tunnel for all web and API ports (`5173-5181`, `3001-3006`).
  - **Docker Remote:** Connects or disconnects the remote Docker socket tunnel (MongoDB `:27018` and Redis `:6380`).
  - **Per-Project Session (`work <proj>`):** Uses existing Mini sources, starts or reuses its dev server, verifies the tunnel and HTTP readiness; does not sync or reconcile Git.
  - **Per-Project Stop (`work stop <proj>`):** Stops the selected Mini dev server; the shared tunnel remains available.
  - **Remote Editor:** Opens the catalog project directory in Cursor Remote SSH.
  - **Browser Launch:** Opens `http://localhost:<webPort>` directly in the Air's browser when tunneled.

Role detection is automatic based on machine hostname (`mac-mini` = host, others = client), and can be toggled in the menu under _Role_ or via `./switchboard.sh role client|host|auto`.

## Menu layout

The menu has three groups, each with a header row.

- **Projects:** header `Projects · N of M active`. All workspace repositories and
  services are listed in this group. Launcher projects show `Name · state · :port`
  with remote start/stop and editor actions. Services (IdeaDesk, ProjectsDocs) provide
  dedicated service controls and Tailscale access. Repositories and tools (Switchboard,
  Jorge's Vault, workspace meta-repo) show git branch, dirty/unpushed status and
  direct links without false stopped states or server controls. Each submenu includes
  status lines, applicable actions, **Git & Quality** details, and **Open** rows.
  The workspace header identifies the Mini as the source owner. Archived
  projects are collapsed into **Archived (n)** at the end.
- **AI:** local quota cards plus public provider status. Usage and provider checks
  have separate pause controls and five-minute refresh schedules.
- **Services and system:** Dev Tunnel and Docker Remote (client) or shared infra
  (host), **Configure Projects…**, Role, memory line, Launch at Login and Quit.

**Open** rows are Local (`localhost:<port>`), Production, Production API, Repository,
ProjectsDocs, Reveal in Finder, and Logs. A row whose URL is not configured is omitted rather than shown
disabled. Only `https` links are opened; ProjectsDocs needs its private portal URL.

### Counter

The menu bar title is `⚡ in-use/total` on a client and `in-use/total` on a host. A
project is in use when its state is not off. Archived projects, services and AI are
not counted, and neither are projects you hid in the settings window: they leave both
numbers. With no visible projects the title reads `0/0` and the header
`Projects · 0 of 0 active`. The tooltip spells out the same numbers and adds
`· n hidden` when any are hidden.

### Configure Projects…

A native window, created when you open it and released when you close it. One row per
project:

- **Visible in menu** checkbox and **order** (move up and down). These are saved per
  Mac in `.local/settings.json` (ignored by git).
- **Local port**, read-only. Ports always come from the launcher catalog.
- **Production** and **API** URLs, editable, `https` only. A row with no registry
  entry shows `No registry entry` and its fields are disabled; the window never
  creates registry entries. Clearing a field removes that link.

Saving URLs makes a minimal text edit to `workspace.registry.json` in the Projects
root (only `links.production` and `links.api` of the matching project; other bytes
are untouched), then runs `node workspace-registry.mjs --validate`. If validation
fails the previous file is restored. It does not run `workspace:sync` and does not
commit; run `npm run workspace:sync` in the Projects root and commit the registry
and generated ProjectsDocs data yourself. A missing, unreadable or malformed
registry only removes the links from the menu.

### Registry links

`workspace.registry.json` projects accept optional `links.production` and
`links.api`: `https` URLs without embedded credentials, validated by
`workspace-registry.mjs --validate` (read-only, so it passes before `workspace:sync`
has run, unlike `--check`). `workspace:sync` copies them to ProjectsDocs, whose
project pages show them. The public ProjectsDocs build omits `*.ts.net` hosts
(for example RutinAI's Funnel URL); the private build keeps them.

## Install

```bash
git clone git@github.com:jorgedelacruz07/Switchboard.git Switchboard
cd Switchboard
./switchboard.sh configure /path/to/your/development/workspace
./switchboard.sh install
```

If this repository lives directly inside the development workspace, the parent
folder is detected automatically and the configure step is optional.

The installer builds and ad-hoc signs the app locally, keeps one application link at
`~/Applications/Switchboard.app`, installs the `switchboard` command and its `mini-bar` alias
in `~/.local/bin`, and opens the menu. Updates replace the stable bundle;
they do not create a versioned application copy. Exact old `Mini Bar.app` and
`Projects Menu.app` links to this bundle are removed. Login registration is a
separate explicit action.

Builds use ad-hoc signing by default. On a machine with an approved Apple code-signing
identity, set `codeSigningIdentity` in the ignored `.local/settings.json` to that
identity's exact name. Builds then verify the identity is available and sign only the
isolated staged bundle with it. Keep signing identities and machine settings out of Git.
It also connects the Claude quota status line when you do not already have one;
existing hooks and custom status lines are preserved. It preserves existing
regular files instead of overwriting them. Add `~/.local/bin` to your shell's PATH
if needed.

The menu bar icon shows the active-project counter described above. Select a project to access its actions.
**Start All** starts projects sequentially through your launcher. A memory-guard
failure leaves projects already running available and displays the result.
**Start All Projects** starts every launcher project, including the ones you hid in
**Configure Projects…**; hidden projects are neither listed nor counted.

## Login registration and controlled legacy migration

Switchboard uses Apple's [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
to configure this app itself at login on macOS 13+, with no helper daemon.
The menu toggle and CLI share one adapter. Status and menu refreshes read only;
only an explicit toggle, `login register` or `login unregister` mutates registration.
The Settings button opens Login Items only when clicked. Registration never retries
a denial, launches the GUI automatically, or bypasses macOS consent.

The diagnostic prints modern `enabled`, `requiresApproval`, `notRegistered`,
`notFound` or `unknown`, any error, and a separate legacy file/authorization result.
Only the confirmed modern enabled state checks the menu item. Pending approval,
missing service or errors cannot claim success. Diagnostic exit 0 means the read
succeeded, not that login is enabled. A mutation exits nonzero unless its requested
state is confirmed. A signed app bundle is required; test binaries use fake backends.
The CLI refuses an older/missing bundle without the login API capability marker;
it never builds or launches a GUI to obtain status.

Legacy migration is deliberately operator controlled. `login migration-plan` does
not boot out jobs, rename files, register services or open Settings. It recognizes
only our exact `~/Library/LaunchAgents/com.jorgedelacruz.projects-menu.plist`
symlink to this checkout's `.local/launchd/` plist with the exact known label,
executable, working directory and remaining configuration. Broken links, regular
files and changed content stay untouched and require manual inspection. Existing
legacy configuration blocks modern registration/unregistration and ordinary install.
Authorization from Apple's `statusForLegacyPlist` is not proof a legacy process is running.

After QA/AppSec review and approval for the actual rollout, the operator:

1. Records the diagnostic and exact existing label, symlink, generated plist and
   stable signed bundle; preserves recoverable copies of the old bundle and files.
2. Boots out only the existing user job at that exact label. If it fails, stops.
   Moves the recognized symlink outside `Library/LaunchAgents` to a preserved
   backup location; leaves its generated plist unchanged. No trust/BTM resets,
   label changes or security-check workarounds are part of migration.
3. Installs the reviewed bundle at its stable identity/path, checks `login status`,
   then explicitly invokes `login register` from that bundle. Verifies modern
   `enabled`. If [`requiresApproval`](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval) is returned, leave the pending registration
   intact while Jorge decides in Login Items. Do not auto-unregister, retry or
   roll back while waiting. This state can also mean consent was revoked; inspect
   Login Items and stop on ambiguity. Keep the app available through normal app
   launch only, without claiming login is enabled.
4. Rollback requires an explicit decision and a fresh, identity-verified service
   status. Stop if it is `notFound`, `unknown` or an error. If that decision calls
   for cancellation and the confirmed state permits it, unregister once and verify
   `notRegistered`; if already `notRegistered`, skip unregister. Only then review
   restoration of the previous bundle, preserved symlink and unchanged legacy
   plist. Every runtime step remains a separate controlled operation; this code
   does not execute that sequence.

For an executable update, inspect registration before replacing anything. Apple's
[SDK contract](https://developer.apple.com/documentation/servicemanagement/smappservice)
requires re-registration after changes to registered agent/daemon executables and
recommends unregistering first. Treat modern app updates conservatively too:
explicitly unregister, install the reviewed update at the stable path, re-register
and verify status in a controlled rollout. Do not infer that ad-hoc signing alone
will be accepted on either machine. No signing/trust relaxation is implemented.

## Staged builds and safe updates

`switchboard build --stage-only` compiles and signs a new bundle under a unique
`build/.stage-*/Switchboard.app`. It verifies the signature with
`codesign --verify --deep --strict` and reads back the identifier, executable,
workspace, checkout and login API version. It never executes that staged app for
login status, replaces the stable app, launches a GUI or changes registration.
Compiler output is signed only inside this new stage; existing signed files are
never overwritten or re-signed. Staged artifacts are retained for review.

Ordinary `build` and `install` then query **only** the stable
`build/Switchboard.app` through its read-only, identity-verified login API. They
refuse enabled, pending approval, not found, unknown or error states, any legacy
entry, an old/missing diagnostic API and a running Switchboard process. They do
not kill it. An absent stable app is also unknown: initial installation and
legacy bootstrap require a separate reviewed operator rollout from the staged
artifact, not an automatic exemption to this gate.

The diagnostic includes its actual bundle path, expected stable path and bundle
identifier. The native backend refuses status and mutations before touching
SMAppService when those identities do not match. A staging `--login status`
therefore returns unknown plus an identity error; it is never the installed
app's state. A capability marker alone is not accepted as proof of identity.

For an identity-capable modern installation, the controlled update sequence is:
explicitly `login unregister`, verify `login status` reports `notRegistered`,
quit Switchboard, then run the reviewed `build` or `install`. The updater checks
status and running state again at the replacement boundary. It exchanges the
complete staged and stable directories atomically on the same volume and keeps
the old signed bundle at the staging location for rollback. Failed signature or
metadata readback restores the previous complete bundle. Only after inspecting
the replacement should the operator explicitly `login register` and verify
`enabled`. On `requiresApproval`, preserve the pending registration while Jorge
checks Login Items and decides; consent may also have been revoked, so stop on
ambiguity. Do not automatically unregister or restore the bundle during that
wait. Normal app launch may keep Switchboard available, but it is not confirmed
login-enabled. Rollback needs a separate explicit decision, a fresh confirmed
state, at most one appropriate unregister and verification of `notRegistered`;
`notFound`, `unknown` or error means stop. No command chains registration into
build/install, and there is no force/unknown-state override.

Updates and native registration mutations share an exclusive lock in `build/`;
status reads do not mutate it. A stale lock stops the operation for inspection,
without an automatic retry or trust reset. This approach follows
[Apple's signed-code update guidance](https://developer.apple.com/documentation/security/updating-mac-software).
OS acceptance and actual migration must still be reviewed on each machine.

## Commands

```bash
mini-bar open
mini-bar usage             # sanitized, read-only AI usage JSON
mini-bar connect-claude    # connect the quota capture bridge
switchboard build --stage-only     # safe artifact preparation; no stable replacement
switchboard build                  # gated ordinary update; app stopped/unregistered
switchboard configure /path/to/workspace
switchboard workspace
switchboard login status          # read-only modern + legacy diagnostic
switchboard login migration-plan  # read-only; preserves legacy files
switchboard login register        # explicit modern registration (on alias)
switchboard login unregister      # explicit modern unregistration (off alias)
switchboard snapshot
switchboard test
```

Workspace selection during a build follows this order:

1. `PROJECTS_WORKSPACE_ROOT` environment variable.
2. The path saved by `switchboard configure`.
3. This repository's parent directory.

After changing the workspace, quit the menu and run `switchboard install` to apply
the new path. Quitting the menu does not stop your projects.

## AI usage sources

AI quota data is read by the resident AppKit process. Background quota refresh and
provider availability checks run every five minutes; manual refresh has a
one-minute cooldown. **Enable AI Usage** and **Enable Provider Status** pause their
own checks without closing project controls. No model prompts are sent to obtain
quota, and no browser, IDE, or agent is launched for monitoring.

| Provider             | Data                                                                                            | Boundary                                                                                                                       |
| -------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Claude Pro           | Five-hour and weekly quota captured from Claude Code's documented status-line JSON.             | Requires a Claude Code response after connecting the bridge; may lag use on the web.                                           |
| Codex / Plus         | Recent local Codex quota events, matched to the signed-in account.                              | No helper in background. Manual account refresh is available; other ChatGPT features have separate limits.                     |
| OpenCode Zen         | Recorded USD cost for `opencode` assistant messages in the local database, this calendar month. | Local recorded spend, not account balance or cross-device billing. Missing records show **No local activity**.                 |
| Gemini / Antigravity | Model quota from an already-running Antigravity IDE's loopback service.                         | IDE account/model quota, not Gemini web or weekly quota. Reset-only responses show the reset time with percentage unavailable. |

Provider availability is read from the `Features/ProviderStatus/` feature module.
The app runs its read-only JSON command as a short Node child process, so no
additional resident service is required. Checks use public endpoints, need no
provider credentials and can be paused independently from usage reads.

| Provider    | Public status source                   | Boundary                                             |
| ----------- | -------------------------------------- | ---------------------------------------------------- |
| Claude      | `status.claude.com`                    | Claude.ai, API and Claude Code components            |
| GPT         | `status.openai.com`                    | Relevant ChatGPT and Codex service components        |
| Antigravity | Google Cloud incidents                 | Approximation based on Gemini/Vertex AI incidents    |
| OpenCode    | OpenCode status and Zen model endpoint | `unknown` when status is stale or the endpoint fails |

The status CLI is part of the root Switchboard package: `npm run status` is
read-only; `npm run status:once` keeps confirmed transition state in the ignored
feature `.data/` folder and can send optional notifications when explicitly
configured. The app itself only shows observed public status and does not enable
a LaunchAgent or notifications.

The Claude bridge stores only validated quota windows, capture time, and a hashed
account binding in `.local/claude-usage.json` with private file permissions. It
never saves transcripts, session IDs, email addresses, or tokens. If you have a
custom status line, `connect-claude` preserves it and reports that the bridge is
not connected. A new Claude Code session may be needed to load the setting.

Codex background checks read at most twelve recent session files, with bounded
headers/tails. Their `creator_account_id` must match the current `auth.json`
account ID; unmatched sessions are skipped. Account IDs and credentials are never
persisted or transmitted by this path. Original event timestamps remain visible,
so inactive or remote-only usage can become stale.

**Codex → Refresh Account Now…** or `mini-bar usage-live` explicitly reads
`account/rateLimits/read` through a short-lived Codex app-server using its existing
sign-in. This can cause a temporary combined-memory spike above 50 MiB. It never
creates a thread or sends a model request. The helper has a 12-second response
deadline, bounded output, and termination/reaping on failure. Background refreshes
do not use this helper.

Antigravity's local CSRF token is read only in memory and sent only to its existing
`127.0.0.1` HTTP listener. Redirects are rejected. The app does not import browser
cookies, bypass TLS, launch the IDE, or store the token. This is an internal IDE
interface and may change; unsupported responses remain unavailable.

Each card identifies the source, last measurement, and reset times. Captures older
than 15 minutes or past a known reset are marked **stale**. Unknown quota is never
rendered as zero use or a full allowance. The app does not aggregate unlike quotas
into a single percentage. Open Usage Dashboard takes you to the provider's website.

References: [Claude Code status line](https://code.claude.com/docs/en/statusline),
[Codex app-server](https://learn.chatgpt.com/docs/app-server), and the
[Antigravity local-probe protocol notes](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md).

## Memory budget

The target is less than **50 MiB physical footprint at rest**. This is a measured
acceptance target, not a hard allocation cap. The menu displays its own current
footprint using Darwin task information. Read-only JSON snapshots stay in memory;
there is no history database, web runtime, background agent session, or model.
Only Claude's small sanitized capture is persisted.

Use the optional development sampler to include temporary child processes:

```bash
python3 scripts/profile-memory.py \
  --app "build/Switchboard.app/Contents/MacOS/Switchboard" \
  --seconds 30 --output .local/memory-profile.json
```

The sampler itself is temporary and is not installed or launched with the app.
It records main-process and combined child footprint peaks at roughly 0.1-second
intervals. Shorter spikes may be missed; use `vmmap -summary <pid>` to corroborate
the main process's lifetime peak. AI providers can be paused directly in the menu.

Validation on a 24 GiB M4 Pro Mac mini (2026-10-22): the default lightweight mode
settled around 20–23 MiB. A 20-second sample spanning the app restart recorded a
33 MiB peak; the new process's `vmmap` peak was 23 MiB at the follow-up check.
The optional direct Codex account read previously reached about 94 MiB combined
with its temporary children, which is why it is excluded from automatic checks.
These are observations on this machine, not universal memory guarantees.

Grouped menu and settings window, measured on 2026-11-03 on the MacBook Air in the
client role with the profiler above: a fresh launch settled near 30 MiB (36 MiB
peak). Opening **Configure Projects…** adds about 8 MiB while it is on screen;
after ten open/close cycles the process rested at about 38 MiB. During those cycles
the main peak was 46 MiB and the combined peak with temporary helper processes
48.5 MiB, only about 1.5 MiB below the 50 MiB target. The host role and **Save**
were not exercised manually.

A follow-up on 2026-11-04 sampled the installed app after about 11 hours of uptime:
`vmmap` reported 60.7 MiB current and 75.7 MiB lifetime peak physical footprint.
The 10-second sampler read 61.42 MiB at the end, 64.94 MiB sampled main-process
peak, and 67.11 MiB combined peak with a temporary helper. This long-running
process exceeded the target; it does not establish a fresh-launch baseline. AI
quota and provider probes now share a serial queue to avoid overlapping their
temporary allocations. Re-measure the rebuilt app after restarting it to assess
that change and its fresh at-rest footprint.

## Launcher contract

The launcher must support these arguments:

| Arguments               | Behavior                                                             |
| ----------------------- | -------------------------------------------------------------------- |
| `catalog`               | Print the project catalog as TSV and exit without starting services. |
| `<project-key>`         | Start one project.                                                   |
| `all`                   | Start all projects, applying any memory guard.                       |
| `kill <project-key>`    | Stop one project's development servers.                              |
| `kill all`              | Stop all managed development servers.                                |
| `restart <project-key>` | Restart one project.                                                 |

Each catalog row has four fields, with no header:

```text
project-key<TAB>relative-workspace-path<TAB>optional-api-port<TAB>web-port
```

The API field can be empty. The web port may also be empty for a process-backed
task that does not expose a network service. The app reports **Running** while
that launcher's PID is alive and does not offer a browser action. Project keys
must be unique.
For example:

```text
demo\tDemo\t3001\t5173
website\tWebsite\t\t5174
resume\tresume\t\t
```

The example uses literal `\t` markers for readability; the launcher emits actual tabs.
The project catalog is read from the launcher rather than copied into app settings.
The app passes `ROOT` (the workspace), `LOG_DIR` (`/tmp/project-dev-logs`), and
`NO_COLOR=1` to the launcher. It uses argument arrays rather than shell interpolation.

Optional launcher PID files are named `<project-key>-dev.pid`. Logs are named
`<project-key>-dev.log`. A live launcher missing declared ports appears as **Partial**.
Listening ports establish availability, not application-level health or process
ownership; the launcher remains responsible for managing the right processes.
For catalog rows without ports, the launcher PID is the process liveness signal.

## Development and validation

IdeaDesk integration verified on 2026-11-03, based on
`461d55e2bf71d87dad43d8056642e204ad2dc9a4`, with uncommitted changes in
`Sources/main.swift` and this README. Isolated tests cover service-port mapping,
generic-action rejection, private URL selection, healthy-service preservation,
LaunchAgent startup, health timeout and exit codes. `switchboard test` and the
signed app build passed. The same start command returned success against the
Mini without replacing its running process; the client snapshot reports
`state: on`, `webPort: 5180`, `liveSyncAlive: false`, without a tunnel dependency.
Mini Bar was rebuilt and reopened on the Air as a single process (18 MB current,
29 MB peak physical footprint in the observed session). Native UI automation
timed out; menu rendering was not inspected through that interface.

Grouped menu, counter, production links and settings window verified on 2026-11-03.
`switchboard test` passed (132 registry, link, model, registry-write and settings
checks, plus the launcher, private-portal and AI usage suites). In the Projects root,
`node --test workspace-registry.test.mjs` and `npm run workspace:check` passed; in
ProjectsDocs, `scripts/project-links.test.mjs` and `npm run lint` passed. The
client-role menu on the Air was inspected through macOS accessibility and screenshots:
the title and group headers, the project submenus with their production links, the
collapsed Archived group, and opening and cancelling the settings window. Not verified
manually: the host-role menu, **Save**, hidden-project counts at runtime, and
clicking the Open links.

```bash
./switchboard.sh test
./switchboard.sh build
./switchboard.sh snapshot
bash -n switchboard.sh install.sh
shellcheck -S warning switchboard.sh install.sh
git diff --check
```

Tests use temporary fixtures to verify catalog parsing, state detection, allowed
actions, argument forwarding, and error propagation. They do not need a configured
workspace or start, stop, or restart real projects. The test executable is built
separately from the installed application. `snapshot` is a read-only runtime check.

There are no automatic CI workflows. Build and validation run locally.

## Repository layout

```text
Sources/main.swift          CLI entry points and isolated self-test runner
Sources/AppDelegate.swift   Menu bar lifecycle, rendering, actions and refresh scheduling
Sources/ProjectController.swift Project models, catalog, runtime snapshots and launcher adapter
Sources/MenuModel.swift     Counter rule, grouping and per-Mac menu preferences
Sources/ProjectLinks.swift  Registry link parsing, URL validation, minimal registry edit
Sources/SettingsWindow.swift Configure Projects window
Sources/MenuTests.swift     Isolated counter, grouping, link and registry-write tests
Sources/AIUsage.swift       Bounded, read-only AI usage adapters
Sources/MemoryUsage.swift   Native physical footprint measurement
Sources/UsageTests.swift    Isolated quota/parser/IPC/database tests
Resources/Info.plist        Portable app bundle metadata
Tests/test_cli.py           Isolated workspace configuration tests
Tests/test_bridge.py        Isolated Claude settings integration tests
scripts/                   Claude capture bridge and temporary memory profiler
switchboard.sh             Build, configuration, and management commands
install.sh                  Home-directory symlinks and installation
build/                      Local binaries and app bundle (ignored)
.local/                     Workspace setting and preserved legacy files (ignored)
```

Machine-specific paths are written only to ignored generated files. No project
list, environment files, provider credentials, or workspace contents are committed.

## Troubleshooting

- **No menu icon:** run `switchboard open`. The app has no Dock icon or main window.
- **Status unavailable:** use **View Last Result** and `switchboard snapshot`.
- **Partial:** a required port is missing or the launcher is alive without ports.
  Check the project's logs, then use **Restart** if appropriate.
- **Start All stops early:** inspect the result. The launcher's memory guard may
  refuse additional projects; stop unused ones before retrying.
- **A tool works in Terminal but not in the menu:** check the runtime/tool paths
  listed above. GUI apps do not load interactive shell profiles.
- **Move or rename this checkout:** reinstall from its new location to refresh
  symlinks and the embedded workspace path. Inspect login status and follow the
  reviewed registration/update procedure separately; build/install does not register login.

Action output is available at `/tmp/project-dev-logs/menu-action.log`. Generated
files stay in the checkout; home-directory integrations are symlinks created by
the installer.
