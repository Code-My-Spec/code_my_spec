defmodule CodeMySpec.Repo.SqliteMigrations.AnAgentCountsItsTurnsToolCalls do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :turn_tool_count, :integer
    end
  end
end
