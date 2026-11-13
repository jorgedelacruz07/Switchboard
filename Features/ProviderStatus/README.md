# Switchboard provider status engine

This Node 26 feature module is part of the Switchboard repository. The Swift menu-bar
app runs `status --json` every five minutes to show public provider availability.
It uses native Node modules, makes no model requests and needs no provider keys.

## Commands

Run commands from the `Switchboard` repository root:

```bash
npm run status                 # live, read-only check; no state writes or alerts
npm run status:json            # JSON consumed by the Swift app
npm run status:once            # compare against feature state and emit transitions
DRY_RUN=1 npm run status:once  # print transitions without notifications
npm test                       # local fixtures only
```

## Sources and limits

| Provider    | Source                                 | Boundary                                          |
| ----------- | -------------------------------------- | ------------------------------------------------- |
| Claude      | `status.claude.com`                    | claude.ai, API and Claude Code components         |
| GPT         | `status.openai.com`                    | ChatGPT and Codex components used by the app      |
| Antigravity | Google Cloud incidents                 | Approximation based on Gemini/Vertex AI incidents |
| OpenCode    | OpenCode status and Zen model endpoint | Unreliable or stale data remains `unknown`        |

The app displays the observed state. The CLI's `once` command separately confirms
transitions: two consecutive problem checks are required; recovery remains stable
for ten minutes. An unknown check preserves the confirmed state and interrupts
pending streaks. A changed or unexpected response must not be reported as healthy.

## Optional notifications

`once` can send native macOS, Telegram or Home Assistant notifications when its
environment explicitly enables them. Secrets are injected from Doppler per
process; never store them in this repository. `DRY_RUN=1` suppresses all sends.

The Home Assistant bridge reference remains under `integrations/homeassistant/`. There is no
LaunchAgent template: Switchboard owns the interactive polling, while the CLI's
transition command can be run manually when notifications are explicitly wanted.

## Local state and development

`Features/ProviderStatus/.data/`, logs, `.env` files and secrets are ignored.
`status` does not create state; `status:once` saves its transition ledger there.

Node 26 is managed by mise. `npm ci` installs Prettier for development only.
`npm run lint` checks syntax and formatting; `npm run quick` also runs the local
test suite. The application calls only `status --json` and never invokes
`once` automatically.
