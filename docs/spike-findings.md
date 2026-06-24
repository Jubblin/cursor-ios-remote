# Spike Findings: Cursor Official Remote Paths

Date: 2026-06-23

## Summary

**Approach A (probe Cursor first) does not solve local IDE session remote control.** The official remote/mobile paths target **cloud agents**, not the in-progress agent session in the desktop Cursor app.

Custom Mac bridge + iOS app (Approach C → B) is required.

## What Was Tested

### 1. `cursor.com/agents` PWA

| Capability | Local IDE session? |
|------------|-------------------|
| View agent status | No — cloud agents only |
| Approve tool calls | No — different agent runtime |
| Send prompts | No — spawns cloud sessions |
| Continue desktop chat | No |

**User verdict:** Already tried; does not connect to local session.

### 2. `agent worker start` / My Machines (Cursor docs)

Documented at [cursor.com/docs/cloud-agent/my-machines](https://cursor.com/docs/cloud-agent/my-machines).

| Capability | Local IDE session? |
|------------|-------------------|
| Runs tool calls on your Mac | Yes — but only for **cloud agent** sessions |
| Agent loop location | Cursor cloud (not local IDE) |
| Inbound ports required | No — outbound HTTPS only |
| Control from phone | Via cursor.com/agents dashboard |

The worker connects **your machine as an execution environment** for cloud-initiated agents. It does **not** expose or mirror the agent panel you have open in Cursor IDE.

**Installed CLI:** `~/.local/bin/cursor-agent` v2025.08.27 — `worker` subcommand only has `ping`, `kill`, `sleep` (local Unix socket at `~/.cursor/projects/<project>/worker.sock` when IDE session active). No `worker start` in this build; cloud worker `start` is documented separately and requires dashboard enablement.

### 3. `cursor-agent worker ping`

```
Failed to ping worker: connect ENOENT .../worker.sock
```

Socket is project-scoped and only present when Cursor has an active worker for that project. Not an HTTP API suitable for iOS clients.

### 4. Cloud Agent API (`POST api.cursor.com/v0/agents`)

Spawns new cloud agents against a GitHub repo. Does not attach to an existing local IDE session.

## Gap Matrix (what we must build)

| Need | Official path | Custom bridge |
|------|---------------|---------------|
| Steer **same** local session from sofa | Missing | Required |
| Approve tool calls remotely | Missing for local | UI automation / AX API |
| Send follow-up prompt | Missing for local | AppleScript + keystrokes |
| Access away from home | N/A | Tailscale / Cloudflare to bridge |
| Push when approval needed | Missing | APNs from Mac bridge |

## Recommendation

Proceed with **CursorBridge** (macOS menu bar + HTTP/WebSocket on port 8742) and **CursorRemote** (iOS SwiftUI). Integration surface: Accessibility API + AppleScript against the Cursor app process.

## Risks

- Cursor agent UI is closed source; automation may break on updates.
- Accessibility permission required on Mac (`System Settings → Privacy → Accessibility`).
- APNs requires Apple Developer account for device push outside foreground app.
