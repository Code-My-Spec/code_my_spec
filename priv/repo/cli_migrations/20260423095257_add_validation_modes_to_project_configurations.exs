defmodule CodeMySpec.Repo.Migrations.AddValidationModesToProjectConfigurations do
  use Ecto.Migration

  def change do
    alter table(:project_configurations) do
      add :spec_validation, :string
      add :qa_validation, :string
    end
  end
end
