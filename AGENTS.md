# Switchboard

This is the single repository for the Switchboard macOS app and its AI provider
status engine. Run app commands from this directory. The parent Projects
repository owns the external development launcher; do not copy that launcher or
personal machine configuration into this repo.

- Keep the UI, CLI output, comments, documentation, and commit messages in English.
- Use native AppKit; keep the app small and avoid a web server or Electron runtime.
- RAM is a primary acceptance criterion: target less than 50 MiB physical footprint
  at rest. Measure current and peak footprint, plus transient helper processes.
  Keep a single resident app; AI checks run at most every five minutes in the
  background. Never start an IDE, browser, or model request to obtain usage.
- Use only sanitized quota snapshots. Preserve stale/unavailable states and source
  boundaries: Codex quota, Claude Code captures, local Zen spend, and Antigravity
  model quota are different metrics. Do not turn missing fields into zero usage.
- AI provider availability is a Switchboard feature in
  `Features/ProviderStatus/`, not a nested project. Its Swift adapter, Node
  probes, tests and integration notes live together; the root `package.json`
  owns Node commands. The app runs the read-only JSON command every five
  minutes. Keep state under the ignored feature `.data/` directory and
  preserve `unknown` states and source boundaries. Do not enable notifications
  or a separate LaunchAgent automatically.
- The Claude bridge may add a status line only when none exists; preserve existing
  user hooks and status-line customizations. Never persist tokens or transcripts.
- Treat `project-dev.sh` as an external adapter. Read its `catalog` output instead
  of maintaining another project list. Preserve its memory guard and exit codes.
- The bundle ID and legacy LaunchAgent label `com.jorgedelacruz.projects-menu`
  are stable OS identifiers kept from before the Switchboard rename. Do not
  rename them without a reviewed login-item migration.
- Run `./switchboard.sh test` for isolated tests. Do not start, stop, or restart
  real projects just to test a change. `snapshot` is a read-only runtime check.
- Keep machine-specific paths, settings, LaunchAgents, binaries, and logs out of git.
  Generated settings live in `.local/`; compiled bundles live in `build/`.
- Use `install.sh` for home-directory symlinks. Preserve existing regular files.
- The Mini holds authoritative product working files, Git operations, dev servers
  and agents. The Air is a thin client using Cursor Remote SSH and loopback
  tunnels. Client Start Remote Work calls the parent `project-remote.sh work <key>`
  with `NO_OPEN=1`, without sync or Git reconciliation. Baton ownership must not
  gate remote start. Do not expose source-transfer, Align or local Git-write
  actions in the client remote-work flow. Existing legacy handoff helpers remain
  outside this flow; never invoke them automatically.
- Resolve project directories from the existing launcher catalog. Open the remote
  directory on host `macmini` through Cursor, with safe shell quoting for SSH and
  literal process arguments for the editor; preserve nonzero failure status.
- Installed apps are separate from source checkouts. Never install or restart
  either machine's app as part of isolated tests.
- Do not commit or alter unrelated work in the parent repository or other projects.
- Do not add CI, cloud infrastructure, telemetry, credentials, or dependencies
  without a task that needs them. Build and test locally.

- Login registration uses `SMAppService.mainApp` through the shared Swift adapter.
  Refresh, status and migration-plan must remain read-only. Tests inject a fake
  backend: never register/unregister real login items or open Settings in tests.
- Keep build/install separate from explicit login registration. Preserve macOS
  approval/error states and refuse automatic retries or GUI launches after denial.
  Legacy migration only recognizes the exact own plist/symlink and reports a
  reversible operator plan; preserve files and all signing/BTM/trust protections.

- Build/sign/verify isolated staged bundles; never rewrite signed installed code
  in place. Ordinary replacement requires identity-verified stable app status
  `notRegistered`, no legacy entry and no running app. Refuse unknown/approval/
  error states; stage diagnostics are not installed-app diagnostics. Preserve the
  complete old bundle through atomic exchange; never auto-register, kill or retry.
