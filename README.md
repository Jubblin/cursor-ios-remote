# Cursor iOS Remote

Remote-control your **local Cursor agent session** from your iPhone. Built for sofa coding and school-pickup steering — not cloud agent handoff.

## Architecture

```
iPhone (CursorRemote) ──LAN or Tailscale──▶ Mac (CursorBridge menu bar) ──AX/AppleScript──▶ Cursor IDE
```

- **Mac bridge** — menu bar app exposing HTTP + WebSocket on port `8742`
- **iOS app** — session status, approve/reject, follow-up prompts, agent session picker
- **Away from home** — use Tailscale MagicDNS hostname (no cloud handoff)

See [docs/spike-findings.md](docs/spike-findings.md) for why Cursor's official PWA / `agent worker` paths don't cover local IDE sessions.

## Quick start

### 1. Mac bridge

```bash
chmod +x scripts/*.sh
./scripts/build-bridge.sh
./scripts/run-bridge.sh
```

On first launch:

1. Grant **Accessibility** permission when prompted (required for approve/reject automation).
2. Click the menu bar icon — a **QR code** appears when the bridge is running. Scan it from the iOS app, or use **Copy pairing JSON**.
3. On iPhone: **Settings → Scan QR code** (or paste JSON manually).

**Install from release DMG:** download the matching DMG from [GitHub Releases](https://github.com/Jubblin/cursor-ios-remote/releases), open it, and drag **CursorBridge** to Applications.

Optional env vars:

| Variable | Default | Purpose |
|----------|---------|---------|
| `CURSOR_BRIDGE_PORT` | `8742` | API listen port |
| `CURSOR_BRIDGE_BIND` | — | Bind to a specific address (e.g. `127.0.0.1` or a Tailscale IP) |
| `CURSOR_BRIDGE_BIND_ALL` | `1` (implicit) | Set to bind `0.0.0.0` (default). Omit and use `CURSOR_BRIDGE_BIND` to restrict |
| `APNS_KEY_PATH` | — | APNs `.p8` key for push notifications |
| `APNS_KEY_ID` | — | Apple key ID |
| `APNS_TEAM_ID` | — | Apple team ID |
| `APNS_TOPIC` | — | iOS bundle ID (`com.cursorremote.app`) |

Token is stored at `~/.cursor-bridge/token.txt` (file mode `0600`). The menu bar UI shows only a token suffix; use **Copy pairing JSON** to transfer credentials to the iOS app.

### 2. iOS app

```bash
cd iOS
xcodegen generate
open CursorRemote.xcodeproj
```

In Xcode:

1. Select your **Development Team** for signing.
2. Build and run on your iPhone (or TestFlight).
3. Open **Settings** → **Scan QR code** (point at the Mac menu bar QR), or paste pairing JSON / enter hostname + token manually.
4. For school pickup: use your Mac's **Tailscale hostname** (e.g. `macbook.tailnet-name.ts.net`).

### 3. Tailscale (away from home)

1. Install Tailscale on Mac and iPhone.
2. Use the Mac's MagicDNS name as hostname in iOS Settings.
3. No inbound ports or Cloudflare needed if Tailscale covers both devices.

## API (Mac bridge)

All endpoints except `/health` require `Authorization: Bearer <token>`.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Bridge health check |
| GET | `/pairing` | Hostname, port, token |
| GET | `/agents` | Agent conversations across all projects |
| POST | `/agents/select` | `{"agentId":"..."}` — open session on Mac |
| GET | `/projects` | List workspace projects (legacy) |
| GET | `/projects/{id}/conversations` | List conversations for a project (legacy) |
| POST | `/conversations/select` | Open chat on Mac (legacy) |
| GET | `/session/status` | Current agent session state |
| POST | `/session/prompt` | `{"text":"..."}` — send follow-up |
| POST | `/session/approve` | Approve pending tool call |
| POST | `/session/reject` | Reject pending tool call |
| POST | `/devices/register` | Register APNs device token |
| WS | `/ws` | Live status updates |

Session states: `idle`, `running`, `awaiting_approval`, `unknown`, `error`.

## Push notifications (optional)

When the bridge detects `awaiting_approval`, it sends an APNs alert to registered devices.

1. Create an APNs key in Apple Developer portal.
2. Set `APNS_*` env vars before launching the bridge.
3. Enable push capability in Xcode (already in entitlements).
4. iOS app registers its token on launch.

## Agent sessions

The Mac bridge scans `~/.cursor/projects/*/agent-transcripts/` and maps each session to its Cursor workspace. On iOS:

1. Tap **Load agents** (or the reload icon).
2. Pick an **agent session** from the flat list.
3. Tap **Open on Mac** — the bridge opens that workspace in Cursor and selects the chat.

## Limitations

- Cursor's agent UI is closed source; automation uses Accessibility API and may break on Cursor updates.
- Approve/reject matches buttons titled Run, Accept, Approve, Skip, Reject, etc.
- Prompt delivery uses Cmd+I composer shortcut + paste — tune in `CursorAutomation.swift` if your keybindings differ.
- HTTP is unencrypted; use only on trusted LAN or Tailscale mesh.

## Security

- **Auth** — Bearer token required on all endpoints except `GET /health`. Comparison uses constant-time equality; failed attempts are rate-limited per client (HTTP 429).
- **Bind address** — By default the bridge listens on all interfaces (`0.0.0.0`) so your iPhone can reach it over Tailscale/LAN. Set `CURSOR_BRIDGE_BIND=127.0.0.1` to restrict to localhost, or set a specific Tailscale IP.
- **Request bodies** — Capped at 64 KB (HTTP 413).
- **Device registration** — iOS bundle ID must match `com.cursorremote.app`; at most 10 APNs device tokens per bridge instance.
- **Approve automation** — Approve only clicks a matching button (no Return-key fallback). Reject may still use Escape as a fallback.
- **iOS token storage** — Auth token is stored in the Keychain, not UserDefaults.

## Project layout

```
Bridge/           macOS menu bar + HTTP server (Swift)
iOS/              iPhone SwiftUI app
docs/             Spike findings and design notes
scripts/          Build and run helpers
Shared/           Shared protocol types (reference)
.github/          GitHub Actions (CI + release)
```

## CI

GitHub Actions runs on every push/PR to `main`:

1. **Lint** — SwiftFormat + SwiftLint (`--strict`)
2. **Mac bridge** — `swift build` (release + debug)
3. **iOS app** — XcodeGen + simulator build

Run locally:

```bash
brew install swiftlint swiftformat
./scripts/lint.sh      # check
./scripts/format.sh    # auto-fix formatting
```

Tag a release with `v*` (e.g. `v1.0.0`) to publish installable **DMG** packages on GitHub Releases (Apple Silicon and Intel).

Package locally:

```bash
./scripts/package-bridge-dmg.sh v1.0.0
```
