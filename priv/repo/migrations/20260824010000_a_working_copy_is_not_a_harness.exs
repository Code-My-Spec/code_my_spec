defmodule CodeMySpec.Repo.Migrations.AWorkingCopyIsNotAHarness do
  @moduledoc """
  Call a working copy a working copy.

  There are three things here and two of them shared a word:

    * a **device** — a machine
    * a **harness** — an install running on a device, one per device in practice
    * a **working copy** — a checkout, which is what this table has always held

  So `harness_id` meant "working copy id" on seven tables while `harness` also
  meant the process in `cms harness`, `harness.log`, `CmsHarness.*` and the
  `harness:session:` topics. Two genuinely different things under one name.

  It only started to hurt when devices arrived: `harnesses.device_id` reads as
  "this harness belongs to a device" when the row is a checkout, and the
  ambiguity would have been baked one level deeper. It had already cost
  readability — the duplicate-rows issue is "several working copies with the
  same root", which needed the parenthetical every time it was written down.

  Column and table names only. The wire and on-disk names — `X-Harness-Id`,
  `CMS_HARNESS_ID`, `.cms_harness.json` — are a protocol that deployed checkouts
  and the published binary already speak, and they move separately behind a
  compatibility window.

  Index and constraint names are left as Postgres generated them. Renaming a
  table does not rename its indexes, and a cosmetic mismatch in `pg_indexes` is
  cheaper than a migration that has to enumerate them.
  """

  use Ecto.Migration

  # Every table that carries a reference to a working copy.
  @tables [:agents, :files, :problems, :issues, :sessions, :analysis_runs, :file_analyses]

  def up do
    rename(table(:harnesses), to: table(:working_copies))

    for t <- @tables do
      rename(table(t), :harness_id, to: :working_copy_id)
    end

    # Not a foreign key — how long a copy may be quiet before its derived state
    # is reclaimed. Same noun, same rename.
    rename(table(:project_configurations), :harness_idle_hours, to: :working_copy_idle_hours)
  end

  def down do
    rename(table(:project_configurations), :working_copy_idle_hours, to: :harness_idle_hours)

    for t <- @tables do
      rename(table(t), :working_copy_id, to: :harness_id)
    end

    rename(table(:working_copies), to: table(:harnesses))
  end
end
