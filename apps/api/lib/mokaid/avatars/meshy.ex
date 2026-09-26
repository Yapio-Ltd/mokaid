defmodule Mokaid.Avatars.Meshy do
  @moduledoc "Server-only Meshy client. POSTs are never retried: generation spends credits."
  @paths %{
    "text" => "/openapi/v2/text-to-3d",
    "image" => "/openapi/v1/image-to-3d",
    "rig" => "/openapi/v1/rigging"
  }
  @framing " Full-body humanoid office character, standing in A-pose, two arms and two legs clearly separated, facing forward, no floor, no props."

  def configured?,
    do: is_binary(config()[:api_key]) and String.trim(config()[:api_key]) not in ["", "CHANGE_ME"]

  def create_text(prompt) do
    create("text", %{
      mode: "preview",
      prompt: prompt <> @framing,
      ai_model: "meshy-6",
      should_remesh: true,
      target_polycount: 20_000,
      topology: "triangle",
      pose_mode: "a-pose",
      target_formats: ["glb"],
      moderation: true
    })
  end

  def create_image(body, content_type) do
    create("image", %{
      image_url: "data:#{content_type};base64,#{Base.encode64(body)}",
      ai_model: "meshy-6",
      should_remesh: true,
      target_polycount: 20_000,
      topology: "triangle",
      pose_mode: "a-pose",
      should_texture: true,
      enable_pbr: true,
      target_formats: ["glb"],
      moderation: true
    })
  end

  def refine(task_id),
    do:
      create("text", %{
        mode: "refine",
        preview_task_id: task_id,
        enable_pbr: true,
        target_formats: ["glb"],
        texture_resolution: "2k",
        moderation: true
      })

  def rig(task_id), do: create("rig", %{input_task_id: task_id, height_meters: 1.75})

  def get(kind, task_id),
    do:
      request(
        :get,
        Map.fetch!(@paths, kind) <> "/" <> URI.encode(task_id, &URI.char_unreserved?/1)
      )

  defp create(kind, params) do
    case request(:post, Map.fetch!(@paths, kind), json: params) do
      {:ok, %{"result" => id}} when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp request(method, path, opts \\ []) do
    if configured?() do
      options = [
        method: method,
        url: (config()[:base_url] || "https://api.meshy.ai") <> path,
        auth: {:bearer, config()[:api_key]},
        retry: false,
        receive_timeout: 60_000,
        connect_options: [timeout: 15_000]
      ]

      case Req.request(Keyword.merge(options ++ opts, config()[:request_options] || [])) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, %{status: status}} ->
          {:error, {:upstream, status}}

        {:error, _} ->
          {:error, :connection_failed}
      end
    else
      {:error, :meshy_unavailable}
    end
  end

  def download(url) when is_binary(url) do
    uri = URI.parse(url)
    allowed = uri.host in ["assets.meshy.ai", "cdn.meshy.ai"]

    if uri.scheme == "https" and allowed and is_nil(uri.userinfo) and uri.port == 443 do
      opts = [
        url: url,
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: 90_000,
        into: fn {:data, chunk}, {req, resp} ->
          body = (resp.body || "") <> chunk
          if byte_size(body) > 100_000_000, do: raise("Meshy asset exceeds 100 MB")
          {:cont, {req, %{resp | body: body}}}
        end
      ]

      case Req.get(Keyword.merge(opts, config()[:download_options] || [])) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        _ -> {:error, :download_failed}
      end
    else
      {:error, :invalid_asset_url}
    end
  rescue
    _ -> {:error, :download_failed}
  end

  def download(_), do: {:error, :missing_asset}
  defp config, do: Application.get_env(:mokaid, :meshy, [])
end
