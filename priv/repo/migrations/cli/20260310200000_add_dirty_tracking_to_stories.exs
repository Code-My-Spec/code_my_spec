defmodule CodeMySpec.Repo.Migrations.AddDirtyTrackingToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :code_changed_at, :utc_datetime
      add :spex_analyzed_at, :utc_datetime
    end
  end
end
