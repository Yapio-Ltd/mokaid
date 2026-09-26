"""Optional real PostgreSQL tests in an isolated, automatically dropped schema.

Set RUNTIME_TEST_DATABASE_URL to a local test database. These tests never
connect to providers, and never modify an application's existing tables.
"""

import asyncio
import os
import time
import uuid

import pytest

from app.runtime_store import OwnershipConflict, PostgresStore

pytestmark = pytest.mark.skipif(not os.environ.get("RUNTIME_TEST_DATABASE_URL"), reason="Local runtime test database was not supplied")


@pytest.fixture
async def pg_store():
    from psycopg import AsyncConnection, sql
    from psycopg.rows import dict_row
    from psycopg_pool import AsyncConnectionPool

    dsn = os.environ["RUNTIME_TEST_DATABASE_URL"]
    schema = "runtime_test_" + uuid.uuid4().hex
    connection = await AsyncConnection.connect(dsn, autocommit=True)
    await connection.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
    pool = AsyncConnectionPool(dsn, min_size=1, max_size=4, open=False,
                               kwargs={"autocommit": True, "row_factory": dict_row, "options": f"-c search_path={schema}"})
    try:
        await pool.open()
        store = PostgresStore(pool)
        await store.initialize()
        yield store
    finally:
        await pool.close()
        await connection.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))
        await connection.close()


def payload(run="r", workspace="ws"):
    return {"run_id": run, "workspace_id": workspace, "task_id": "t", "agent_id": "a", "input": {}}


async def test_postgres_acceptance_claim_atomicity_and_recovery(pg_store):
    store = pg_store
    assert await store.accept_run(payload())
    assert not await store.accept_run(payload())
    with pytest.raises(OwnershipConflict):
        await store.accept_run(payload(workspace="foreign"))
    a, b = await asyncio.gather(store.claim_runs("a"), store.claim_runs("b"))
    assert len(a) + len(b) == 1
    owner = (a or b)[0]["owner"]
    assert await store.renew_lease("r", owner)
    assert not await store.renew_lease("r", "foreign")
    await store._mutate("r", lambda row: row.update(lease_until=0))
    recovered = await store.claim_runs("new")
    assert recovered[0]["attempt"] == 2
    assert not await store.finish_run("r", owner, "completed")
    assert await store.finish_run("r", "new", "completed")


async def test_postgres_concurrent_patches_journal_and_event_ownership(pg_store):
    store = pg_store
    await store.accept_run(payload())
    await store.accept_run(payload("other", "foreign"))
    await asyncio.gather(store.save_execution("r", team={"members": ["a"]}),
                         store.save_execution("r", cursor=2))
    await store.save_execution("r", session_id="session")
    with pytest.raises(OwnershipConflict):
        await store.save_execution("other", session_id="session")
    assert (await store.get_execution("r"))["team"] == {"members": ["a"]}
    first, second = await asyncio.gather(store.begin_operation("r", "post", {"body": "hello"}),
                                        store.begin_operation("r", "post", {"body": "hello"}, "child"))
    assert sum(item["execute"] for item in (first, second)) == 1
    await store.finish_operation("r", first["key"], "succeeded", {"id": "result"})
    cached = await store.begin_operation("r", "post", {"body": "hello"})
    assert cached["result"] == {"id": "result"}
    assert await store.record_event("e", "session", "agent.session.completed", {"run_id": "foreign"})
    assert not await store.record_event("e", "session", "agent.session.completed", {"run_id": "foreign"})
    event = (await store.list_events("r"))[0]
    assert event["workspace_id"] == "ws"
    assert not await store.list_events("other")


async def test_postgres_commands_and_cleanup_require_remote_deletion(pg_store):
    store = pg_store
    await store.accept_run(payload())
    await store.claim_runs("owner")
    await store.save_execution("r", session_id="session")
    await store.enqueue_command("r", "resume", {"decision": "approved"}, "approval")
    assert len(await store.pending_commands("r", "owner")) == 1
    assert await store.ack_command("r", "approval", "owner")
    assert not await store.pending_commands("r", "owner")
    await store.finish_run("r", "owner", "completed")
    await store._mutate("r", lambda row: row.update(completed_at=time.time() - 8 * 86400))
    assert len(await store.expired_sessions()) == 1
    assert await store.cleanup() == 0
    await store.mark_session_deleted("session")
    assert await store.cleanup() == 1
    assert await store.find_session("session") is None


async def test_postgres_retention_fences_resumes_and_preserves_pending_accounting(pg_store):
    store = pg_store
    await store.accept_run(payload())
    await store.claim_runs("worker")
    await store.save_execution("r", session_id="session")
    await store.finish_run("r", "worker", "waiting_for_user_input")
    old = time.time() - 8 * 86400
    await store._mutate("r", lambda row: row.update(paused_at=old))
    assert len(await store.expired_sessions()) == 1
    assert len(await store.list_sessions("r")) == 1
    first, second = await asyncio.gather(store.claim_cleanup("r", "a"), store.claim_cleanup("r", "b"))
    assert first != second
    cleaner = "a" if first else "b"
    with pytest.raises(OwnershipConflict):
        await store.enqueue_command("r", "resume", {"decision": "approved"})
    assert not await store.claim_runs("worker")
    await store.save_session_snapshot("r", "session", retention_imported=True)
    await store.finish_cleanup("r", cleaner, "canceled", {"summary": "Expired"})
    await store.mark_session_deleted("session")
    assert await store.cleanup() == 0
    await store.release_cleanup("r", cleaner)
    await store.save_execution("r", settlement_pending=True)
    assert await store.cleanup() == 0
    await store.save_execution("r", settlement_pending=False, delivery_pending={"status": "canceled"})
    assert await store.cleanup() == 0
    await store.save_execution("r", delivery_pending=None)
    assert await store.cleanup() == 1
