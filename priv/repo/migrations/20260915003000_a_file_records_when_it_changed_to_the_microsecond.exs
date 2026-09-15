defmodule CodeMySpec.Repo.Migrations.AFileRecordsWhenItChangedToTheMicrosecond do
  @moduledoc """
  `files.updated_at` was second-resolution, which is too coarse to order a file
  against the analyzer run that read it.

  `Analysis.Coverage.seen_entries/3` asks "did this file change after the run
  began". A run starts with microsecond precision (`analysis_runs.started_at` is
  `timestamp(6)`), so at second precision every file written in the same second
  as the run was unorderable against it — indistinguishable from one written a
  full second before. The only safe reading was to treat the whole second as
  possibly-during and exclude it, which throws away coverage for files the
  analyzer really did read.

  The same coarseness is the known trap behind `FileSync.sync_changed`'s `:gt`
  mtime filter, where a file written inside the sync's own second is skipped.
  That column is filesystem mtime and is coarse at the source; this one is ours
  and had no reason to be.
  """

  use Ecto.Migration

  def up do
    alter table(:files) do
      modify :inserted_at, :naive_datetime_usec
      modify :updated_at, :naive_datetime_usec
    end
  end

  def down do
    alter table(:files) do
      modify :inserted_at, :naive_datetime
      modify :updated_at, :naive_datetime
    end
  end
end
