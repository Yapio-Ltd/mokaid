# API Reference

Base URL: `http://localhost:4000/api` (dev). All responses are JSON envelopes: `{"data": ...}` or `{"error": {"code", "message"}}`.

## Authentication

- Dev: `POST /api/auth/login` with `{"email", "password"}` → `{"data": {"token", "user"}}`. Send `Authorization: Bearer <token>`.
- Production: Cognito JWT (access token) in the same header; the API validates via JWKS and maps `cognito_sub` to a user.
- Workspace scoping: all workspace routes are nested under `/api/workspaces/:workspace_id/...` and require membership.

## Endpoints (summary)

### Auth & session
| Method | Path | Description |
|---|---|---|
| POST | `/auth/login` | Dev login (email/password) |
| GET | `/auth/me` | Current user + memberships |

### Workspaces
| GET | `/workspaces` | List my workspaces |
| GET/PATCH | `/workspaces/:id` | Read / update settings |

### Agents
| GET | `/workspaces/:wid/agents` | List (filters: `kind`, `status`, `q`) |
| POST | `/workspaces/:wid/agents` | Create |
| GET/PATCH/DELETE | `/workspaces/:wid/agents/:id` | Read / update / archive |
| POST | `/workspaces/:wid/agents/:id/status` | Change status |

### Tasks
| GET | `/workspaces/:wid/tasks` | List (filters: `status`, `assignee`, `project_id`, `q`) |
| POST | `/workspaces/:wid/tasks` | Create |
| GET/PATCH/DELETE | `/workspaces/:wid/tasks/:id` | CRUD |
| POST | `/workspaces/:wid/tasks/:id/status` | Move (Kanban) |
| POST | `/workspaces/:wid/tasks/:id/comments` | Comment |
| POST | `/workspaces/:wid/tasks/:id/run` | Execute with AI |
| POST | `/workspaces/:wid/approvals/:id/decision` | Approve / reject an AI action |

### Projects, Knowledge, Drive, Calendar, Members, Integrations, Billing, Analytics
Standard REST collections following the same pattern; see `apps/api/lib/mokaid_web/router.ex` for the authoritative list.

### Worker callbacks (`Authorization: Bearer <WORKER_AUTH_TOKEN>`)
| POST | `/worker/runs/:id/status` | Status transition |
| POST | `/worker/runs/:id/approval` | Request human approval |
| POST | `/worker/runs/:id/complete` | Final output |
| POST | `/worker/runs/:id/fail` | Error report |

## Realtime (WebSocket)

Connect to `/socket` with `{"token": <auth token>}` params.

| Topic | Events |
|---|---|
| `workspace:{id}` | `agent.status_changed`, `task.created`, `task.status_changed`, `run.waiting_approval`, `member.presence` |
| `task:{id}` | `comment.created`, `subtask.updated`, `run.step` |
| `notifications:{user_id}` | `notification.created` |

## Errors

| Code | Meaning |
|---|---|
| 401 | Missing/invalid token |
| 403 | Not a member / missing permission |
| 404 | Not found in this workspace |
| 422 | Validation errors (`errors` map) |
| 429 | Rate limited |
