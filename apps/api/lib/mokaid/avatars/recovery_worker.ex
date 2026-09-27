defmodule Mokaid.Avatars.RecoveryWorker do
  @moduledoc "Recovers interrupted avatar jobs from the API without running character preparation."
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 240]

  import Ecto.Query
  alias Mokaid.{Avatars, Repo}
  alias Mokaid.Avatars.{Generation, Worker}

  @workers ["Mokaid.Avatars.Worker", "Mokaid.Avatars.RepairWorker"]
  @rescue_after :timer.minutes(30)

  @impl Oban.Worker
  def perform(_job) do
    # A killed BEAM cannot acknowledge its executing job. Oban's normal stager
    # only handles scheduled/retryable jobs; rescue these two workers explicitly.
    # Thirty minutes exceeds Blender (600s), cooking (120s), and the row claim.
    jobs = from j in Oban.Job, where: j.queue == "avatars" and j.worker in ^@workers

    with {:ok, ids} <-
           Repo.transaction(fn ->
             {:ok, _} = Oban.Engine.rescue_jobs(Oban.config(), jobs, rescue_after: @rescue_after)

             from(g in Generation,
               join: j in Oban.Job,
               on: fragment("?->>'generation_id'", j.args) == type(g.id, :string),
               where:
                 g.status in ^Avatars.active_statuses() and j.queue == "avatars" and
                   j.worker == "Mokaid.Avatars.Worker" and
                   j.state in ~w(completed cancelled discarded),
               distinct: true,
               select: g.id
             )
             |> Repo.all()
           end) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Worker.reconcile_terminal(id) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end
end
