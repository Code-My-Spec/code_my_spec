defmodule CodeMySpec.Repo.Migrations.AddSyncedFromServerToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :synced_from_server, :boolean
    end

    create index(:issues, [:synced_from_server])
  end
end
