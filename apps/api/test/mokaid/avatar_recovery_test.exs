defmodule Mokaid.AvatarRecoveryTest do
  use Mokaid.DataCase, async: false

  import Ecto.Query
  alias Mokaid.Avatars
  alias Mokaid.Assets3d.Asset
  alias Mokaid.Avatars.{Generation, RecoveryWorker, RepairWorker, Worker}
  alias Mokaid.Billing.{Credits, CreditTransaction, Subscription}

  defmodule Storage do
    def delete_source(_key), do: :ok
  end

  setup do
    previous =
      for {key, value} <- [
            avatar_pipeline_enabled: true,
            avatar_storage: Storage,
            meshy: [api_key: "fixture", request_options: [plug: {Req.Test, __MODULE__}]]
          ],
          into: %{} do
        old = Application.fetch_env(:mokaid, key)
        Application.put_env(:mokaid, key, value)
        {key, old}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:mokaid, key, value)
        {key, :error} -> Application.delete_env(:mokaid, key)
      end)
    end)

    Req.Test.stub(__MODULE__, fn _ ->
      flunk("Recovery must never call the generation provider")
    end)

    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)

    %Subscription{}
    |> Subscription.changeset(%{workspace_id: workspace.id, credits_balance: 10_000})
    |> Repo.insert!()

    {:ok, workspace: workspace, member: member}
  end

  defp generation(ctx) do
    {:ok, row} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        Avatars.create(ctx.workspace.id, ctx.member, %{
          "mode" => "text",
          "prompt" => "A humanoid office character",
          "expected_credits" => 1_000
        })
      end)

    job = Repo.one!(from j in Oban.Job, where: j.args["generation_id"] == ^row.id)
    {row, job}
  end

  defp executing(job, age, attrs \\ []) do
    job
    |> Ecto.Changeset.change(
      Keyword.merge(
        [state: "executing", attempt: 1, attempted_at: DateTime.add(DateTime.utc_now(), -age)],
        attrs
      )
    )
    |> Repo.update!()
    |> Repo.reload!()
  end

  defp recover do
    Oban.Testing.with_testing_mode(:manual, fn -> RecoveryWorker.perform(%Oban.Job{}) end)
  end

  defp balance(ctx), do: Credits.summary(ctx.workspace.id).spendable

  test "job deadlines leave room for the longest subprocess before orphan rescue" do
    for worker <- [Worker, RepairWorker] do
      timeout = worker.timeout(%Oban.Job{})
      assert timeout == :timer.minutes(18)
      assert timeout + :timer.seconds(600 + 5) < :timer.minutes(30)
    end
  end

  test "old interrupted jobs are made available without changing their generation or charge",
       ctx do
    {row, job} = generation(ctx)
    job = executing(job, 1_801)
    original = Repo.get!(Generation, row.id)

    assert :ok = recover()
    assert %{state: "available", attempt: 1} = Repo.reload!(job)
    assert Repo.reload!(original) == original
    assert balance(ctx) == 9_000
  end

  test "fresh jobs, other queues and other workers are never rescued", ctx do
    {_row, job} = generation(ctx)
    fresh = executing(job, 1_700)

    foreign_queue =
      %Oban.Job{}
      |> Ecto.Changeset.change(%{queue: "default", worker: "Mokaid.Avatars.Worker", args: %{}})
      |> Repo.insert!()
      |> executing(3_600)

    foreign_worker =
      %Oban.Job{}
      |> Ecto.Changeset.change(%{queue: "avatars", worker: "Other.Worker", args: %{}})
      |> Repo.insert!()
      |> executing(3_600)

    assert :ok = recover()

    for untouched <- [fresh, foreign_queue, foreign_worker],
        do: assert(Repo.reload!(untouched) == untouched)

    assert balance(ctx) == 9_000
  end

  test "a killed final attempt fails the generation and refunds its debit exactly once", ctx do
    {row, job} = generation(ctx)
    job = executing(job, 1_801, attempt: job.max_attempts)

    assert :ok = recover()
    assert Repo.reload!(job).state == "discarded"
    assert Repo.reload!(row).status == "failed"
    assert Repo.reload!(row).error =~ "refunded"
    assert balance(ctx) == 10_000

    transactions =
      Repo.all(from t in CreditTransaction, where: t.workspace_id == ^ctx.workspace.id)

    assert length(transactions) == 2

    assert :ok = recover()
    assert balance(ctx) == 10_000

    assert Repo.all(from t in CreditTransaction, where: t.workspace_id == ^ctx.workspace.id) ==
             transactions
  end

  test "a historical terminal job never fails a generation with another incomplete job", ctx do
    {row, job} = generation(ctx)
    job |> Ecto.Changeset.change(state: "discarded", attempt: job.max_attempts) |> Repo.update!()

    for state <- ~w(available scheduled executing retryable suspended) do
      active =
        %Oban.Job{}
        |> Ecto.Changeset.change(%{
          queue: "avatars",
          worker: "Mokaid.Avatars.Worker",
          args: %{generation_id: row.id},
          state: state
        })
        |> Repo.insert!()

      assert :ok = recover()
      assert Repo.reload!(row).status == "queued"
      assert balance(ctx) == 9_000
      Repo.delete!(active)
    end
  end

  test "ready characters and exhausted repair jobs never alter assets or credits", ctx do
    {row, job} = generation(ctx)

    asset =
      %Asset{}
      |> Asset.changeset(%{
        workspace_id: ctx.workspace.id,
        slug: "ready_#{row.id}",
        kind: "character",
        storage_key: "ready/model.glb",
        cdn_path: "/ready/model.glb",
        sha256: String.duplicate("a", 64),
        byte_size: 42,
        animation_clips: ["idle"],
        metadata: %{"media_token" => "unchanged"}
      })
      |> Repo.insert!()

    row =
      row
      |> Ecto.Changeset.change(status: "ready", asset_id: asset.id)
      |> Repo.update!()
      |> Repo.reload!()

    executing(job, 1_801, attempt: job.max_attempts)

    repair =
      %Oban.Job{}
      |> Ecto.Changeset.change(%{
        queue: "avatars",
        worker: "Mokaid.Avatars.RepairWorker",
        args: %{generation_id: row.id},
        max_attempts: 2
      })
      |> Repo.insert!()
      |> executing(1_801, attempt: 2)

    assert :ok = recover()
    assert Repo.reload!(repair).state == "discarded"
    assert Repo.reload!(row) == row
    assert Repo.reload!(asset) == asset
    assert balance(ctx) == 9_000
    assert Repo.aggregate(CreditTransaction, :count) == 1
  end

  test "repair-only terminal jobs do not authorize a generation refund", ctx do
    {row, job} = generation(ctx)
    executing(job, 1_801, attempt: job.max_attempts, worker: "Mokaid.Avatars.RepairWorker")

    assert :ok = recover()
    assert Repo.reload!(job).state == "discarded"
    assert Repo.reload!(row).status == "queued"
    assert balance(ctx) == 9_000
  end
end
