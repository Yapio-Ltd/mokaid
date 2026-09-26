defmodule Mokaid.Avatars.Glb do
  @moduledoc "Checks Meshy's GLB container and gives its walking clip the application's canonical name."
  def prepare(
        <<"glTF", 2::little-32, length::little-32, json_size::little-32, 0x4E4F534A::little-32,
          json::binary-size(json_size), rest::binary>> = data
      )
      when length == byte_size(data) do
    with {:ok, doc} <- Jason.decode(json),
         true <- is_list(doc["meshes"]) and doc["meshes"] != [],
         true <- embedded?(doc),
         animations when is_list(animations) and animations != [] <- doc["animations"] do
      animations =
        Enum.with_index(animations, fn animation, index ->
          Map.put(animation, "name", if(index == 0, do: "walking", else: "meshy_#{index}"))
        end)

      encoded = doc |> Map.put("animations", animations) |> Jason.encode!()
      padded = encoded <> String.duplicate(" ", rem(4 - rem(byte_size(encoded), 4), 4))
      size = 20 + byte_size(padded) + byte_size(rest)

      {:ok,
       <<"glTF", 2::little-32, size::little-32, byte_size(padded)::little-32,
         0x4E4F534A::little-32, padded::binary, rest::binary>>}
    else
      _ -> {:error, :invalid_glb}
    end
  rescue
    _ -> {:error, :invalid_glb}
  end

  def prepare(_), do: {:error, :invalid_glb}

  defp embedded?(doc) do
    Enum.all?((doc["buffers"] || []) ++ (doc["images"] || []), fn item ->
      is_nil(item["uri"]) or
        (is_binary(item["uri"]) and String.starts_with?(item["uri"], "data:"))
    end)
  end
end
