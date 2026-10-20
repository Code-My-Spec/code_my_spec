defmodule CodeMySpec.Repo.Migrations.ADeviceCanBeADevBox do
  use Ecto.Migration

  # Story 1130: an owner adds a dev box by choosing a provider; the box gets a
  # token of its own, kept as a property of the device (story 1020). Only the
  # hash is stored: the token is shown once, when the box is added.
  def change do
    alter table(:devices) do
      add(:provider, :string)
      add(:token_hash, :string)
      add(:token_last_used_at, :utc_datetime_usec)
    end

    create(unique_index(:devices, [:token_hash], where: "token_hash IS NOT NULL"))
  end
end
