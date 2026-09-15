defmodule CodeMySpec.Repo.Migrations.ARowRecordsWhenItChangedToTheMicrosecond do
  @moduledoc """
  Every table the requirement graph fingerprints by `{id, updated_at}` was
  second-resolution, so a row written more than once inside one second moved no
  fingerprint at all.

  `Freshness.row_key/1` is `{row.id, row.updated_at}` — chosen deliberately over
  named fields, because naming them covers only what the module happens to know
  and was wrong twice in one afternoon (criterion 5887). It rests on
  `updated_at` actually moving when the row does.

  At second precision it does not. Measured on criterion 6491: a story was
  written four times in one second — three clears from the spec-file and
  criteria paths, then the specs-ready latch set true — and every write produced
  the same `updated_at`. The fingerprint held still, `recompute_stale/3` skipped
  the story, and the stored `false` verdict stood against a latch that was true
  in the same transaction. The graph reported the opposite of the database and
  nothing could change its mind.

  Invisible until reads stopped recomputing the whole project, which is what
  covered for it.

  `qa_attempts` is already `:utc_datetime_usec` and needs nothing.
  """

  use Ecto.Migration

  @tables ~w(stories components bdd_rules criteria questions personas issues deploys working_copies)a

  def up do
    for t <- @tables do
      alter table(t) do
        modify :inserted_at, :utc_datetime_usec
        modify :updated_at, :utc_datetime_usec
      end
    end
  end

  def down do
    for t <- @tables do
      alter table(t) do
        modify :inserted_at, :utc_datetime
        modify :updated_at, :utc_datetime
      end
    end
  end
end
