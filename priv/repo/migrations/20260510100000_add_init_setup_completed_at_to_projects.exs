defmodule CodeMySpec.Repo.Migrations.AddInitSetupCompletedAtToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :init_completed_at, :utc_datetime
      add :setup_completed_at, :utc_datetime
    end
  end
end
