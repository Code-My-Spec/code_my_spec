defmodule CodeMySpec.Repo.Migrations.MakeCheckerModuleNullable do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      modify :checker_module, :string, null: true, from: {:string, null: false}
    end
  end
end
