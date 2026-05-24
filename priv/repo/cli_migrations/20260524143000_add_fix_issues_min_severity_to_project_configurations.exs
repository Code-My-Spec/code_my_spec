defmodule CodeMySpec.Repo.Migrations.AddFixIssuesMinSeverityToProjectConfigurations do
  use Ecto.Migration

  def change do
    alter table(:project_configurations) do
      add :fix_issues_min_severity, :string
    end
  end
end
