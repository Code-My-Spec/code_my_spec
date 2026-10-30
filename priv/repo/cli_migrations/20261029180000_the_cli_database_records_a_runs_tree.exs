defmodule CodeMySpec.Repo.Migrations.TheCliDatabaseRecordsARunsTree do
  @moduledoc """
  `analysis_runs.start_tree`, which the run schema reads (story 1174). Added
  only where absent, as `TheCliDatabaseCarriesWhatMigrationReads` does.
  """

  use Ecto.Migration

  def up do
    %{rows: rows} = repo().query!("SELECT name FROM pragma_table_info('analysis_runs')")

    if "start_tree" not in List.flatten(rows),
      do: execute("ALTER TABLE analysis_runs ADD COLUMN start_tree TEXT")
  end

  def down, do: :ok
end
