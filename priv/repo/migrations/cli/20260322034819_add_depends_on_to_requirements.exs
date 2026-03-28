defmodule CodeMySpec.Repo.Migrations.AddDependsOnToRequirements do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :depends_on, :text, default: "[]"
    end
  end
end
