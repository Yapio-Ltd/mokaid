defmodule Mokaid.Avatars.Worker do
  @moduledoc "Resumable Meshy preview → texture → rig → permanent assets pipeline."
  use Oban.Worker,
    queue: :avatars,
    max_attempts: 12,
    unique: [
      period: 30,
      fields: [:worker, :args],
      keys: [:generation_id],
      states: :incomplete
    ]

  import Ecto.Query
  alias Mokaid.Avatars.{Generation, Meshy, PreparedAsset}
  alias Mokaid.Billing.Credits
  alias Mokaid.{Avatars, Repo}

  @doc false
  def reconcile_terminal(id) do
    result =
      Repo.transaction(fn ->
        row = Repo.one(from g in Generation, where: g.id == ^id, lock: "FOR UPDATE")

        jobs =
          from j in Oban.Job,
            where: j.queue == "avatars" and j.args["generation_id"] == ^id

        terminal =
          from j in jobs,
            where:
              j.worker == "Mokaid.Avatars.Worker" and
                j.state in ~w(completed cancelled discarded)

        incomplete =
          from j in jobs,
            where: j.state in ~w(suspended available scheduled executing retryable)

        if row && row.status in Avatars.active_statuses() && Repo.exists?(terminal) &&
             not Repo.exists?(incomplete) do
          fail(row, "Character creation was interrupted. Your credits have been refunded.")
        end
      end)

    case result do
      {:ok, _} ->
        broadcast_balance(id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"generation_id" => id}, attempt: attempt, max_attempts: max}) do
    case Repo.transaction(
           fn ->
             # Polls and duplicate deliveries serialize on the same row. State transitions
             # and job retries cannot submit the same next stage concurrently.
             generation = Repo.one(from g in Generation, where: g.id == ^id, lock: "FOR UPDATE")

             cond do
               is_nil(generation) or generation.status in ~w(ready failed) ->
                 :ok

               DateTime.diff(DateTime.utc_now(), generation.inserted_at) > 7200 ->
                 fail(generation, "Generation took too long. Please try again.")

               true ->
                 case step(generation) do
                   {:error, reason} when attempt >= max -> fail(generation, error_message(reason))
                   result -> result
                 end
             end
           end,
           timeout: 240_000
         ) do
      {:ok, {:submit, id, claim, fun}} ->
        finish_submission(id, claim, fun.())

      {:ok, {:prepare, row, claim, url}} ->
        finish_preparation(row.id, claim, prepare_asset(row, url))

      {:ok, :waiting} ->
        {:snooze, 15}

      {:ok, result} ->
        broadcast_balance(id)
        result

      {:error, _} ->
        {:error, :avatar_processing_failed}
    end
  end

  defp step(%Generation{task_id: "submitting:" <> _} = row) do
    # A previous process may have died after Meshy accepted a paid request.
    # Never resubmit an unresolved claim; a concurrent healthy request has two
    # minutes to finish, otherwise surface the ambiguous result to the user.
    if DateTime.diff(DateTime.utc_now(), row.updated_at) > 120,
      do: fail(row, error_message(:connection_failed)),
      else: :waiting
  end

  defp step(%Generation{task_id: "preparing:" <> pending} = row) do
    # Baking is local and safe to repeat; paid upstream submissions are not.
    # Keep the original rig task ID so an interrupted preparation can resume.
    if DateTime.diff(DateTime.utc_now(), row.updated_at) > 900 do
      case String.split(pending, ":", parts: 2) do
        [_claim, rig_id] when rig_id != "" -> step(update!(row, %{task_id: rig_id}))
        _ -> fail(row, error_message(:avatar_preparation_failed))
      end
    else
      :waiting
    end
  end

  defp step(%Generation{status: "queued", mode: "text"} = row),
    do: submit(row, fn -> Meshy.create_text(row.prompt) end, "text", "generating", 2)

  defp step(%Generation{status: "queued", mode: "image"} = row) do
    with {:ok, body, type} <- Avatars.storage().get_source(row.source_storage_key) do
      submit(row, fn -> Meshy.create_image(body, type) end, "image", "generating", 2)
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp step(row) do
    case Meshy.get(row.task_kind, row.task_id) do
      {:ok, %{"status" => "SUCCEEDED"} = task} ->
        advance(row, task)

      {:ok, %{"status" => status}} when status in ["FAILED", "CANCELED"] ->
        message =
          if row.status == "rigging",
            do:
              "We could not animate this character. Try a full-body humanoid with arms and legs clearly visible.",
            else: "We could not create this character. Please try another photo or description."

        fail(row, message)

      {:ok, %{"status" => status} = task} when status in ["PENDING", "IN_PROGRESS"] ->
        raw = task["progress"]
        percent = if is_number(raw), do: raw |> round() |> max(0) |> min(100), else: 0
        {base, span} = phase_progress(row)
        update!(row, %{progress: max(row.progress, base + div(percent * span, 100))})
        :waiting

      {:ok, _} ->
        {:error, :invalid_response}

      {:error, {:upstream, code}} when code in [401, 402, 403, 404, 422] ->
        fail(row, error_message({:upstream, code}))

      {:error, _} = error ->
        error
    end
  end

  defp advance(%Generation{mode: "text", status: "generating"} = row, _task),
    do: submit(row, fn -> Meshy.refine(row.task_id) end, "text", "texturing", 40)

  defp advance(%Generation{status: status} = row, task)
       when status in ["generating", "texturing"] do
    row = update!(row, %{thumbnail_source_url: task["thumbnail_url"]})
    submit(row, fn -> Meshy.rig(row.task_id) end, "rig", "rigging", 70)
  end

  defp advance(row, task) do
    claim = "preparing:" <> Ecto.UUID.generate() <> ":" <> row.task_id
    row = update!(row, %{status: "saving", progress: 95, task_id: claim})
    url = get_in(task, ["result", "basic_animations", "walking_glb_url"])
    # No database connection or row lock is held while Blender runs.
    {:prepare, row, claim, url}
  end

  defp prepare_asset(row, url) do
    with {:ok, source} <- Meshy.download(url),
         {:ok, attrs} <- PreparedAsset.prepare(row, source),
         do: {:ok, attrs}
  rescue
    _ -> {:error, :avatar_preparation_failed}
  end

  defp finish_preparation(id, claim, result) do
    case Repo.transaction(fn ->
           row = Repo.one(from g in Generation, where: g.id == ^id, lock: "FOR UPDATE")

           if row && row.task_id == claim && row.status == "saving" do
             case result do
               {:ok, attrs} ->
                 asset =
                   %Mokaid.Assets3d.Asset{}
                   |> Mokaid.Assets3d.Asset.changeset(attrs)
                   |> Repo.insert!()

                 update!(row, %{
                   status: "ready",
                   progress: 100,
                   asset_id: asset.id,
                   thumbnail_url: attrs.metadata["thumbnail_url"],
                   thumbnail_source_url: nil,
                   source_storage_key: nil
                 })

                 {:cleanup, row.source_storage_key}

               {:error, _} ->
                 fail(row, error_message(:avatar_preparation_failed))
             end
           else
             :ok
           end
         end) do
      {:ok, {:cleanup, source_key}} ->
        Avatars.storage().delete_source(source_key)
        :ok

      {:ok, result} ->
        broadcast_balance(id)
        result

      {:error, _} ->
        {:error, :avatar_processing_failed}
    end
  end

  defp submit(row, fun, kind, status, progress) do
    # Commit an unresolved claim BEFORE leaving the transaction to make the
    # paid API request. A DB/process failure after POST cannot cause a retry to
    # spend credits on the same stage again (Meshy has no idempotency key).
    claim = "submitting:" <> Ecto.UUID.generate()
    update!(row, %{task_id: claim, task_kind: kind, status: status, progress: progress})
    {:submit, row.id, claim, fun}
  end

  defp finish_submission(id, claim, response) do
    case Repo.transaction(fn ->
           row = Repo.one(from g in Generation, where: g.id == ^id, lock: "FOR UPDATE")

           if row && row.task_id == claim && row.status not in ~w(failed ready) do
             case response do
               {:ok, task_id} ->
                 update!(row, %{task_id: task_id})
                 :waiting

               {:error, reason} ->
                 fail(row, error_message(reason))
             end
           else
             :ok
           end
         end) do
      {:ok, :waiting} ->
        {:snooze, 15}

      {:ok, result} ->
        broadcast_balance(id)
        result

      {:error, _} ->
        {:error, :avatar_processing_failed}
    end
  end

  defp phase_progress(%{status: "generating", mode: "text"}), do: {2, 37}
  defp phase_progress(%{status: "generating"}), do: {2, 67}
  defp phase_progress(%{status: "texturing"}), do: {40, 29}
  defp phase_progress(_), do: {70, 24}
  defp update!(row, attrs), do: row |> Generation.changeset(attrs) |> Repo.update!()

  defp fail(row, message) do
    case Credits.refund_strict(row.workspace_id, Avatars.charge_key(row.id),
           description: "Refund for failed 3D character"
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    update!(row, %{status: "failed", error: message, source_storage_key: nil})
    Avatars.storage().delete_source(row.source_storage_key)
    :ok
  end

  defp broadcast_balance(id) do
    case Repo.get(Generation, id) do
      %Generation{status: "failed", workspace_id: workspace_id} ->
        Credits.broadcast_balance(workspace_id)

      _ ->
        :ok
    end
  end

  defp error_message({:upstream, 402}),
    do: "Character generation is temporarily out of credits. Please contact support."

  defp error_message({:upstream, 429}),
    do: "Character generation is busy. Please try again in a few minutes."

  defp error_message({:upstream, code}) when code in [401, 403],
    do: "Character generation is temporarily unavailable. Please contact support."

  defp error_message(:avatar_preparation_failed),
    do:
      "We could not prepare all office animations for this character. Any charged credits have been returned. Try a full-body humanoid with clearly separated arms and legs."

  defp error_message(:connection_failed),
    do: "We could not confirm the generation request. Please try again later."

  defp error_message(_), do: "We could not finish saving this character. Please try again."
end
