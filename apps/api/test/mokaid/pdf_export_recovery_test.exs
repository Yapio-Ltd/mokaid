defmodule Mokaid.PdfExportRecoveryTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{Agents, Tasks}
  alias Mokaid.Tasks.Workers.StaleRunWorker

  defp paused_export(workspace, member, agent, tool_name, status \\ "waiting_for_approval") do
    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{"title" => tool_name, "status" => "waiting", "assigned_agent_id" => agent.id},
        member
      )

    {:ok, run} = Tasks.create_execution_run(task)
    {:ok, run} = Tasks.update_run_progress(run, %{"status" => status})

    {:ok, request} =
      Tasks.create_approval_request(run, %{
        "tool_name" => tool_name,
        "risk_level" => "high",
        "proposed_action" => "The old gate"
      })

    request =
      request
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Repo.update!()

    %{run: run, request: request, task: task}
  end

  test "maintenance automatically resumes only a pending live PDF export" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Alex"})
    pdf = paused_export(workspace, member, agent, "export_pdf")
    external = paused_export(workspace, member, agent, "send_email")
    canceled = paused_export(workspace, member, agent, "export_pdf", "canceled")

    assert :ok = StaleRunWorker.resume_pdf_exports()
    approved = Tasks.get_approval_request(workspace.id, pdf.request.id)
    assert approved.status == "approved"
    assert approved.reviewed_by_member_id == nil
    assert approved.decision_payload == %{"source" => "internal_pdf_export_recovery"}
    assert Tasks.get_run(pdf.run.id).status == "running"
    assert Tasks.get_task(workspace.id, pdf.task.id).status == "in_progress"
    assert Tasks.get_approval_request(workspace.id, external.request.id).status == "pending"
    assert Tasks.get_run(external.run.id).status == "waiting_for_approval"
    assert Tasks.get_approval_request(workspace.id, canceled.request.id).status == "pending"
    assert Tasks.get_run(canceled.run.id).status == "canceled"

    assert :ok = StaleRunWorker.resume_pdf_exports()
    assert length(Tasks.list_runs_for_task(workspace.id, pdf.task.id)) == 1
  end

  test "a canceled run from an earlier sweep snapshot cannot be revived" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Alex"})
    pdf = paused_export(workspace, member, agent, "export_pdf")
    {:ok, _} = Tasks.update_run_progress(pdf.run, %{"status" => "canceled"})

    assert :ok = StaleRunWorker.resume_pdf_export(pdf.request)
    assert Tasks.get_run(pdf.run.id).status == "canceled"
    assert Tasks.get_approval_request(workspace.id, pdf.request.id).status == "pending"

    assert {:ok, %{status: "canceled"}} =
             Mokaid.AI.handle_progress(pdf.run.id, %{"status" => "running"})

    assert :ok = Mokaid.AI.resume_after_approval(pdf.run.id, "approved", nil, "export_pdf")
    assert Tasks.get_run(pdf.run.id).status == "canceled"
    assert length(Tasks.list_runs_for_task(workspace.id, pdf.task.id)) == 1
  end
end
