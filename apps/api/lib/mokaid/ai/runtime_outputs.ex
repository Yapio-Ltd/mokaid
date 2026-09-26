defmodule Mokaid.AI.RuntimeOutputs do
  @moduledoc "Serializes publication retries by task and immutable provider artifact key."
  import Ecto.Query
  alias Mokaid.{Repo, Tasks}
  alias Mokaid.AI.ManagedRuntime

  def publish(workspace_id, task_id, attrs, create) do
    with {:ok, _} <- Ecto.UUID.cast(workspace_id),
         {:ok, _} <- Ecto.UUID.cast(task_id),
         {:ok, _} <- Ecto.UUID.cast(attrs["run_id"]),
         %{} = run <- Tasks.get_run(attrs["run_id"]),
         true <- run.workspace_id == workspace_id and run.task_id == task_id,
         key when is_binary(key) and byte_size(key) in 1..200 <- attrs["artifact_key"] do
      Repo.transaction(fn ->
        # The same publication lock covers lookup and insertion: concurrent delivery retries
        # cannot upload another Drive item, even after the runtime has settled.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
          "runtime-output:" <> task_id
        ])

        existing =
          Repo.one(
            from d in Mokaid.Drive.DriveItem,
              where:
                d.workspace_id == ^workspace_id and d.linked_task_id == ^task_id and
                  fragment("?->>'runtime_artifact_key' = ?", d.metadata, ^key) and
                  fragment("?->>'runtime_run_id' = ?", d.metadata, ^run.id),
              limit: 1
          )

        if existing do
          {:existing, existing}
        else
          case ManagedRuntime.authorize_output(
                 workspace_id,
                 run.id,
                 attrs
               ) do
            {:ok, _} -> {:created, create.()}
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)
    else
      _ -> {:error, :not_found}
    end
  end
end
