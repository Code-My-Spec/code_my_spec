defmodule CodeMySpec.Repo.Migrations.AddFastModeSettingsToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :require_specs, :boolean
      add :require_unit_tests, :boolean
    end
  end
end
