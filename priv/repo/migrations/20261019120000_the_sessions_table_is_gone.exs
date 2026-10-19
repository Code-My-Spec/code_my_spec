defmodule CodeMySpec.Repo.Migrations.TheSessionsTableIsGone do
  use Ecto.Migration

  # Issue 26b78dca. A Claude Code conversation is a terminal agent now (story
  # 1122) and every task is an agent's, so the sessions table has no reader or
  # writer left. Back it up before running this where it holds rows you mean to
  # keep:
  #
  #     pg_dump --table=sessions --data-only <database> > sessions-backup.sql
  #
  # `agents.git_rewrite_at` takes over the one session column something still
  # reads: when a terminal session last ran a command able to move HEAD.
  #
  # `permission_requests.session_id` named the session a tap-out applied to; a
  # terminal session's tap-out names its agent now.
  def up do
    alter table(:agents) do
      add :git_rewrite_at, :utc_datetime_usec
    end

    alter table(:permission_requests) do
      remove :session_id
    end

    drop table(:sessions)
  end

  def down do
    raise Ecto.MigrationError,
      message: "the sessions table is not coming back; restore from the backup"
  end
end
