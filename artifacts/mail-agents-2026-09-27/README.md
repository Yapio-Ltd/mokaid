# Workspace Mail agent validation — 27 September 2026

The combined worker suite passed **236 tests**. [Recorded output](worker-tests.txt) includes the original 213-test integration batch plus 23 regressions for mailbox inventory evidence and private capability renewal. Five existing PyMuPDF/SWIG deprecation warnings remain. Ruff and `git diff --check` passed for the final changes.

The fixtures exercise private API callbacks, actor binding, token exclusion, pagination and body limits, conversation routing, real attachment receipts, partial failure handling, delegation rules and recovery. Listing accounts satisfies only an explicit inventory/access question; message questions require an actual search/read. A zero-match cached search creates no attachment and reports the synchronization limitation. Managed authorization replaces stale Mail capabilities only after a successful live authorization response.

Persisted execution contexts may renew a denied capability once through the authenticated refresh endpoint and repeat the identical operation once after receiving a valid new token. Conversations cannot renew. Revocation, malformed renewal responses and network errors do not trigger an operation retry; a second denial does not start another renewal. Both old and renewed tokens remain private.

No real provider was contacted, no real message was sent, and this receipt does not establish a production deployment or live-account end-to-end result.

Run from `apps/ai-worker`:

```sh
.venv/bin/pytest tests/test_workspace_mail_tools.py tests/test_runner.py tests/test_deep_team.py tests/test_managed_runtime.py tests/test_managed_recovery.py tests/test_mail_mission_routing.py tests/test_research_delivery.py tests/test_research_repair.py tests/test_direct_chat.py tests/test_orchestrator_chat.py tests/test_mission_delivery.py tests/test_runtime_dispatch.py -q
```
