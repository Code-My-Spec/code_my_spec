defmodule CodeMySpec.Repo.Migrations.CreateComponents do
  use Ecto.Migration

  def change do
    create table(:components, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string
      add :module_name, :string, null: false
      add :description, :text
      add :priority, :integer

      # Foreign keys - CLI doesn't have accounts table but needs the field
      add :account_id, :integer
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_component_id, references(:components, type: :binary_id, on_delete: :nilify_all)

      add :component_status, :map

      timestamps(type: :utc_datetime)
    end

    create index(:components, [:account_id])
    create index(:components, [:project_id])
    create index(:components, [:parent_component_id])
    create unique_index(:components, [:module_name, :project_id])
  end
end
