defmodule CodeMySpec.Repo.Migrations.RenameEnvironmentToEnvironmentType do
  use Ecto.Migration

  def change do
    rename(table(:sessions), :environment, to: :environment_type)
  end
end
