# Handoff: Seamless auth for SubMaxxing (kill the copy-paste flow)

## Problem

When the Claude session token expires, SubMaxxing's reconnect flow currently:
1. Runs `claude auth login` in an embedded PTY (now via interactive login shell, so `node` resolves).
2. Auto-opens the OAuth authorize URL in the browser (via `NSWorkspace`).
3. The Claude CLI uses a **hosted callback** (`redirect_uri=https://platform.claude.com/oauth/callback`), which means the user must **copy an authorization code from the browser and paste it back** into the CLI prompt.

The embedded terminal was read-only; that's been fixed (it now has an input field). But the underlying UX — copy a code, paste it into a terminal — is unacceptable. Users shouldn't touch auth codes at all.

**Goal: re-auth should be seamless. No manual code copy-paste. Ideally, no visible re-auth at all most of the time.**

## Solution priority (do them in this order)

### 1. PRIMARY — Proactive token refresh (avoid re-auth entirely)

The keychain credential JSON contains a `refreshToken` and `expiresAt`. Most "session expired" events should never happen if SubMaxxing refreshes the access token *before* it expires.

- Keychain service: `Claude Code-credentials` (plus sharded variants `Claude Code-credentials-<hex>` — see `AuthManager.loadFromKeychain` / the sharded-enumeration logic added in commit `b0213ab`).
- Credential JSON shape:
  ```json
  { "claudeAiOauth": { "accessToken": "...", "refreshToken": "...",
                       "expiresAt": <ms-epoch>, "subscriptionType": "..." } }
  ```
- Token endpoint (already referenced in `AuthManager` as `oauthTokenURL`): `https://platform.claude.com/v1/oauth/token`
- Refresh request: `POST` with `grant_type=refresh_token`, `refresh_token=<...>`, `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e` (client_id observed in the authorize URL).

**Tasks:**
- Audit the existing refresh path: `UsageManager` has `tokenHealthTimer` + `isRefreshingToken`, and `AuthManager` exposes `refreshToken`. Determine why a refresh isn't already preventing the expired state. Likely candidates: (a) refresh never actually POSTs to the token endpoint, (b) refresh fires too late (after expiry), (c) the refreshed token isn't written back to the keychain in the format Claude Code expects, so the next read is stale.
- Implement/repair: schedule a refresh at e.g. `expiresAt - 5min`. On success, write the new token back to the keychain entry (same `claudeAiOauth` JSON shape) AND update in-memory state. Verify Claude Code itself still reads the refreshed credential (don't corrupt the entry).
- If refresh succeeds, the user sees nothing — the meter just keeps working. This eliminates ~all routine re-auths.

### 2. FALLBACK — Native PKCE OAuth with localhost loopback (when refresh fails)

When the refresh token itself is expired/revoked, a full re-auth is unavoidable — but it can still be paste-free. Implement the OAuth flow natively in the app instead of shelling out to `claude auth login`:

- Generate PKCE `code_verifier` + `code_challenge` (S256).
- Start a local HTTP listener on `http://127.0.0.1:<random-port>/callback` (use `Network.framework` `NWListener` or a tiny `NWConnection` accept loop).
- Open the authorize URL in the browser with `redirect_uri=http://127.0.0.1:<port>/callback`, `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`, `response_type=code`, `code_challenge`, `code_challenge_method=S256`, and the scopes observed in the live URL: `org:create_api_key user:profile user:inference user:session...` (capture the full scope list from an actual `claude auth login` authorize URL before implementing).
- Browser redirects to the localhost callback after approval → app captures `code` from the query string automatically (no paste).
- Exchange `code` + `code_verifier` at `https://platform.claude.com/v1/oauth/token` (`grant_type=authorization_code`) → get access + refresh tokens.
- Write them to the keychain in the `claudeAiOauth` shape so both SubMaxxing and Claude Code read them.

**Open question to resolve first:** does Anthropic's OAuth client allow a `http://127.0.0.1` / `localhost` loopback redirect for this client_id? Loopback redirects are standard for native OAuth (RFC 8252) and most providers allow them even when a hosted callback is the default. Test by constructing the authorize URL with a localhost redirect_uri and seeing if the consent screen accepts it. If the client_id rejects loopback redirects, this approach is blocked and you fall back to option 3.

**Also check:** does `claude auth login` (or `claude setup-token`) have a flag for a loopback/automatic callback or a non-interactive token mint? If the CLI can do the loopback dance itself, driving it (instead of reimplementing OAuth) is lower-risk. `claude auth login --help` / `claude setup-token --help`.

### 3. LAST RESORT — keep the embedded-terminal paste flow

Already implemented (input field + native URL open). Leave it as the final fallback if both refresh and native PKCE are unavailable, but it should rarely if ever be hit.

## Constraints / cautions

- **ToS gray area:** SubMaxxing already reads Claude Code's OAuth credentials from the keychain and calls `api.anthropic.com/api/oauth/usage`. Reusing the Claude Code `client_id` for a native OAuth flow extends that. Flag this to the user; it's their call whether to ship it publicly. Keep the CLI-driven flow available as the "official" path.
- **Don't corrupt the keychain entry.** Claude Code reads the same entry. Preserve the exact JSON shape and all fields (don't drop `subscriptionType`, `expiresAt`, etc.). Round-trip test: refresh via SubMaxxing, then confirm `claude` CLI still works without re-login.
- **Sharded keychain:** writes must target the same entry the CLI reads. See the sharded enumeration in `AuthManager` (commit `b0213ab`). Determine which entry is canonical for writes.
- Security: never log tokens or auth codes. The user pasted auth codes into a chat twice during this session — the app should make codes invisible to the user entirely.

## Key files

- `Sources/AuthManager.swift` — credential loading (disk + sharded keychain), `oauthTokenURL`, `refreshToken`.
- `Sources/UsageManager.swift` — `launchAutoReconnect()` (~line 1648), `tokenHealthTimer`, `isRefreshingToken`, `startReconnectPolling()`, `reconnectURLObserver`.
- `Sources/TerminalSession.swift` — embedded PTY (`send(_:)` for input).
- `Sources/MenuBarView.swift` — `EmbeddedTerminalView` (input row).

## Definition of done

- Routine token expiry is invisible: proactive refresh keeps the meter live with zero user interaction.
- When a true re-auth is needed, it's one click → browser → approve → done. No code copy-paste anywhere.
- `claude` CLI still works after SubMaxxing refreshes/writes credentials (no keychain corruption).
- Build via `make install`; verify against a real expiry if possible, otherwise document what couldn't be tested live.

## Repo

- Local: `~/Documents/Claude/Projects/SubMaxxing`
- Remote: `Sunrise-Labs-Dot-AI/SubMaxxing` (public)
- Build/run: `make install` (builds, re-signs ad-hoc, replaces `/Applications/SubMaxxing.app`, relaunches)
