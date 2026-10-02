defmodule CodeMySpec.Repo.Migrations.DependenciesTrackInCode do
  use Ecto.Migration

  # The unique constraint on {source, target} means one row per edge, so
  # "planned and also found in code" cannot live in `provenance` alone —
  # it travels as its own flag instead.
  def change do
    alter table(:dependencies) do
      add :in_code, :boolean, default: false, null: false
    end
  end
end
