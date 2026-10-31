defmodule CodeMySpec.Repo.SqliteMigrations.AnOverlayNamesTheFilesItWasComputedFrom do
  use Ecto.Migration

  def change do
    alter table(:copy_overlays) do
      add :files, :string
    end
  end
end
