defmodule CodeMySpec.Repo.Migrations.CreateRequirements do
  use Ecto.Migration

  def change do
    create table(:requirements) do
      add :name, :string, null: false

      add :type, :string,
        null: false

      add :description, :string, null: false
      add :checker_module, :string, null: false
      add :satisfied_by, :string
      add :satisfied, :boolean, default: false, null: false
      add :checked_at, :utc_datetime
      add :details, :map, default: %{}

      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:requirements, [:component_id])
    create unique_index(:requirements, [:component_id, :name])
  end
end
