defmodule CodeMySpec.Repo.Migrations.AnIssueRecordsWhenItWasAcceptedAndClosed do
  use Ecto.Migration

  # Nothing recorded when an issue was accepted or closed, so nothing could say
  # how many were open on a given day. Closed issues take `updated_at` as their
  # closing time — the last write is nearly always the close. Accepted issues
  # take it too; a resolved or dismissed one is left without `accepted_at`,
  # since whether and when it was accepted is not known.
  def up do
    alter table(:issues) do
      add :accepted_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
    end

    execute "UPDATE issues SET closed_at = updated_at WHERE status IN ('resolved', 'dismissed')"
    execute "UPDATE issues SET accepted_at = updated_at WHERE status = 'accepted'"
  end

  def down do
    alter table(:issues) do
      remove :accepted_at
      remove :closed_at
    end
  end
end
