defmodule CodeMySpec.Repo.Migrations.AdvisoryFindingsAndCredoWholeCopy do
  @moduledoc """
  John, 2026-10-04: advisory findings never block, and task evaluation judges
  credo on the whole copy, as promotion does — both as project settings.

  `advisory_findings` is nullable and undefaulted; the default lives in the
  schema and a NULL reads as it. Credo's `block_changed` was the old default,
  so existing rows on it move to `block_all`; anything else was chosen and
  stays.
  """

  use Ecto.Migration

  def change do
    alter table(:project_configurations) do
      add :advisory_findings, :string
    end

    execute(
      "UPDATE project_configurations SET credo = 'block_all' WHERE credo IS NULL OR credo = 'block_changed'",
      "SELECT 1"
    )
  end
end
