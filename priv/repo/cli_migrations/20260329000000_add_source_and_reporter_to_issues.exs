defmodule CodeMySpec.Repo.Migrations.AddSourceAndReporterToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :source, :string, null: false, default: "qa_agent"
      add :reported_by_id, :integer
    end

    create index(:issues, [:source])
    create index(:issues, [:reported_by_id])
  end
end
