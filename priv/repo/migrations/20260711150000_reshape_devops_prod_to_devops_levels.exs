defmodule CodeMySpec.Repo.Migrations.ReshapeDevopsProdToDevopsLevels do
  use Ecto.Migration

  # devops_prod [:on, :off] shipped unreleased and immediately grew a third
  # level: :off (no DevOps at all) | :uat (staging only) | :prod (full
  # promotion). One ordered enum, not flags — prod requires UAT. Old values
  # remap: on → prod, off → uat. Default lives on the schema, never here.
  def up do
    rename table(:project_configurations), :devops_prod, to: :devops

    execute("UPDATE project_configurations SET devops = 'prod' WHERE devops = 'on'")
    execute("UPDATE project_configurations SET devops = 'uat' WHERE devops = 'off'")
  end

  def down do
    execute("UPDATE project_configurations SET devops = 'on' WHERE devops = 'prod'")
    execute("UPDATE project_configurations SET devops = 'off' WHERE devops IN ('uat', 'off')")

    rename table(:project_configurations), :devops, to: :devops_prod
  end
end
