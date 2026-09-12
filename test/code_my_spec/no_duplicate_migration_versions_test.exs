defmodule CodeMySpec.NoDuplicateMigrationVersionsTest do
  @moduledoc """
  No two migrations may share a version.

  `Ecto.Migrator` does not refuse the pair. `schema_migrations` is keyed on the
  version integer, so one file runs, the row is recorded, and the other is
  skipped **permanently** — a migrator never revisits a version it has already
  written. Nothing logs it and nothing reports it.

  What it looks like afterwards is a database that is up to date by every
  available measure and wrong in its tables. `mix ecto.migrate` answers
  "Migrations already up", truthfully, about the version. That is the one state
  no other check in this project can see: `cms.migrate_test_partitions` reports
  such a database current, because by Ecto's model it is.

  ## It has cost two days, from the same root

  **2026-09-12, first.** `a_restart_remembers_what_it_was_for` and
  `a_resolved_question_keeps_its_answer` both landed on `20260912010000`. The
  loser was skipped, and the consequences arrived as something else entirely:
  479 spex failures all reading `column q0.resolution does not exist`, against a
  tree whose migration was written, committed and applied. Four confident wrong
  diagnoses before anyone compared databases (`d86b09cd`).

  The repair renumbered the file, which could not un-record the version, so
  `working_copies.tools_seen_at` was left with no remover — hence
  `drop_the_orphaned_tools_seen_at`.

  **2026-09-12, again, the same day.** That drop was stamped `20260912070000`,
  and so was `a_requirement_remembers_what_it_was_computed_from` on another
  branch. They met at a merge. The fingerprint column never landed, and the
  repair written for it —
  `AddTheRequirementFingerprintColumnWhereItNeverLanded` — diagnosed it as "the
  version row committed and the DDL did not", which is not what happened: the
  DDL that ran was the other file's.

  Two collisions, one day, and the second was introduced by work landing
  alongside the fix for the first. Neither was noticed by anything; both were
  noticed by a person, late, via a symptom in a different subsystem.

  ## Why a test rather than care

  The check is one line against a directory listing, and the failure it prevents
  is invisible for as long as it takes somebody to compare two databases by
  hand. Care did not catch it twice.
  """

  use ExUnit.Case, async: true

  @migrations "priv/repo/migrations"

  test "every migration has a version no other migration has" do
    duplicates =
      @migrations
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.group_by(&version/1)
      |> Enum.filter(fn {_version, files} -> length(files) > 1 end)
      |> Enum.sort()

    assert duplicates == [],
           """
           Two or more migrations share a version.

           Ecto records the version once and skips the rest for good, with no
           error and no log line. The database then reports itself up to date
           and is missing a table change — which surfaces days later as a
           failure in something unrelated, and reads as broken code.

           Renumber the one that is safe to re-run. A migration whose DDL is
           idempotent (`ADD COLUMN IF NOT EXISTS`, `DROP COLUMN IF EXISTS`) can
           take a fresh version harmlessly on every database; a bare
           `alter table/add` cannot, because it would fail where it has already
           applied.

           #{describe(duplicates)}
           """
  end

  # The leading timestamp, which is what Ecto keys on. Everything after the
  # first underscore is a human label and does not participate.
  defp version(filename), do: filename |> String.split("_", parts: 2) |> hd()

  defp describe(duplicates) do
    Enum.map_join(duplicates, "\n\n", fn {version, files} ->
      "  #{version}\n" <> Enum.map_join(Enum.sort(files), "\n", &"    #{&1}")
    end)
  end
end
