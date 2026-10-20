defmodule CodeMySpec.Repo.Migrations.ADevBoxTokenCanBeRevoked do
  use Ecto.Migration

  # Story 1131: a dev box trades its token for access tokens of its own, and
  # Sam can revoke one box without touching the others. `device_id` ties an
  # access token to the box it was issued to; `token_revoked_at` is the box
  # token's own revocation.
  def change do
    alter table(:devices) do
      add(:token_revoked_at, :utc_datetime_usec)
    end

    alter table(:oauth_access_tokens) do
      add(:device_id, :binary_id)
    end

    create(index(:oauth_access_tokens, [:device_id], where: "device_id IS NOT NULL"))
  end
end
