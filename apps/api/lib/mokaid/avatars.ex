defmodule Mokaid.Avatars do
  @moduledoc "Workspace-owned, durable Meshy character generation."
  import Ecto.Query
  alias Mokaid.Avatars.{Generation, Meshy, Worker}
  alias Mokaid.Repo

  @active ~w(queued generating texturing rigging saving)
  def active_statuses, do: @active

  def list(workspace_id) do
    from(g in Generation,
      where: g.workspace_id == ^workspace_id,
      order_by: [desc: g.inserted_at],
      limit: 30,
      preload: [:asset]
    )
    |> Repo.all()
  end

  def get(workspace_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      from(g in Generation,
        where: g.workspace_id == ^workspace_id and g.id == ^id,
        preload: [:asset]
      )
      |> Repo.one()
    else
      _ -> nil
    end
  end

  def create(workspace_id, member, params) do
    with true <- Meshy.configured?() || {:error, :meshy_unavailable},
         {:ok, input} <- validate_input(params),
         :ok <- check_limits(workspace_id),
         {:ok, source} <- store_source(workspace_id, input) do
      result =
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
            "avatar:" <> workspace_id
          ])

          case check_limits(workspace_id) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          attrs = %{
            workspace_id: workspace_id,
            created_by_member_id: member && member.id,
            mode: input.mode,
            prompt: input[:prompt],
            name: input.name,
            source_storage_key: source
          }

          generation = %Generation{} |> Generation.changeset(attrs) |> Repo.insert!()
          %{generation_id: generation.id} |> Worker.new() |> Oban.insert!()
          Repo.preload(generation, :asset)
        end)

      if match?({:error, _}, result), do: storage().delete_source(source)
      result
    end
  end

  def validate_input(%{"mode" => "text", "prompt" => prompt} = params) when is_binary(prompt) do
    prompt = String.trim(prompt)

    with {:ok, name} <- name(params) do
      if String.length(prompt) in 3..600,
        do: {:ok, %{mode: "text", prompt: prompt, name: name}},
        else: {:error, :invalid_avatar_prompt}
    end
  end

  def validate_input(%{"mode" => "image", "file" => %Plug.Upload{} = file} = params) do
    with {:ok, name} <- name(params),
         {:ok, %{size: size}} when size > 0 and size <= 10_000_000 <- File.stat(file.path),
         {:ok, body} <- File.read(file.path),
         {:ok, type} when type in ["image/jpeg", "image/png"] <- image_type(body) do
      {:ok, %{mode: "image", body: body, content_type: type, name: name}}
    else
      {:error, :invalid_avatar_name} = error -> error
      _ -> {:error, :invalid_avatar_image}
    end
  end

  def validate_input(_), do: {:error, :invalid_avatar_input}

  defp name(params) do
    case params["name"] do
      nil ->
        {:ok, "Custom character"}

      name when is_binary(name) ->
        name = String.trim(name)
        name = if name == "", do: "Custom character", else: name
        if String.length(name) in 1..80, do: {:ok, name}, else: {:error, :invalid_avatar_name}

      _ ->
        {:error, :invalid_avatar_name}
    end
  end

  def image_type(<<0x89, "PNG", 13, 10, 26, 10, _::binary>>), do: {:ok, "image/png"}
  def image_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def image_type(_), do: {:error, :invalid_avatar_image}

  defp store_source(workspace_id, %{mode: "image"} = input) do
    case storage().put_source(workspace_id, input.body, input.content_type) do
      {:ok, %{storage_key: key}} -> {:ok, key}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp store_source(_, _), do: {:ok, nil}

  defp check_limits(workspace_id) do
    active =
      from(g in Generation, where: g.workspace_id == ^workspace_id and g.status in ^@active)

    since = DateTime.add(DateTime.utc_now(), -86_400, :second)

    daily =
      from(g in Generation, where: g.workspace_id == ^workspace_id and g.inserted_at > ^since)

    cond do
      Repo.aggregate(active, :count) >= 2 -> {:error, :avatar_generation_in_progress}
      Repo.aggregate(daily, :count) >= 10 -> {:error, :avatar_generation_daily_limit}
      true -> :ok
    end
  end

  def storage, do: Application.get_env(:mokaid, :avatar_storage, Mokaid.Avatars.Storage)

  def serialize(generation) do
    asset =
      case generation.asset do
        %Mokaid.Assets3d.Asset{} = asset -> MokaidWeb.JSON.asset_3d(asset)
        _ -> nil
      end

    %{
      id: generation.id,
      mode: generation.mode,
      prompt: generation.prompt,
      name: generation.name,
      status: generation.status,
      progress: generation.progress,
      asset_id: generation.asset_id,
      asset: asset,
      thumbnail_url: generation.thumbnail_url,
      error: generation.error,
      inserted_at: generation.inserted_at,
      updated_at: generation.updated_at
    }
  end

  @doc "Webhooks only wake known tasks. Never accept status or asset URLs from their bodies."
  def webhook_hint(%{"id" => task_id}, raw_body)
      when is_binary(task_id) and byte_size(raw_body) <= 1_000_000 do
    case Repo.get_by(Generation, task_id: task_id) do
      %Generation{status: status} = generation when status in @active ->
        Repo.transaction(fn ->
          digest = :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

          {inserted, _} =
            Repo.insert_all(
              "meshy_webhook_deliveries",
              [%{digest: digest, inserted_at: DateTime.utc_now()}],
              on_conflict: :nothing
            )

          if inserted == 1 do
            %{generation_id: generation.id} |> Worker.new() |> Oban.insert!()
          end

          cutoff = DateTime.add(DateTime.utc_now(), -604_800, :second)

          from(d in "meshy_webhook_deliveries", where: d.inserted_at < ^cutoff)
          |> Repo.delete_all()
        end)

      _ ->
        {:ok, :ignored}
    end
  end

  def webhook_hint(_, _), do: {:ok, :ignored}
end
