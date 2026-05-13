defmodule CodeMySpec.Repo.Migrations.AddSubagentsAndTtl do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :subagents, {:array, :map}, default: []
    end

    alter table(:project_configurations) do
      add :subagent_ttl_minutes, :integer, default: 10, null: false
    end
  end
end
