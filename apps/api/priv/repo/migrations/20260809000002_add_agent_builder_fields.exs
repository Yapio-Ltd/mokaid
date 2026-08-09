defmodule Mokaid.Repo.Migrations.AddAgentBuilderFields do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      # Free-form standing directives from the employer, injected into every
      # mission's system prompt ("Directives from your employer").
      add :instructions, :text
      # Which model tier runs this agent's missions: "smart" (default) or "fast".
      add :model_quality, :string, default: "smart", null: false
      # {"disabled": ["send_email", "mcp:slack:*"]} — tools the agent never gets.
      add :tool_preferences, :map, default: %{}, null: false
    end
  end
end
