defmodule CodeMySpec.Repo.Migrations.AddExecutionTypeToRequirements do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :execution_type, :string
    end
  end
end
