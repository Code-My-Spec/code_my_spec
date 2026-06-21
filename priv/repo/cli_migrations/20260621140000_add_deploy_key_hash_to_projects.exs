defmodule CodeMySpec.Repo.Migrations.AddDeployKeyHashToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :deploy_key_hash, :string
    end

    create unique_index(:projects, [:deploy_key_hash])
  end
end
