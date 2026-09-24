defmodule CodeMySpec.Repo.Migrations.ASourcePathIsAsLongAsTheCriterionThatNamedIt do
  use Ecto.Migration

  @moduledoc """
  Three columns hold a repo-relative source path in `varchar(255)`. Generated
  spex filenames are longer than that, so the analyzer cannot record what it
  found.

  ## What it looked like

  metric_flow's credo leg failed with `ERROR 22001
  (string_data_right_truncation) value too long for type character varying(255)`
  and recorded **zero** problems. The harness said the rest out loud:

      the server REJECTED the credo result for /Volumes/X10 Pro/github/metric_flow
      That analyzer ran, but nothing was recorded from it. The run is still open
      on the server, so the next stop will report analysis pending rather than clean.

  So the leg neither passes nor produces findings to fix — it stays open, and
  every stop after it reports analysis pending. A gate that reads problems reads
  none and concludes clean; a human reading the leg sees a failure with nothing
  in it. Both are wrong in the same direction.

  ## Why the paths are that long

  A criterion's spex filename is generated from the criterion's text, so its
  length is the length of a sentence somebody wrote in a story. metric_flow's
  longest is **304 characters**:

      test/spex/fetch-and-select-google-business-profile-locations-across-mu-d555b3dd/
      criterion_4855_locations_are_fetched_using_the_google_business_profile_api_v1_...

  Nothing is wrong with that name — `mix spex` globs `_spex.exs` and the scanner
  keys criteria off `criterion_*_spex.exs`, so the shape is load-bearing. 255 was
  never a fact about paths, it is `:string`'s default, and every project whose
  criteria are written as full sentences will cross it.

  `files.path` and `criteria.spec_path` are already `text`, which is why the
  2329-file sync of the same checkout succeeded while the analyzer on it did not.
  `Problem`'s own changeset says the same thing: `validate_length(:file_path,
  min: 1)`, with no max, next to `max: 255` on the two columns that really are
  bounded. The schema layer already treats a path as unbounded; only the column
  disagreed.

  ## All three, not just the one that crashed

  The other two take the same paths from the same checkouts and have not been
  handed a long one yet:

  - `file_edits.file_path` — stop-hook attribution of changed files, so it sees
    every spex an agent touches.
  - `issues.source_path` — where an issue filed against a spex points.

  Widening only the column that happened to fail first leaves two identical
  faults to be rediscovered one crash at a time.

  Left alone: `problems.file_fingerprint` (a hash), `projects.local_path` (a
  checkout root), `doc_embeddings.path` (knowledge docs, all short today). Those
  are bounded in fact, not just by default.

  `varchar(n)` to `text` is binary-coercible in Postgres, so no table rewrite;
  the two btree indexes on these columns are rebuilt, and at 353 / 6589 / 1710
  rows that is immediate. A 304-byte key is far under btree's ~2704-byte limit.
  """

  def up do
    alter table(:problems) do
      modify :file_path, :text, null: false
    end

    alter table(:file_edits) do
      modify :file_path, :text, null: false
    end

    alter table(:issues) do
      modify :source_path, :text
    end
  end

  # Lossy on purpose, and it has to be: the old shape cannot hold the data the
  # new one accepts. Truncating beats dropping the rows — a problem with a
  # shortened path is still a problem somebody can find — but a truncated path
  # no longer resolves on disk, so this is a rollback, not a round trip.
  def down do
    execute "UPDATE problems SET file_path = left(file_path, 255) WHERE length(file_path) > 255"
    execute "UPDATE file_edits SET file_path = left(file_path, 255) WHERE length(file_path) > 255"

    execute "UPDATE issues SET source_path = left(source_path, 255) WHERE length(source_path) > 255"

    alter table(:problems) do
      modify :file_path, :string, null: false
    end

    alter table(:file_edits) do
      modify :file_path, :string, null: false
    end

    alter table(:issues) do
      modify :source_path, :string
    end
  end
end
