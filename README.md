<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square" alt="Swift 5.9">
  <img src="https://img.shields.io/github/license/Sunrise-Labs-Dot-AI/SubMaxxing?style=flat-square&color=34d399" alt="MIT License">
</p>

<h1 align="center">SubMaxxing</h1>

<p align="center">
  <strong>A macOS menu bar monitor for Claude and Codex usage.</strong><br>
  Quotas, session history, API-equivalent cost analytics, project breakdowns, and subscription-aware planning.
</p>

---

## What It Does

SubMaxxing helps you understand how much AI work you are routing through local tools, especially when usage is hidden behind subscription plans.

It currently tracks:

| Area | What you get |
|---|---|
| Claude usage | Session, weekly, Sonnet, Opus, and Claude Design quota windows from your existing Claude login |
| Codex usage | Codex-side quota windows plus analytics parsed from `~/.codex/sessions/**/*.jsonl` |
| Analytics | Today, 7-day, and 30-day API-equivalent costs, messages, tokens, cache hits, models, projects, and trends |
| Timeline | Claude session history with topic, duration, model, and cost estimates |
| ROI | Claude session-to-git analysis for local project work |
| Extensions | Claude Code plugin discovery and management |
| Menu bar | Compact status, live countdowns, activity rings, warnings, and a global `Option-Command-C` toggle |

## Important: Analytics Are API-Equivalent

SubMaxxing's cost analytics answer a specific question:

> What would this usage have cost if it had been billed at published API token rates?

That is not always the same as your actual bill.

If you are using Claude Pro, Claude Max, ChatGPT Plus, Codex, or another subscription to fund most of this activity, the analytics should be read as API-equivalent replacement value or opportunity cost. They are useful for understanding volume, model mix, cache impact, project concentration, and whether a subscription is absorbing work that would otherwise be expensive at API rates.

For Claude, the app also shows subscription and extra-usage planning where data is available. For Codex, transcript analytics currently use OpenAI API-equivalent pricing because local Codex session files expose token usage, not subscription allocation or true marginal cost.

## Fork Acknowledgement

SubMaxxing is a fork of [Claude God](https://github.com/Lcharvol/Claude-God) by Lucas Charvolin.

The original project established the macOS menu bar app, Claude quota monitoring, Claude session analytics, timeline, ROI, extensions UI, widget support, and much of the SwiftUI foundation. This fork keeps that work intact while adapting the product direction, branding, repository ownership, and adding Codex-side analytics.

The project remains MIT licensed. See [LICENSE](LICENSE).

## Quick Start

### Install

The public release flow is still being cleaned up after the fork. For now, build from source:

```bash
git clone https://github.com/Sunrise-Labs-Dot-AI/SubMaxxing.git
cd SubMaxxing
brew install xcodegen
make install
```

`make install` builds the app, installs it to `/Applications/SubMaxxing.app`, signs it locally, and launches it.

### Sign In

For Claude quota data:

```bash
claude login
```

For Codex analytics, no extra sign-in is required. SubMaxxing reads local Codex session transcripts from:

```text
~/.codex/sessions/**/*.jsonl
```

Open the menu bar app with the `S`/`SM` icon or press `Option-Command-C`.

## How It Works

### Claude Quotas

SubMaxxing reads your Claude OAuth credentials from Keychain or `~/.claude/.credentials.json`, then calls the Claude usage endpoint:

```text
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_token>
anthropic-beta: oauth-2025-04-20
```

It displays returned quota windows such as `five_hour`, `seven_day`, `seven_day_sonnet`, and `seven_day_opus`, with reset timers and threshold warnings.

### Claude Analytics

Claude analytics parse local session files under:

```text
~/.claude/projects/**/*.jsonl
```

The parser estimates API-equivalent costs from token usage and published Anthropic model pricing, then aggregates by day, model, and project.

### Codex Analytics

Codex analytics parse local transcript files under:

```text
~/.codex/sessions/**/*.jsonl
```

The parser reads `token_count` events, uses `payload.info.last_token_usage`, accounts for cached input tokens separately, derives project names from working directories, and prices usage with OpenAI API-equivalent model rates. Unknown Codex models fall back to GPT-5 pricing and log a warning.

## Development

Common commands:

```bash
make build     # Build Release
make run       # Build and run from the build directory
make install   # Build, install to /Applications, sign locally, and launch
make clean     # Remove generated build artifacts
```

The Xcode project is generated from `project.yml`; do not edit `SubMaxxing.xcodeproj` by hand.

## Project Structure

```text
Sources/
├── SubMaxxingApp.swift       # App entry point and MenuBarExtra
├── MenuBarView.swift         # Main SwiftUI popover UI
├── UsageManager.swift        # Claude quotas, refresh, budgets, notifications
├── CodexUsageManager.swift   # Codex quotas and analytics refresh
├── SessionAnalyzer.swift     # Claude JSONL parser and pricing helpers
├── CodexSessionAnalyzer.swift # Codex JSONL parser
├── AuthManager.swift         # Claude credential loading and token refresh
├── RingImageMaker.swift      # Menu bar activity-ring image renderer
└── Assets.xcassets/          # App icon assets

Widget/
└── SubMaxxingWidget.swift    # WidgetKit desktop quota gauges
```

## Notes

- The app is local-first and reads local session files for analytics.
- API-equivalent cost estimates are designed for planning and comparison, not accounting.
- No new runtime dependencies are required beyond Apple's frameworks.
- Release metadata and distribution links are still being reconciled after the fork.

## License

[MIT](LICENSE)
