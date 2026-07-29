defmodule CodeMySpec.Repo.Migrations.ReshapeDevopsProdToDevopsLevels do
  use Ecto.Migration

  # devops_prod [:on, :off] shipped unreleased and immediately grew a third
  # level: :off (no DevOps at all) | :uat (staging only) | :prod (full
  # promotion). One ordered enum, not flags — prod requires UAT. Old values
  # remap: on → prod, off → uat. Default lives on the schema, never here.
  #
  # Guarded, unlike the Postgres copy. On a fresh database 20260711120000 now
  # adds `devops` directly and there is nothing to rename — see that migration
  # for why (SQLite reports `no such column` when renaming a column that was
  # added by an earlier migration in the SAME migrator pass, which is exactly
  # what a first boot does). Existing CLIs still have devops_prod and take the
  # rename path.
  def up do
    if column?("project_configurations", "devops_prod") do
      rename table(:project_configurations), :devops_prod, to: :devops

      execute("UPDATE project_configurations SET devops = 'prod' WHERE devops = 'on'")
      execute("UPDATE project_configurations SET devops = 'uat' WHERE devops = 'off'")
    end
  end

  def down do
    if column?("project_configurations", "devops") do
      execute("UPDATE project_configurations SET devops = 'on' WHERE devops = 'prod'")
      execute("UPDATE project_configurations SET devops = 'off' WHERE devops IN ('uat', 'off')")

      rename table(:project_configurations), :devops, to: :devops_prod
    end
  end

  defp column?(table, column) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table})")
    Enum.any?(rows, fn row -> Enum.at(row, 1) == column end)
  end
end
