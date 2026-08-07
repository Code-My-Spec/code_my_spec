defmodule CodeMySpec.Repo.Migrations.CreateLinkedServers do
  use Ecto.Migration

  # A server is account-scoped, not project-scoped. `provisioning_environments`
  # carries `server_name` and `ip` per project, which is why a box cannot be
  # shared between projects and why nothing owns a server's lifecycle — the
  # environment *is* the only record, so removing it orphans a live machine.
  #
  # This table records the link and nothing else. Size, address and status are
  # read from the provider on every view, because a box resized in the Hetzner
  # console must read correctly here; a cached copy would be a second source of
  # truth that drifts silently.
  def change do
    create table(:linked_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # The provider's own name, which is what identifies a box across a
      # resize, a reboot and an address change. Ids would be more stable still,
      # but the name is what Sam sees in both consoles.
      add :name, :string, null: false
      add :provider, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Linking the same box twice is not an error worth surfacing — it is a
    # double click. The unique index makes the upsert in `Server.link/2`
    # possible rather than needing a read-then-write race.
    create unique_index(:linked_servers, [:account_id, :provider, :name])
    create index(:linked_servers, [:account_id])
  end
end
