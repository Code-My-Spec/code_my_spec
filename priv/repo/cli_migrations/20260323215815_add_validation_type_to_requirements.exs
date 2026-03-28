defmodule CodeMySpec.Repo.Migrations.AddValidationTypeToRequirements do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :validation_type, :string
    end
  end
end
