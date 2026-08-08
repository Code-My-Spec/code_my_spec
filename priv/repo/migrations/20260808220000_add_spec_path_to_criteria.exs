defmodule CodeMySpec.Repo.Migrations.AddSpecPathToCriteria do
  use Ecto.Migration

  @moduledoc """
  Where a criterion's spex file is, recorded rather than derived.

  The path was computed from the criterion's id and a slug of its
  description — `test/spex/<story_id>_<story_slug>/criterion_<id>_<slug>_spex.exs`
  — which pinned a file on disk to two things that move.

  The id moves on migration. Story ids are per-deployment sequences, so
  migrating renumbers everything and every one of the 86 story directories on
  disk then names a story that no longer has that id here. Every criterion
  requirement would look for a file that exists under a different name.

  The slug moves whenever somebody edits a title or a description, which is an
  ordinary thing to do to a story. The derived path changed, the file did not,
  and the old one was orphaned with nothing pointing at it.

  Recording the path removes both. The file is where the record says it is; a
  rename is a deliberate act that updates the row, and a migration carries the
  string across untouched.

  Nullable, and the deriving code stays as the fallback: criteria authored
  before this have no path recorded, and computing one for them is still right
  until something writes it down.
  """

  def change do
    alter table(:criteria) do
      add :spec_path, :text
    end
  end
end
