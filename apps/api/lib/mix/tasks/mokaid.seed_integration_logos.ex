defmodule Mix.Tasks.Mokaid.SeedIntegrationLogos do
  @moduledoc "Downloads official integration logos and uploads them to S3/MinIO."
  @shortdoc "Seed integration provider logos to object storage"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    for app <- [:logger, :postgrex, :ecto_sql, :req, :ex_aws, :sweet_xml, :jason] do
      Application.ensure_all_started(app)
    end

    {:ok, _} = Mokaid.Repo.start_link()

    Mokaid.Integrations.LogoAssets.seed_all()
  end
end
