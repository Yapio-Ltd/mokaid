# Realtime

mokaid uses Phoenix Channels over WebSocket for all real-time features.

## Connection

- Endpoint: `wss://<host>/socket` (local: `ws://localhost:4000/socket`).
- Auth: the client passes its bearer token as a socket param; `UserSocket.connect/3` validates it and assigns `user_id`.
- Reconnection/backoff is handled by the `phoenix` npm client; queries re-sync on reconnect via TanStack Query invalidation.

## Topics

| Topic | Joined by | Purpose |
|---|---|---|
| `workspace:{workspace_id}` | every member on app load | workspace-wide events + Presence |
| `task:{task_id}` | task detail panel | granular task updates |
| `agent:{agent_id}` | agent profile panel | live status/schedule |
| `notifications:{user_id}` | topbar | personal notifications |

Membership is verified at join time (same rules as the REST API).

## Events (compact payloads)

Events carry IDs and minimal fields; clients refetch details when needed.

```json
{ "event": "agent.status_changed", "agent_id": "…", "status": "busy", "task_id": "…" }
{ "event": "task.status_changed", "task_id": "…", "from": "todo", "to": "in_progress", "actor_id": "…" }
{ "event": "run.waiting_approval", "run_id": "…", "task_id": "…", "tool": "send_email", "risk": "high" }
{ "event": "notification.created", "id": "…", "kind": "approval_request" }
```

## Presence

`MokaidWeb.Presence` tracks users on the workspace topic with `{status, joined_at}` metadata. The frontend derives online/away/offline indicators and feeds the 3D office avatar states.

## 3D bridge

The Babylon layer never talks to the socket directly. Events update Zustand/TanStack Query state; `OfficeCanvas` maps agent statuses to `AgentVisualState` (13 states) and pushes them into the scene with `updateAgents()` — no React re-render of the canvas.
