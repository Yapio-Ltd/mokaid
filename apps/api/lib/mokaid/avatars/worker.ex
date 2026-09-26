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
  alias Mokaid.Avatars.{Generation, Glb, Meshy}
  alias Mokaid.{Avatars, Repo}

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
      {:ok, {:submit, id, claim, fun}} -> finish_submission(id, claim, fun.())
      {:ok, :waiting} -> {:snooze, 15}
      {:ok, result} -> result
      {:error, _} -> {:error, :avatar_processing_failed}
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
            else:
              "Meshy could not create this character. Please try another photo or description."

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
    row = update!(row, %{status: "saving", progress: 95})
    url = get_in(task, ["result", "basic_animations", "walking_glb_url"])
    key = "assets3d/generated-characters/#{row.workspace_id}/#{row.id}"
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    media = MokaidWeb.Endpoint.url() <> "/api/avatar-assets/#{row.id}/#{token}"

    with {:ok, source} <- Meshy.download(url),
         {:ok, glb} <- Glb.prepare(source),
         {:ok, native} <- native_cooker().cook(glb),
         :ok <- Avatars.storage().put_asset(key <> ".glb", glb, "model/gltf-binary"),
         {:ok, native_path} <- save_native(key, native, media),
         {:ok, thumbnail} <- save_thumbnail(row, key, media) do
      attrs = %{
        workspace_id: row.workspace_id,
        slug: "custom_#{row.id}",
        kind: "character",
        storage_key: key <> ".glb",
        cdn_path: media <> "/model.glb",
        sha256: :crypto.hash(:sha256, glb) |> Base.encode16(case: :lower),
        byte_size: byte_size(glb),
        animation_clips: ["walking"],
        metadata: %{
          "display_name" => row.name,
          "target_height_m" => 1.75,
          "source" => "meshy",
          "custom" => true,
          "generation_id" => row.id,
          "media_token" => token,
          "native_cdn_path" => native_path,
          "thumbnail_url" => thumbnail && thumbnail.url,
          "thumbnail_content_type" => thumbnail && thumbnail.type,
          "skeleton" => "meshy_biped"
        }
      }

      asset = %Mokaid.Assets3d.Asset{} |> Mokaid.Assets3d.Asset.changeset(attrs) |> Repo.insert!()

      update!(row, %{
        status: "ready",
        progress: 100,
        asset_id: asset.id,
        thumbnail_url: thumbnail && thumbnail.url,
        thumbnail_source_url: nil,
        source_storage_key: nil
      })

      Avatars.storage().delete_source(row.source_storage_key)
      :ok
    end
  end

  defp save_native(_key, nil, _media), do: {:ok, nil}

  defp save_native(key, native, media) do
    with :ok <-
           Avatars.storage().put_asset(key <> ".mokaidasset", native, "application/octet-stream") do
      {:ok, media <> "/model.mokaidasset"}
    end
  end

  defp save_thumbnail(%{thumbnail_source_url: nil}, _, _), do: {:ok, nil}

  defp save_thumbnail(row, key, media) do
    with {:ok, bytes} <- Meshy.download(row.thumbnail_source_url),
         {:ok, type} <- Avatars.image_type(bytes),
         :ok <- Avatars.storage().put_asset(key <> ".png", bytes, type) do
      {:ok, %{url: media <> "/thumbnail.png", type: type}}
    else
      # A missing preview must not discard a successfully generated character.
      _ -> {:ok, nil}
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
      {:ok, :waiting} -> {:snooze, 15}
      {:ok, result} -> result
      {:error, _} -> {:error, :avatar_processing_failed}
    end
  end

  defp phase_progress(%{status: "generating", mode: "text"}), do: {2, 37}
  defp phase_progress(%{status: "generating"}), do: {2, 67}
  defp phase_progress(%{status: "texturing"}), do: {40, 29}
  defp phase_progress(_), do: {70, 24}
  defp update!(row, attrs), do: row |> Generation.changeset(attrs) |> Repo.update!()

  defp fail(row, message) do
    update!(row, %{status: "failed", error: message, source_storage_key: nil})
    Avatars.storage().delete_source(row.source_storage_key)
    :ok
  end

  defp native_cooker,
    do: Application.get_env(:mokaid, :avatar_native_cooker, Mokaid.Avatars.NativeCooker)

  defp error_message({:upstream, 402}),
    do: "Character generation is temporarily out of credits. Please contact support."

  defp error_message({:upstream, 429}),
    do: "Character generation is busy. Please try again in a few minutes."

  defp error_message({:upstream, code}) when code in [401, 403],
    do: "Character generation is temporarily unavailable. Please contact support."

  defp error_message(:connection_failed),
    do: "Meshy could not confirm the generation request. Please try again later."

  defp error_message(_), do: "We could not finish saving this character. Please try again."
end
