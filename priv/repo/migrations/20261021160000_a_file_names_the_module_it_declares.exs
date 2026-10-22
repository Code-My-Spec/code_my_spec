defmodule CodeMySpec.Repo.Migrations.AFileNamesTheModuleItDeclares do
  use Ecto.Migration

  # The scanned module claims a component by name; it was read out of the
  # scanner's `validation_errors` JSON.
  def up do
    alter table(:files) do
      add :module_name, :string
    end

    create index(:files, [:project_id, :module_name])

    flush()

    execute("UPDATE files SET module_name = validation_errors->'data'->>'module_name'")
  end

  def down do
    alter table(:files) do
      remove :module_name
    end
  end
end
