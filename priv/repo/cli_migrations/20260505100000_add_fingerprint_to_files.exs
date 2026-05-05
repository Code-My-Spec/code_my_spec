defmodule CodeMySpec.Repo.Migrations.CliAddFingerprintToFiles do
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :fingerprint, :string
    end
  end
end
