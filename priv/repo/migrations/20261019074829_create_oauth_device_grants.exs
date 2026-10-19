defmodule CodeMySpec.Repo.Migrations.CreateOauthDeviceGrants do
  use Ecto.Migration

  # `create_if_not_exists`/`create_if_not_exists index(...)` rather than
  # plain `create`: an earlier version of this migration, since replaced,
  # already ran against at least one environment and left the table (with a
  # foreign key this version deliberately drops -- see the migration right
  # after this one) behind under the same table name. This has to converge
  # whether the table is already there or not, since there is no path back
  # to that environment to roll it back first.
  def change do
    create_if_not_exists table(:oauth_device_grants) do
      add :device_code, :string, null: false
      add :user_code, :string, null: false
      add :application_id, references(:oauth_applications, on_delete: :nothing), null: false
      # Opaque, not a foreign key: the requesting harness's own self-chosen
      # id, carried through for the devices page's own lookup to match
      # against -- a device that has not yet announced itself should still
      # be able to request a code, not be refused for a row that doesn't
      # exist yet.
      add :device_id, :binary_id
      add :resource_owner_id, references(:users, on_delete: :nothing)
      add :scopes, :string
      add :expires_at, :utc_datetime, null: false
      add :interval, :integer, null: false, default: 5
      add :denied_at, :utc_datetime
      add :access_token_id, references(:oauth_access_tokens, on_delete: :nothing)

      timestamps()
    end

    create_if_not_exists unique_index(:oauth_device_grants, [:device_code])
    create_if_not_exists unique_index(:oauth_device_grants, [:user_code])
    create_if_not_exists index(:oauth_device_grants, [:device_id])
  end
end
