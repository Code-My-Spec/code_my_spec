defmodule CodeMySpec.Repo.Migrations.AddValidationToFiles do
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :valid, :boolean
      add :validation_errors, :map
    end

    create index(:files, [:valid])
  end
end
