defmodule CodeMySpec.Repo.Migrations.ChangeFilesPathToText do
  use Ecto.Migration

  def change do
    alter table(:files) do
      modify :path, :text, from: :string
    end
  end
end
