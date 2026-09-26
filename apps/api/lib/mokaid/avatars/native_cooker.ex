defmodule Mokaid.Avatars.NativeCooker do
  @moduledoc "Converts a generated GLB for the desktop renderer without running a shell."
  def cook(glb) do
    case System.get_env("MESHY_NATIVE_COOKER") do
      nil ->
        unavailable()

      "" ->
        unavailable()

      script ->
        directory = Path.join(System.tmp_dir!(), "mokaid-avatar-#{Ecto.UUID.generate()}")
        File.mkdir_p!(directory)

        try do
          input = Path.join(directory, "model.glb")
          output = Path.join(directory, "model.mokaidasset")
          File.write!(input, glb)

          task =
            Task.async(fn ->
              try do
                System.cmd(System.get_env("MESHY_NODE_BIN") || "node", [script, input, output],
                  stderr_to_stdout: true
                )
              rescue
                _ -> {"", 1}
              end
            end)

          case Task.yield(task, 120_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, {_, 0}} -> File.read(output)
            _ -> {:error, :native_conversion_failed}
          end
        after
          File.rm_rf(directory)
        end
    end
  rescue
    _ -> {:error, :native_conversion_failed}
  end

  defp unavailable do
    if Application.get_env(:mokaid, :env) == :prod or
         System.get_env("PHX_SERVER") in ["true", "1"],
       do: {:error, :native_conversion_failed},
       else: {:ok, nil}
  end
end
