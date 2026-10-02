defmodule CodeMySpec.Repo.Migrations.ComponentsAndDependenciesCarryProvenance do
  use Ecto.Migration

  # Components as records (3aeb66cf): `authored` is written as intended
  # architecture, `discovered` is derived from code. Nullable and unset on
  # existing rows; the one-time freeze stamps them.
  def change do
    alter table(:components) do
      add :provenance, :string
    end

    alter table(:dependencies) do
      add :provenance, :string
    end
  end
end
