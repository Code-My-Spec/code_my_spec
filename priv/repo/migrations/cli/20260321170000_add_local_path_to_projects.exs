defmodule CodeMySpec.Repo.Migrations.AddLocalPathToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :local_path, :string
    end
  end
end
