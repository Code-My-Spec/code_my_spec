defmodule CodeMySpec.Repo.Migrations.AddCategoryToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :category, :string
    end
  end
end
