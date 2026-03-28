defmodule CodeMySpec.Repo.Migrations.DropTasksTables do
  use Ecto.Migration

  def change do
    drop_if_exists table(:task_dependencies)
    drop_if_exists table(:tasks)
  end
end
