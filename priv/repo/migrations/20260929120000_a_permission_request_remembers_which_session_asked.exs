defmodule CodeMySpec.Repo.Migrations.APermissionRequestRemembersWhichSessionAsked do
  use Ecto.Migration

  # e96115a9: a Claude Code session's tap_out wrote only `session.state`, which
  # no screen reads. The row is the request; this names the session its
  # decision applies to. Nullable, no default: most requests have no session.
  def change do
    alter table(:permission_requests) do
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:permission_requests, [:session_id, :status])
  end
end
