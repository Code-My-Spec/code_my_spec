defmodule CodeMySpec.Repo.Migrations.AddScopeToRequirements do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :scope, :string, default: "local"
    end
  end
end
