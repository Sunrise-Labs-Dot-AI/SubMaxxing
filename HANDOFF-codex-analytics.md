# Handoff to Codex — SubMaxxing Codex Analytics tab + tab stubs

You are working on **SubMaxxing**, a macOS menu bar app that tracks Claude (Anthropic) and Codex (OpenAI) usage side-by-side. The Claude side has full tabs (Usage / Analytics / Timeline / ROI / Extensions). The Codex side currently only has the Usage panel. **Your job is to add Codex-side support for the other tabs.**

## Repo

- GitHub: `Sunrise-Labs-Dot-AI/SubMaxxing` (public)
- Local: `~/Documents/Claude/Projects/SubMaxxing`
- Branch: `main`
- Build: `make install` from the repo root (xcodegen → xcodebuild → ad-hoc codesign → /Applications)

Clone fresh if you don't have it:
```bash
git clone https://github.com/Sunrise-Labs-Dot-AI/SubMaxxing.git ~/Documents/Claude/Projects/SubMaxxing
cd ~/Documents/Claude/Projects/SubMaxxing
brew install xcodegen   # if missing
make install
```

## Architecture

Read these first to orient:
- `CLAUDE.md` — repo dev guidelines (functional Swift, no force unwraps, `enumerateLines` for big JSONL)
- `Sources/SubMaxxingApp.swift` — entry point
- `Sources/UsageManager.swift` — Anthropic side: state, OAuth API, quotas, projections, bill estimate
- `Sources/CodexUsageManager.swift` — OpenAI side: parallel to UsageManager, reads `~/.codex/auth.json` + `chatgpt.com/backend-api/wham/usage`
- `Sources/SessionAnalyzer.swift` — Claude JSONL parser, pricing, cost calc, daily aggregations. **You will write a parallel parser for Codex.**
- `Sources/MenuBarView.swift` — all SwiftUI. Side-by-side layout: `claudeContent` (left, tab-driven), `codexUsageView` (right, always visible). You will extend the right column to switch by tab.

## Scope (in priority order)

### 1. Codex JSONL parser — `Sources/CodexSessionAnalyzer.swift` (NEW FILE)

Mirror `SessionAnalyzer` but for OpenAI Codex CLI transcripts.

- **Input directory:** `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`
- **JSONL line schema** (differs from Claude — verify by reading a few lines):
  - Each line is one event
  - Keys to look for: `type`, `timestamp`, `payload` (or similar nested object containing token usage)
  - Token usage fields typically: `prompt_tokens`, `completion_tokens`, `total_tokens`, `cache_read_tokens` (if present)
  - Model field: somewhere in the payload, look for `model` containing strings like `gpt-5`, `gpt-5-codex`, `gpt-4o`, `o4-mini`
- **Reference implementation in Python** (don't depend on, but useful to study the parse logic): the `codex-cli-usage` PyPI package. `pip download codex-cli-usage` then inspect the wheel for parsing patterns.
- **Pure static parsing function** (per CLAUDE.md style): take a file path, return `(messages, tokens, cost)` per session.

### 2. OpenAI pricing constants — extend `Sources/SessionAnalyzer.swift` or new file

Add a `ModelPricing.codexPrice(for: String) -> Price` (or a new `OpenAIModelPricing` enum) covering current rates:

| Model substring | Input $/M | Output $/M | Cache read $/M |
|---|---|---|---|
| `gpt-5` (non-codex) | 1.25 | 10.00 | 0.125 |
| `gpt-5-codex` | 1.25 | 10.00 | 0.125 |
| `gpt-4o` | 5.00 | 20.00 | 2.50 |
| `gpt-4o-mini` | 0.15 | 0.60 | 0.075 |
| `o4-mini` | 1.10 | 4.40 | 0.275 |
| `o3` | 2.00 | 8.00 | 0.50 |

**Verify rates** against OpenAI's current pricing page before shipping — these are point-in-time and shift. Use a fallback to `gpt-5` pricing for unknown models with a log warning.

### 3. Wire results into `CodexUsageManager`

Expose:
```swift
@Published var todayStats: UsageStats
@Published var weekStats: UsageStats
@Published var monthStats: UsageStats
```

Reuse the existing `UsageStats` struct from `SessionAnalyzer.swift` (`totalCost`, `totalTokens`, `totalMessages`, `sessionCount`, `byModel`, `daily`, `byProject`). You may need to adapt `ProjectUsage` — Codex sessions don't have a clean "project" concept like Claude does. Either skip `byProject` or derive from `cwd` if present in the JSONL.

Run the scan on a background queue (`DispatchQueue.global(qos: .userInitiated)`) on app launch and on a refresh timer (every 5 min, similar cadence to Claude side). Use `enumerateLines` for streaming (the JSONL files can be large).

### 4. `codexStatsView` in `MenuBarView.swift`

Side-by-side replica of `statsView` (the Claude Analytics view) backed by Codex data.

- Reuse `SHCard`, `SHStatCard`, `BurnRateProjectionRow` etc. — they're provider-agnostic
- Top cost cards: Today / 7d / 30d, formatted as `formatCost($)` with message counts
- Per-model breakdown row (similar to `monthSpendBreakdown` for Claude)
- Skip the budget bar, monthly forecast, project budgets — those are Claude-specific
- Skip the weekly comparison + heatmap — out of scope for v1

### 5. Tab routing on the Codex side

Currently the right column always shows `codexUsageView`. Change so it switches based on `manager.selectedTab`:

| `selectedTab` | Right column shows |
|---|---|
| `.usage` (default) | `codexUsageView` (no change) |
| `.analytics` | `codexStatsView` (new, from above) |
| `.timeline` | `codexTimelineStub` — small "Codex timeline coming soon" card with a brief explanation |
| `.roi` | `codexROIStub` — "ROI tracking is Claude-specific (correlates with git commits)" |
| `.extensions` | `codexExtensionsStub` — "Extensions are Claude-specific (MCP servers, skills, plugins)" |

Find the `HStack` in `MenuBarView.swift`'s `body` that wraps `claudeContent` + `SHVerticalDivider()` + `codexUsageView`. Replace `codexUsageView` with a tab-routed `@ViewBuilder` like `claudeContent` is.

### 6. Acceptance

- `make install` builds clean without errors
- App relaunches, click Analytics tab → right column shows the new Codex stats view with your real Codex usage numbers (today/7d/30d cost cards populate from your `~/.codex/sessions/`)
- Click Timeline / ROI / Extensions → right column shows the stub card matching the table above (not the old Codex usage panel)
- Click back to Usage → right column shows the existing Codex usage panel
- No regression on the Claude side

## Constraints

- Match the existing code style in `CLAUDE.md`: functional, value types, no force unwraps, `print("[SubMaxxing] ...")` for logging.
- Don't introduce new dependencies (no SwiftUI third-party libs, no new MCP integrations).
- All UI strings: keep tone consistent with the existing app (terse, direct, no marketing copy).
- Commit each logical step separately (parser → pricing → manager wiring → view → tab routing). Use imperative-mood messages explaining the "why."
- Test by running `make install` after each commit and visually verifying.

## Final step

When done, push to `origin/main` (= `Sunrise-Labs-Dot-AI/SubMaxxing`) and report back with:
- Commit SHAs for each step
- Screenshot of the new Codex Analytics tab populated with real data
- Any deviation from the spec above + the reasoning
