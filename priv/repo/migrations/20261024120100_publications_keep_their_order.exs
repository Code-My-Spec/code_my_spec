defmodule CodeMySpec.Repo.Migrations.PublicationsKeepTheirOrder do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :publication_sequence, :bigint, default: 0, null: false
    end
  end
end
