defmodule Mokaid.AIResumeTest do
  use Mokaid.DataCase, async: false

  alias Mokaid.{AI, Agents, Tasks}

  test "stopping during the resume HTTP request prevents lost-run fallback restart" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Alex"})

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{"title" => "Export PDF", "status" => "waiting", "assigned_agent_id" => agent.id},
        member
      )

    {:ok, run} = Tasks.create_execution_run(task)
    {:ok, run} = Tasks.update_run_progress(run, %{"status" => "waiting_for_approval"})

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    original_config = Application.fetch_env!(:mokaid, :ai_worker)

    on_exit(fn ->
      Application.put_env(:mokaid, :ai_worker, original_config)
      :gen_tcp.close(listener)
    end)

    Application.put_env(:mokaid, :ai_worker,
      dispatch: :http,
      url: "http://127.0.0.1:#{port}",
      token: "fixture"
    )

    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, :resume_request_received)

        receive do
          :finish_request -> :ok
        after
          5_000 -> raise "test did not release the resume request"
        end

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
          )

        :gen_tcp.close(socket)
      end)

    resuming =
      Task.async(fn -> AI.resume_after_approval(run.id, "approved", nil, "export_pdf") end)

    assert_receive :resume_request_received, 5_000

    # Same state transitions as Stop, while the worker request is still open.
    AI.cancel_active_runs_for_task(task, "Stopped by a teammate")
    {:ok, _} = Tasks.update_task(task, %{"status" => "to_do"}, member)
    send(server.pid, :finish_request)

    assert :ok = Task.await(resuming, 5_000)
    Task.await(server, 5_000)
    assert Tasks.get_run(run.id).status == "canceled"
    assert Tasks.get_task(workspace.id, task.id).status == "to_do"
    assert length(Tasks.list_runs_for_task(workspace.id, task.id)) == 1
  end
end
