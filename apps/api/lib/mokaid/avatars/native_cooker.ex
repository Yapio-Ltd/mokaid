defmodule Mokaid.Avatars.NativeCooker do
  @moduledoc "Bakes the complete office library and a head portrait before native conversion."

  @clips ~w(idle walking typing working thinking talking waiting requesting_approval
    blocked celebrating away offline reviewing learning sitting preparing_coffee
    playing_foosball sitting_sofa sit_down stand_up sit_down_sofa stand_up_sofa
    walking_coffee carrying_coffee drinking_coffee talking_coffee chair_pullback
    chair_pushin walking_brisk walking_relaxed typing_focused typing_relaxed
    phone_pickup phone_call phone_putdown greeting laughing laughing_coffee
    talking_standing sitting_sofa_coffee talking_sofa_coffee drinking_sofa_coffee
    laughing_sofa_coffee sit_down_sofa_coffee stand_up_sofa_coffee
    talking_sofa_coffee_left talking_sofa_coffee_right coffee_putdown)

  def required_clips, do: @clips

  def prepare(glb) when is_binary(glb) and byte_size(glb) <= 64 * 1024 * 1024 do
    directory = Path.join(System.tmp_dir!(), "mokaid-avatar-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    try do
      input = Path.join(directory, "input.glb")
      output = Path.join(directory, "model.glb")
      native = Path.join(directory, "model.mokaidasset")
      preparer = System.get_env("MOKAID_AVATAR_PREPARER")
      blender = System.get_env("MOKAID_AVATAR_BLENDER")
      cooker = System.get_env("MESHY_NATIVE_COOKER")

      with true <-
             configured_file?(preparer) and configured_file?(blender) and configured_file?(cooker),
           :ok <- File.write(input, glb),
           :ok <-
             run(
               blender,
               [
                 "--background",
                 "--factory-startup",
                 "--disable-autoexec",
                 "--threads",
                 "2",
                 "--python-exit-code",
                 "1",
                 "--python",
                 preparer,
                 "--",
                 "--input",
                 input,
                 "--output-dir",
                 directory
               ],
               directory,
               "prepare",
               600
             ),
           {:ok, manifest_bytes} <- File.read(Path.join(directory, "manifest.json")),
           {:ok, manifest} <- Jason.decode(manifest_bytes),
           :ok <- validate_manifest(manifest),
           :ok <-
             run(
               System.get_env("MESHY_NODE_BIN") || "node",
               [cooker, output, native],
               directory,
               "cook",
               120
             ),
           {:ok, prepared} <- read_bounded(output, 64 * 1024 * 1024),
           true <-
             manifest["model_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, prepared), case: :lower),
           {:ok, cooked} <- read_bounded(native, 128 * 1024 * 1024),
           {:ok, portrait} <- read_bounded(Path.join(directory, "portrait.png"), 2 * 1024 * 1024),
           true <- match?(<<0x89, "PNG", 13, 10, 26, 10, _::binary>>, portrait),
           true <- String.starts_with?(cooked, "MOKASSET") do
        {:ok, %{glb: prepared, native: cooked, portrait: portrait, manifest: manifest}}
      else
        _ -> {:error, :avatar_preparation_failed}
      end
    after
      File.rm_rf(directory)
    end
  rescue
    _ -> {:error, :avatar_preparation_failed}
  end

  def prepare(_), do: {:error, :avatar_preparation_failed}

  def validate_manifest(%{
        "status" => "ready",
        "animation_clips" => clips,
        "target_height_m" => 1.75,
        "pipeline_version" => 1,
        "quality" => %{"clips" => 48},
        "portrait" => %{"size" => [384, 384], "weighted_head_vertices" => count}
      })
      when is_list(clips) and is_integer(count) and count > 0 do
    if length(clips) == length(@clips) and MapSet.new(clips) == MapSet.new(@clips),
      do: :ok,
      else: {:error, :incomplete_avatar_animations}
  end

  def validate_manifest(_), do: {:error, :incomplete_avatar_animations}

  defp configured_file?(path), do: is_binary(path) and path != "" and File.regular?(path)

  defp read_bounded(path, limit) do
    with {:ok, %{size: size}} when size > 0 and size <= limit <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         do: {:ok, bytes}
  end

  defp run(executable, args, directory, name, timeout) do
    preparer = System.get_env("MOKAID_AVATAR_PREPARER") || ""

    runner =
      System.get_env("MOKAID_AVATAR_PROCESS_RUNNER") ||
        Path.join(Path.dirname(preparer), "avatar-process-runner.py")

    python = System.get_env("MOKAID_AVATAR_PYTHON") || "python3"

    case System.cmd(
           python,
           [
             runner,
             "--timeout",
             Integer.to_string(timeout),
             "--log",
             Path.join(directory, name <> ".log"),
             "--",
             executable | args
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> {:error, :avatar_preparation_failed}
    end
  end
end
