defmodule CodeMySpec.Repo.Migrations.EnrichCriteriaForBdd do
  use Ecto.Migration

  def change do
    alter table(:criteria) do
      add :rule_id, references(:bdd_rules, type: :binary_id, on_delete: :nilify_all)
      add :body, :text
      add :kind, :string
    end

    create index(:criteria, [:rule_id])
  end
end
