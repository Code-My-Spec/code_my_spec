defmodule CodeMySpec.Repo.Migrations.CreateProjectLeases do
  use Ecto.Migration

  # Who currently owns a project's files, for the error message only.
  #
  # The lease itself is a Postgres advisory lock held on a dedicated connection
  # (see CodeMySpec.Leases.Session) — Postgres drops it when that connection
  # closes, so a harness that dies frees its projects immediately, with no
  # deadline to wait out and no heartbeat to miss.
  #
  # An advisory lock is two integers, though, and cannot tell you *which
  # checkout* is holding your project. That is what this table is for: the lock
  # decides, and this records a human-readable label so the refusal can say
  # "the harness at /workspace/todo_sprite" instead of "no".
  #
  # Consequences of being a label rather than the authority: a row left behind
  # by a crashed harness is stale but harmless, because acquiring consults the
  # lock and then overwrites the row. Nothing reads this to decide anything.
  def change do
    create table(:project_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :holder_label, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_leases, [:project_id])
  end
end
