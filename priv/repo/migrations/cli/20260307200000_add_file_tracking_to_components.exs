defmodule CodeMySpec.Repo.Migrations.AddFileTrackingToComponents do
  use Ecto.Migration

  def change do
    alter table(:components) do
      add :files_changed_at, :utc_datetime
      add :last_analyzed_at, :map, default: %{}
    end
  end
end
